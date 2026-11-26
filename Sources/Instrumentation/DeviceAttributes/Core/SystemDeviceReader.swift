/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Reads the real device: the battery from `BatteryMonitor`, the rest from the Mach kernel.
struct SystemDeviceReader: DeviceReader {
  let battery: BatteryMonitor

  func read() -> DeviceSample {
    DeviceSample(
      batteryCharge: battery.charge,
      cpuUtilization: ProcessStats.cpuUtilization(),
      memoryUsage: ProcessStats.residentMemory()
    )
  }
}
