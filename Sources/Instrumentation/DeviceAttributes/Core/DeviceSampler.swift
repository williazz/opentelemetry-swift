/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Hands out the latest `DeviceSample`, reading the device at most once per interval.
///
/// The span and log processors share one sampler, so a burst of signals costs one kernel read
/// for all three values, not one per signal. The sampler has no timer. An app with nothing to
/// record spends nothing, and a reading is never older than the interval.
public final class DeviceSampler: @unchecked Sendable {
  private let reader: DeviceReader
  private let interval: TimeInterval
  private let uptime: @Sendable () -> TimeInterval
  private let lock = NSLock()
  private var lastSample = DeviceSample()
  private var lastSampleUptime: TimeInterval?

  /// - Parameters:
  ///   - interval: The shortest time between two reads of the device, in seconds.
  ///   - uptime: A monotonic clock in seconds. A wall clock would let a clock change freeze or
  ///     flood the reads.
  init(
    reader: DeviceReader,
    interval: TimeInterval,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.reader = reader
    self.interval = interval
    self.uptime = uptime
  }

  /// The latest sample. Reads the device if the last read is at least one interval old.
  ///
  /// A read holds the lock, so a thread that arrives during one waits for it, tens of
  /// microseconds, and then takes the fresh sample. The lock keeps two threads from reading at once.
  public func sample() -> DeviceSample {
    let now = uptime()
    lock.lock()
    defer { lock.unlock() }
    if let last = lastSampleUptime, now - last < interval {
      return lastSample
    }
    lastSampleUptime = now
    lastSample = reader.read()
    return lastSample
  }
}
