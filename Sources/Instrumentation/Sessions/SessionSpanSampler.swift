/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

public class SessionSpanSampler: Sampler {
  private let sessionManager: SessionManager

  public init(sessionManager: SessionManager? = nil) {
    self.sessionManager = sessionManager ?? SessionManagerProvider.getInstance()
  }

  public func shouldSample(parentContext: SpanContext?,
                           traceId: TraceId,
                           name: String,
                           kind: SpanKind,
                           attributes: [String: AttributeValue],
                           parentLinks: [SpanData.Link]) -> Decision {
    // Get session ID from attributes if available, otherwise use current session
    let sessionId = attributes[SessionConstants.id]?.description ?? sessionManager.peekSession()?.id
    let isSampled = sessionId.map { sessionManager.isSessionSampled(for: $0) } ?? false
    
    return SessionSamplingDecision(isSampled: isSampled)
  }

  public var description: String {
    return "SessionSpanSampler"
  }
}

/// Decision implementation for session-based sampling
public struct SessionSamplingDecision: Decision {
  public let isSampled: Bool
  public let attributes: [String: AttributeValue] = [:]
}
