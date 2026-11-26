/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Adds `user.id` to every span at start, when the application has set a user ID.
public final class UserIdSpanProcessor: SpanProcessor {
  public let isStartRequired = true
  public let isEndRequired = false
  private let userIdManager: UserIdManager

  public init(userIdManager: UserIdManager? = nil) {
    self.userIdManager = userIdManager ?? UserIdManagerProvider.getInstance()
  }

  public func onStart(parentContext: SpanContext?, span: ReadableSpan) {
    let key = SemanticConventions.User.id.rawValue
    // A span whose creator already set user.id keeps that value.
    guard span.getAttributes()[key] == nil, let userId = userIdManager.userId else { return }
    span.setAttribute(key: key, value: userId)
  }

  public func onEnd(span: any ReadableSpan) {}
  public func shutdown(explicitTimeout: TimeInterval?) {}
  public func forceFlush(timeout: TimeInterval?) {}
}
