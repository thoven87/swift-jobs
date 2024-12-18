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

/// Defines job parameters and identifier
public protocol JobParameters: Codable, Sendable {
    /// Job type name
    static var jobName: String { get }
}

extension JobParameters {
    /// Job type id
    public static var jobID: JobIdentifier<Self> {
        .init(jobName)
    }

    /// Added so it is possible to push JobParameters referenced as Existentials to a Job queue
    @discardableResult public func push<Queue: JobQueueDriver>(
        to jobQueue: JobQueue<Queue>,
        options: JobOptions = .init()
    ) async throws -> Queue.JobID {
        try await jobQueue.push(self, options: options)
    }
}

extension JobQueue {
    ///  Push Job onto queue
    /// - Parameters:
    ///   - parameters: parameters for the job
    ///   - options: JobOptions
    /// - Returns: Identifier of queued job
    @discardableResult public func push<Parameters: JobParameters>(
        _ parameters: Parameters,
        options: JobOptions = .init()
    ) async throws -> Queue.JobID {
        try await self.push(id: Parameters.jobID, parameters: parameters, options: options)
    }

    ///  Register job type
    /// - Parameters:
    ///   - parameters: Job parameter type
    ///   - maxRetryCount: Maximum number of times job is retried before being flagged as failed
    ///   - execute: Job code
    public func registerJob<Parameters: JobParameters>(
        parameters: Parameters.Type = Parameters.self,
        maxRetryCount: Int = 0,
        execute: @escaping @Sendable (Parameters, JobContext) async throws -> Void
    ) {
        self.registerJob(id: Parameters.jobID, maxRetryCount: maxRetryCount, execute: execute)
    }
}
