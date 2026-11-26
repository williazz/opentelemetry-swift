/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import InstrumentationSemanticConventions
import OpenTelemetryApi
import OpenTelemetrySdk

/// Adds the battery charge, CPU utilization and resident memory to each log record, then passes
/// the record to the next processor.
///
/// The values are the latest `DeviceSampler` sample, at most one interval old. Without
/// `DeviceAttributesInstrumentation.install()` the battery is missing.
public class DeviceAttributesLogRecordProcessor: LogRecordProcessor {
  private let nextProcessor: LogRecordProcessor
  private let sampler: DeviceSampler?

  /// - Parameter sampler: Where the values come from. The default is the sampler `install()`
  ///   creates, looked up on each record, so the processor may be made before `install()` runs.
  public init(nextProcessor: LogRecordProcessor, sampler: DeviceSampler? = nil) {
    self.nextProcessor = nextProcessor
    self.sampler = sampler
  }

  public func onEmit(logRecord: ReadableLogRecord) {
    var enhancedRecord = logRecord
    let sample = (sampler ?? DeviceAttributesInstrumentation.sampler).sample()
    if let charge = sample.batteryCharge {
      enhancedRecord.setAttribute(key: FederatedSemanticConventions.Hw.batteryCharge.rawValue, value: .double(charge))
    }
    if let cpu = sample.cpuUtilization {
      enhancedRecord.setAttribute(key: FederatedSemanticConventions.Process.cpuUtilization.rawValue, value: .double(cpu))
    }
    if let memory = sample.memoryUsage {
      enhancedRecord.setAttribute(key: FederatedSemanticConventions.Process.memoryUsage.rawValue, value: .int(memory))
    }
    nextProcessor.onEmit(logRecord: enhancedRecord)
  }

  public func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    nextProcessor.shutdown(explicitTimeout: explicitTimeout)
  }

  public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    nextProcessor.forceFlush(explicitTimeout: explicitTimeout)
  }
}
