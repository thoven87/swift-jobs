//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Dispatch
import Foundation
import Logging
import Metrics
import ServiceLifecycle

/// Object handling a single job queue
final class JobQueueHandler<Queue: JobQueueDriver>: Sendable {
    init(queue: Queue, numWorkers: Int, logger: Logger) {
        self.queue = queue
        self.numWorkers = numWorkers
        self.logger = logger
        self.jobRegistry = .init()
    }

    ///  Register job
    /// - Parameters:
    ///   - id: Job Identifier
    ///   - maxRetryCount: Maximum number of times job is retried before being flagged as failed
    ///   - execute: Job code
    func registerJob(_ job: JobDefinition<some Codable & Sendable>) {
        self.jobRegistry.registerJob(job: job)
    }

    func run() async throws {
        try await withGracefulShutdownHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = self.queue.makeAsyncIterator()
                for _ in 0..<self.numWorkers {
                    if let job = try await iterator.next() {
                        group.addTask {
                            try await self.runJob(job)
                        }
                    }
                }
                while true {
                    try await group.next()
                    guard let job = try await iterator.next() else { break }
                    group.addTask {
                        try await self.runJob(job)
                    }
                }
            }
            await self.queue.shutdownGracefully()
        } onGracefulShutdown: {
            Task {
                await self.queue.stop()
            }
        }
    }

    func runJob(_ queuedJob: QueuedJob<Queue.JobID>) async throws {
        var logger = logger
        let startTime = DispatchTime.now().uptimeNanoseconds

        Meter(label: self.meterLabel, dimensions: [("status", JobStatus.queued.rawValue)]).decrement()
        Meter(label: self.meterLabel, dimensions: [("status", JobStatus.processing.rawValue)]).increment()
        defer {
            Meter(label: self.meterLabel, dimensions: [("status", JobStatus.processing.rawValue)]).decrement()
        }
        logger[metadataKey: "JobID"] = .stringConvertible(queuedJob.id)
        let job: any JobInstanceProtocol
        do {
            job = try self.jobRegistry.decode(queuedJob.jobBuffer)
        } catch let error as JobQueueError where error == .unrecognisedJobId {
            logger.debug("Failed to find Job with ID while decoding")
            try await self.queue.failed(jobId: queuedJob.id, error: error)
            return
        } catch {
            logger.debug("Job failed to decode")
            try await self.queue.failed(jobId: queuedJob.id, error: JobQueueError.decodeJobFailed)
            return
        }
        logger[metadataKey: "JobName"] = .string(job.name)

        guard (job.delayUntil ?? .distantPast) < Date() else {
            logger.debug("Requeueing Job for later execution, it's delayed", metadata: [
                "DelayedUntil": "\(job.delayUntil ?? .distantPast)",
                "JobName": "\(job.name)",
            ])
            // TODO: requeue Job with the exact same parameters
            return
        }

        // Calculate wait time from queued to processing
        let jobQueuedDuration = Date.now.timeIntervalSince(job.queuedAt)
        Timer(
            label: "\(self.metricsLabel)_queued_for_duration_seconds",
            preferredDisplayUnit: .seconds
        ).recordSeconds(jobQueuedDuration)

        // var count = job.maxRetryCount
        logger.debug("Starting Job")

        do {
            while true {
                do {
                    Meter(label: self.meterLabel, dimensions: [("status", JobStatus.processing.rawValue)]).increment()
                    try await job.execute(context: .init(logger: logger))
                    break
                } catch let error as CancellationError {
                    logger.debug("Job cancelled")
                    // Job failed is called but due to the fact the task is cancelled, depending on the
                    // job queue driver, the process of failing the job might not occur because itself
                    // might get cancelled
                    try await self.queue.failed(jobId: queuedJob.id, error: error)
                    self.updateJobMetrics(for: job.name, startTime: startTime, error: error)
                    return
                } catch {
                    if job.remainingAttempts <= 0 {
                        logger.debug("Job failed")
                        try await self.queue.failed(jobId: queuedJob.id, error: error)
                        self.updateJobMetrics(for: job.name, startTime: startTime, error: error)
                        return
                    }
                    // count -= 1
                    logger.debug("Retrying Job")
                    self.updateJobMetrics(for: job.name, startTime: startTime, retrying: true)
                    let attempts = job.attempts + 1
                    let delay = self.backoff(attempts: attempts)
                    // let nextJobQueueDuration = Date.now.timeIntervalSince(job.queuedAt) + delay
                    // once this is parameters are figured out. extact into a function so it can be used for both
                    // delayed and retries
                    let jobBuffer = EncodableJob(
                        id: JobIdentifier(job.name),
                        // TODO: How do I get job parameters from here?
                        parameters: queuedJob,
                        queuedAt: job.queuedAt,
                        delayUntil: .init(timeIntervalSinceNow: TimeInterval(delay)),
                        attempts: attempts
                    )
                    try await self.queue.push(jobBuffer)

                    /// Should we enque the job with delay until instead of sleeping?
                    /// This would give us the benefit of allowing jobs to be pushed now and get processed later
                    // try await Task.sleep(nanoseconds: self.backoff(attempts: count))
                }
            }
            logger.debug("Finished Job")
            try await self.queue.finished(jobId: queuedJob.id)
            self.updateJobMetrics(for: job.name, startTime: startTime)
        } catch {
            logger.debug("Failed to set job status")
            self.updateJobMetrics(for: job.name, startTime: startTime, error: error)
        }
    }

    private let jobRegistry: JobRegistry
    private let queue: Queue
    private let numWorkers: Int
    let logger: Logger
}

extension JobQueueHandler: CustomStringConvertible {
    public var description: String { "JobQueueHandler<\(String(describing: Queue.self))>" }
    private var metricsLabel: String { "swift_jobs" }
    private var meterLabel: String { "swift_jobs_meter" }

    /// Used for the histogram which can be useful to see by job status
    private enum JobStatus: String, Codable, Sendable {
        case queued
        case processing
        case retried
        case cancelled
        case failed
        case succeeded
    }

    private func updateJobMetrics(
        for name: String,
        startTime: UInt64,
        error: Error? = nil,
        retrying: Bool = false
    ) {
        if retrying {
            Counter(
                label: self.metricsLabel,
                dimensions: [("name", name), ("status", JobStatus.retried.rawValue)]
            ).increment()
            return
        }

        let jobStatus: JobStatus = if let error {
            if error is CancellationError {
                .cancelled
            } else {
                .failed
            }
        } else {
            .succeeded
        }

        let dimensions: [(String, String)] = [
            ("name", name),
            ("status", jobStatus.rawValue),
        ]

        // Calculate job execution time
        Timer(
            label: "\(self.metricsLabel)_duration_seconds",
            dimensions: dimensions,
            preferredDisplayUnit: .seconds
        ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime)

        // Increment job counter base on status
        Counter(
            label: self.metricsLabel,
            dimensions: dimensions
        ).increment()
    }
}

extension JobQueueHandler {
    func backoff(attempts: Int, baseDelay: Double = 0.25, maxInterval: Double = 60) -> UInt64 {
        let delay = baseDelay * pow(2, Double(attempts))
        return UInt64(Double.random(in: 0...min(maxInterval, delay)) * 1_000_000_000)
    }
}
