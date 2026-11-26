/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import XCTest
@testable import DeviceAttributesInstrumentation

final class CountingReader: DeviceReader, @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  var sample: DeviceSample

  init(sample: DeviceSample = DeviceSample(batteryCharge: 0.5, cpuUtilization: 0.25, memoryUsage: 1_000)) {
    self.sample = sample
  }

  var readCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reads
  }

  func read() -> DeviceSample {
    lock.lock()
    defer { lock.unlock() }
    reads += 1
    return sample
  }
}

final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var seconds: TimeInterval = 100

  var now: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return seconds
  }

  func advance(_ delta: TimeInterval) {
    lock.lock()
    seconds += delta
    lock.unlock()
  }
}

final class DeviceSamplerTests: XCTestCase {
  func testFirstCallReadsTheDevice() {
    let reader = CountingReader()
    let sampler = DeviceSampler(reader: reader, interval: 1, uptime: FakeClock().asUptime)

    XCTAssertEqual(sampler.sample(), reader.sample)
    XCTAssertEqual(reader.readCount, 1)
  }

  func testCallsWithinTheIntervalReuseTheLastRead() {
    let reader = CountingReader()
    let clock = FakeClock()
    let sampler = DeviceSampler(reader: reader, interval: 1, uptime: clock.asUptime)

    _ = sampler.sample()
    clock.advance(0.999)
    reader.sample = DeviceSample(batteryCharge: 0.1)

    XCTAssertEqual(sampler.sample().batteryCharge, 0.5)
    XCTAssertEqual(reader.readCount, 1)
  }

  func testCallAtTheIntervalReadsAgain() {
    let reader = CountingReader()
    let clock = FakeClock()
    let sampler = DeviceSampler(reader: reader, interval: 1, uptime: clock.asUptime)

    _ = sampler.sample()
    clock.advance(1)
    reader.sample = DeviceSample(batteryCharge: 0.1)

    XCTAssertEqual(sampler.sample().batteryCharge, 0.1)
    XCTAssertEqual(reader.readCount, 2)
  }

  func testZeroIntervalReadsOnEveryCall() {
    let reader = CountingReader()
    let sampler = DeviceSampler(reader: reader, interval: 0, uptime: FakeClock().asUptime)

    _ = sampler.sample()
    _ = sampler.sample()
    _ = sampler.sample()

    XCTAssertEqual(reader.readCount, 3)
  }

  func testConcurrentCallsInOneIntervalReadOnce() {
    let reader = CountingReader()
    let sampler = DeviceSampler(reader: reader, interval: 1, uptime: FakeClock().asUptime)

    DispatchQueue.concurrentPerform(iterations: 200) { _ in
      XCTAssertEqual(sampler.sample(), reader.sample)
    }

    XCTAssertEqual(reader.readCount, 1)
  }

  func testAnUnavailableValueStaysNilUntilTheNextRead() {
    let reader = CountingReader(sample: DeviceSample(batteryCharge: nil, cpuUtilization: 0.1, memoryUsage: 5))
    let sampler = DeviceSampler(reader: reader, interval: 1, uptime: FakeClock().asUptime)

    XCTAssertNil(sampler.sample().batteryCharge)
  }
}

extension FakeClock {
  var asUptime: @Sendable () -> TimeInterval { { [self] in now } }
}
