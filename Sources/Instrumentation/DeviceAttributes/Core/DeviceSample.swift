/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// One reading of the device and process. A value is `nil` when the platform can't report it.
public struct DeviceSample: Equatable, Sendable {
  /// The battery's charge from 0 to 1, or `nil` when the level is unknown, as on a simulator.
  public var batteryCharge: Double?
  /// The share of CPU capacity the process uses from 0 to 1, where 1 means every core is busy.
  public var cpuUtilization: Double?
  /// The process's resident memory in bytes.
  public var memoryUsage: Int?

  public init(batteryCharge: Double? = nil, cpuUtilization: Double? = nil, memoryUsage: Int? = nil) {
    self.batteryCharge = batteryCharge
    self.cpuUtilization = cpuUtilization
    self.memoryUsage = memoryUsage
  }

  /// A battery level that UIKit reports as -1 when it can't tell, or that falls outside 0 to 1,
  /// is not a charge, so it becomes `nil`.
  static func charge(fromBatteryLevel level: Float) -> Double? {
    guard level.isFinite, level >= 0, level <= 1 else { return nil }
    return rounded(Double(level))
  }

  /// Four decimals keep a reading's noise out of the export without hiding an idle process.
  static func rounded(_ value: Double) -> Double {
    (value * 10_000).rounded() / 10_000
  }
}

/// Reads the device. The tests replace it.
public protocol DeviceReader: Sendable {
  func read() -> DeviceSample
}
