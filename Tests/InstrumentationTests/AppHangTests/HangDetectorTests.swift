/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

@testable import AppHang
import Foundation
import XCTest

/// A clock the test moves by hand, so every assertion about a duration is exact and no test
/// waits for real time to pass.
final class TestClock: @unchecked Sendable {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)
  private let lock = NSLock()
  private var _seconds: TimeInterval = 0

  var seconds: TimeInterval { lock.withLock { _seconds } }

  func advance(_ interval: TimeInterval) {
    lock.withLock { _seconds += interval }
  }

  var clock: HangClock {
    HangClock(now: { [self] in start.addingTimeInterval(seconds) },
              uptime: { [self] in seconds })
  }

  func date(at offset: TimeInterval) -> Date {
    start.addingTimeInterval(offset)
  }
}

final class HangDetectorTests: XCTestCase {
  private var clock: TestClock!
  private var configuration: AppHangInstrumentationConfiguration!

  override func setUp() {
    super.setUp()
    clock = TestClock()
    configuration = AppHangInstrumentationConfiguration()
  }

  private func makeDetector() -> HangDetector {
    HangDetector(configuration: configuration, clock: clock.clock)
  }

  // MARK: - Detecting a hang

  func testWorkShorterThanTheThresholdIsNoHang() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.249)
    XCTAssertNil(detector.willSleep())
  }

  func testWorkAtTheThresholdIsAHang() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.25)

    let hang = detector.willSleep()

    XCTAssertEqual(hang?.start, clock.date(at: 0))
    XCTAssertEqual(hang?.duration ?? 0, 0.25, accuracy: 0.000_001)
    XCTAssertNil(hang?.stackTrace)
  }

  func testHangStartsWhenTheRunLoopWokeNotWhenItSlept() {
    let detector = makeDetector()
    clock.advance(5)
    detector.didWake()
    clock.advance(2)

    let hang = detector.willSleep()

    XCTAssertEqual(hang?.start, clock.date(at: 5))
    XCTAssertEqual(hang?.duration ?? 0, 2, accuracy: 0.000_001)
  }

  func testSleepingWithoutWakingIsNoHang() {
    let detector = makeDetector()
    clock.advance(10)
    XCTAssertNil(detector.willSleep())
  }

  func testEachRunLoopPassIsTimedOnItsOwn() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(1)
    XCTAssertNotNil(detector.willSleep())

    detector.didWake()
    clock.advance(0.1)
    XCTAssertNil(detector.willSleep(), "the idle time between passes is not part of the next one")
  }

  func testThresholdIsConfigurable() {
    configuration.hangThreshold = 2
    let detector = makeDetector()
    detector.didWake()
    clock.advance(1.9)
    XCTAssertNil(detector.willSleep())

    detector.didWake()
    clock.advance(2.1)
    XCTAssertNotNil(detector.willSleep())
  }

  // MARK: - Capturing the stack trace

  func testNoStackTraceIsDueWhileTheMainThreadIsIdle() {
    let detector = makeDetector()
    XCTAssertNil(detector.stackTraceIsDue())
  }

  func testNoStackTraceIsDueBelowTheStackTraceThreshold() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.16) // just under two thirds of 0.25
    XCTAssertNil(detector.stackTraceIsDue())
  }

  func testStackTraceIsDueOnceTheHangIsLikely() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.17)

    let ongoing = detector.stackTraceIsDue()

    XCTAssertEqual(ongoing?.startUptime, 0)
  }

  func testStackTraceThresholdIsConfigurable() {
    configuration.hangThreshold = 1
    configuration.stackTraceThreshold = 0.5
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.4)
    XCTAssertNil(detector.stackTraceIsDue())
    clock.advance(0.2)
    XCTAssertNotNil(detector.stackTraceIsDue())
  }

  func testOnlyOneCaptureRunsAtATime() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.2)

    XCTAssertNotNil(detector.stackTraceIsDue())
    XCTAssertNil(detector.stackTraceIsDue(), "a capture is already walking the stack")
  }

  func testCapturedStackTraceIsReportedWithTheHang() throws {
    let detector = makeDetector()
    let capture = CapturedStackTrace(addresses: [0x1000, 0x2000], isTruncated: false)
    detector.didWake()
    clock.advance(0.2)

    let ongoing = try XCTUnwrap(detector.stackTraceIsDue())
    detector.record(stackTrace: capture, for: ongoing)
    clock.advance(0.3)

    XCTAssertEqual(detector.willSleep()?.stackTrace, capture)
  }

  func testStackTraceIsTakenOncePerHang() throws {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.2)
    let ongoing = try XCTUnwrap(detector.stackTraceIsDue())
    detector.record(stackTrace: CapturedStackTrace(addresses: [0x1000], isTruncated: false), for: ongoing)

    clock.advance(1)

    XCTAssertNil(detector.stackTraceIsDue(), "the trace from the start of the hang is the useful one")
  }

  func testAFailedCaptureIsRetried() throws {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.2)
    let ongoing = try XCTUnwrap(detector.stackTraceIsDue())
    detector.record(stackTrace: nil, for: ongoing)

    XCTAssertNotNil(detector.stackTraceIsDue(), "no trace was taken, so the next poll tries again")
  }

  func testStackTraceFromAFinishedHangIsDropped() throws {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.2)
    let ongoing = try XCTUnwrap(detector.stackTraceIsDue())
    _ = detector.willSleep()

    detector.didWake()
    clock.advance(0.3)
    detector.record(stackTrace: CapturedStackTrace(addresses: [0x1000], isTruncated: false), for: ongoing)

    XCTAssertNil(detector.willSleep()?.stackTrace, "the trace belongs to work that has finished")
  }

  // MARK: - Background

  func testHangInProgressIsDroppedWhenTheAppLeavesTheForeground() {
    let detector = makeDetector()
    detector.didWake()
    clock.advance(0.1)
    detector.enteredBackground()
    clock.advance(3600) // suspended, which stops the main thread without hanging it

    XCTAssertNil(detector.willSleep())
  }

  func testNothingIsRecordedWhileTheAppIsInTheBackground() {
    let detector = makeDetector()
    detector.enteredBackground()
    detector.didWake()
    clock.advance(10)

    XCTAssertNil(detector.willSleep())
    XCTAssertNil(detector.stackTraceIsDue())
  }

  func testTheRunLoopPassThatReturnsToTheForegroundIsNoHang() {
    let detector = makeDetector()
    detector.enteredBackground()
    detector.didWake()
    clock.advance(3600)
    detector.enteringForeground()

    XCTAssertNil(detector.willSleep())
  }

  func testHangsAreRecordedAgainAfterReturningToTheForeground() {
    let detector = makeDetector()
    detector.enteredBackground()
    detector.enteringForeground()
    detector.didWake()
    clock.advance(0.5)

    XCTAssertNotNil(detector.willSleep())
  }

  func testADetectorStartedInTheBackgroundRecordsNothing() {
    let detector = HangDetector(configuration: configuration, clock: clock.clock, isForeground: false)
    detector.didWake()
    clock.advance(1)

    XCTAssertNil(detector.willSleep())
  }
}
