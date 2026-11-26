/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// How `DeviceAttributesInstrumentation` samples the device.
public struct DeviceAttributesConfiguration: Sendable {
  /// The shortest time between two reads of the device, in seconds. The default is 1.
  ///
  /// A read of CPU and memory takes about 30 microseconds in a debug build with the test
  /// process's threads, so one read a second costs about 0.003% of a core, and nothing while the
  /// app records no signals. A shorter interval
  /// follows a spike more closely, and the kernel's CPU figure decays over about a second, so
  /// reading more often than that adds cost without adding information. 0 reads on every signal.
  public var sampleInterval: TimeInterval

  public init(sampleInterval: TimeInterval = 1) {
    self.sampleInterval = sampleInterval
  }
}

/// Records the battery charge, CPU utilization and resident memory on spans and log records.
///
/// `install()` starts the battery monitor and creates the shared `DeviceSampler`. The attributes
/// reach signals through `DeviceAttributesSpanProcessor` and `DeviceAttributesLogRecordProcessor`,
/// which the app adds to its providers.
public enum DeviceAttributesInstrumentation {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var installed: DeviceSampler?
  private static let battery = BatteryMonitor()
  private static let beforeInstall = DeviceSampler(reader: SystemDeviceReader(battery: battery), interval: 1)

  /// The installed sampler. Before `install()` it is a sampler that reports CPU and memory but no
  /// battery, so a processor made too early still works.
  public static var sampler: DeviceSampler {
    lock.lock()
    defer { lock.unlock() }
    return installed ?? beforeInstall
  }

  /// Whether `install()` has run.
  public static var isInstalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return installed != nil
  }

  /// Starts battery monitoring and sets the sampling interval. Idempotent and thread-safe: only the
  /// first call takes effect. Call it from the main thread at launch so the battery has a value
  /// before the first span.
  public static func install(configuration: DeviceAttributesConfiguration = .init()) {
    lock.lock()
    defer { lock.unlock() }
    guard installed == nil else { return }
    let interval = configuration.sampleInterval
    installed = DeviceSampler(
      reader: SystemDeviceReader(battery: battery),
      interval: interval.isFinite && interval >= 0 ? interval : DeviceAttributesConfiguration().sampleInterval
    )
    battery.start()
  }
}
