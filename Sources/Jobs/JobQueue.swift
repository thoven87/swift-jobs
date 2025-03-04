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

import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import ServiceLifecycle

/// Protocol for Job queue. Allows us to pass job queues around as existentials
public protocol JobQueueProtocol: Service {
    associatedtype Queue: JobQueueDriver

    var logger: Logger { get }

    ///  Push Job onto queue
    /// - Parameters:
    ///   - id: Job identifier
    ///   - parameters: parameters for the job
    /// - Returns: Identifier of queued job
    func push<Parameters: JobParameters>(
        _ parameters: Parameters,
        options: JobOptions
    ) async throws -> Queue.JobID

    ///  Register job type
    /// - Parameters:
    ///   - job: Job definition
    func registerJob(_ job: JobDefinition<some JobParameters>)
}

extension JobQueueProtocol {
    ///  Register job type
    /// - Parameters:
    ///   - parameters: Job Parameters
    ///   - maxRetryCount: Maximum number of times job is retried before being flagged as failed
    ///   - execute: Job code
    public func registerJob<Parameters: JobParameters>(
        parameters: Parameters.Type = Parameters.self,
        maxRetryCount: Int = 0,
        execute: @escaping @Sendable (
            Parameters,
            JobContext
        ) async throws -> Void
    ) {
        self.logger.info("Registered Job", metadata: ["JobName": .string(Parameters.jobName)])
        let job = JobDefinition<Parameters>(maxRetryCount: maxRetryCount, execute: execute)
        self.registerJob(job)
    }
}

/// Job queue
///
/// Wrapper type to bring together a job queue implementation and a job queue
/// handler. Before you can push jobs onto a queue you should register it
/// with the queue via either ``registerJob(parameters:maxRetryCount:execute:)`` or
/// ``registerJob(_:)``.
public struct JobQueue<Queue: JobQueueDriver>: JobQueueProtocol {
    /// underlying driver for queue
    public let queue: Queue
    let handler: JobQueueHandler<Queue>
    let initializationComplete: Trigger

    public init(
        _ queue: Queue,
        numWorkers: Int = 1,
        logger: Logger,
        options: JobQueueOptions = .init(),
        @JobMiddlewareBuilder middleware: () -> some JobMiddleware = { NullJobMiddleware() }
    ) {
        self.queue = queue
        self.handler = .init(queue: queue, numWorkers: numWorkers, logger: logger, options: options, middleware: middleware())
        self.initializationComplete = .init()
    }

    ///  Push Job onto queue
    /// - Parameters:
    ///   - id: Job identifier
    ///   - parameters: parameters for the job
    /// - Returns: Identifier of queued job
    @discardableResult public func push<Parameters: JobParameters>(
        _ parameters: Parameters,
        options: JobOptions = .init()
    ) async throws -> Queue.JobID {
        let request = JobRequest(parameters: parameters, queuedAt: .now, attempts: 0)
        let instanceID = try await self.queue.push(request, options: options)
        await self.handler.middleware.onPushJob(parameters: parameters, jobInstanceID: instanceID.description)
        self.logger.debug(
            "Pushed Job",
            metadata: ["JobID": .stringConvertible(instanceID), "JobName": .string(Parameters.jobName)]
        )
        return instanceID
    }

    ///  Register job type
    /// - Parameters:
    ///   - job: Job definition
    public func registerJob(_ job: JobDefinition<some JobParameters>) {
        self.handler.queue.registerJob(job)
    }

    ///  Run queue handler
    public func run() async throws {
        do {
            try await self.queue.onInit()
            self.initializationComplete.trigger()
        } catch {
            self.initializationComplete.failed(error)
        }
        try await self.handler.run()
    }

    public var logger: Logger { self.handler.logger }
}

extension JobQueue {
    /// Get JobQueue metadata
    func getMetadata<Value: Codable>(_ key: JobMetadataKey<Value>) async throws -> Value? {
        guard let buffer = try await self.queue.getMetadata(key.name) else { return nil }
        return try JSONDecoder().decode(Value.self, from: buffer)
    }

    /// Set JobQueue metadata
    func setMetadata<Value: Codable>(key: JobMetadataKey<Value>, value: Value) async throws {
        let buffer = try JSONEncoder().encodeAsByteBuffer(value, allocator: ByteBufferAllocator())
        try await self.queue.setMetadata(key: key.name, value: buffer)
    }
}

extension JobQueue: CustomStringConvertible {
    public var description: String { "JobQueue<\(String(describing: Queue.self))>" }
}
