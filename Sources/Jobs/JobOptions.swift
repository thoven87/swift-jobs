//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2024 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.Date

/// Job options
public struct JobOptions: Sendable {
    /// When to execute the job
    public let delayUntil: Date

    public init(delayUntil: Date? = nil) {
        self.delayUntil = delayUntil ?? Date.now
    }
}
