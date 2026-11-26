/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Adds `user.id` to every log record, when the application has set a user ID.
public final class UserIdLogRecordProcessor: LogRecordProcessor {
  private let nextProcessor: LogRecordProcessor
  private let userIdManager: UserIdManager

  public init(nextProcessor: LogRecordProcessor, userIdManager: UserIdManager? = nil) {
    self.nextProcessor = nextProcessor
    self.userIdManager = userIdManager ?? UserIdManagerProvider.getInstance()
  }

  public func onEmit(logRecord: ReadableLogRecord) {
    let key = SemanticConventions.User.id.rawValue
    // A record whose producer already set user.id keeps that value.
    guard logRecord.attributes[key] == nil, let userId = userIdManager.userId else {
      nextProcessor.onEmit(logRecord: logRecord)
      return
    }
    var enhanced = logRecord
    enhanced.setAttribute(key: key, value: userId)
    nextProcessor.onEmit(logRecord: enhanced)
  }

  public func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    nextProcessor.shutdown(explicitTimeout: explicitTimeout)
  }

  public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    nextProcessor.forceFlush(explicitTimeout: explicitTimeout)
  }
}
