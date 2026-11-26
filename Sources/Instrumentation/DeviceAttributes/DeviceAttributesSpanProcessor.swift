/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import InstrumentationSemanticConventions
import OpenTelemetryApi
import OpenTelemetrySdk

/// Adds the battery charge, CPU utilization and resident memory to each span when it starts.
///
/// The values are the latest `DeviceSampler` sample, at most one interval old. Without
/// `DeviceAttributesInstrumentation.install()` the battery is missing.
public class DeviceAttributesSpanProcessor: SpanProcessor {
  public var isStartRequired = true
  public var isEndRequired = false
  private let sampler: DeviceSampler?

  /// - Parameter sampler: Where the values come from. The default is the sampler `install()`
  ///   creates, looked up on each span, so the processor may be made before `install()` runs.
  public init(sampler: DeviceSampler? = nil) {
    self.sampler = sampler
  }

  public func onStart(parentContext: SpanContext?, span: ReadableSpan) {
    let sample = (sampler ?? DeviceAttributesInstrumentation.sampler).sample()
    if let charge = sample.batteryCharge {
      span.setAttribute(key: FederatedSemanticConventions.Hw.batteryCharge.rawValue, value: charge)
    }
    if let cpu = sample.cpuUtilization {
      span.setAttribute(key: FederatedSemanticConventions.Process.cpuUtilization.rawValue, value: cpu)
    }
    if let memory = sample.memoryUsage {
      span.setAttribute(key: FederatedSemanticConventions.Process.memoryUsage.rawValue, value: memory)
    }
  }

  public func onEnd(span: any ReadableSpan) {}

  public func shutdown(explicitTimeout: TimeInterval?) {}

  public func forceFlush(timeout: TimeInterval?) {}
}
