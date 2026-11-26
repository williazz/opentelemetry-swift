/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

@testable import AppHang
import Foundation
import InMemoryExporter
import OpenTelemetryApi
import OpenTelemetrySdk
import SharedTestUtils
#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif
import XCTest

final class AppHangInstrumentationTests: XCTestCase {
  private var exporter: InMemoryExporter!

  override func setUp() {
    super.setUp()
    exporter = InMemoryExporter()
    OpenTelemetry.registerTracerProvider(
      tracerProvider: TracerProviderSdk(spanProcessors: [SimpleSpanProcessor(spanExporter: exporter)])
    )
  }

  override func tearDown() {
    exporter.reset()
    super.tearDown()
  }

  // MARK: - Configuration

  func testDefaultConfiguration() {
    let configuration = AppHangInstrumentationConfiguration()

    XCTAssertEqual(configuration.hangThreshold, 0.25)
    XCTAssertEqual(configuration.pollInterval, 0.1)
    XCTAssertEqual(configuration.maxFrames, 128)
    XCTAssertTrue(configuration.capturesStackTrace)
    XCTAssertFalse(configuration.includesSymbolNames)
    XCTAssertFalse(configuration.recordsHangsWhileTraced)
    XCTAssertEqual(configuration.resolvedStackTraceThreshold, 0.25 * 2 / 3, accuracy: 0.000_001)
  }

  func testStackTraceThresholdFollowsTheHangThreshold() {
    var configuration = AppHangInstrumentationConfiguration()
    configuration.hangThreshold = 3

    XCTAssertEqual(configuration.resolvedStackTraceThreshold, 2, accuracy: 0.000_001)
  }

  func testThresholdsThatWouldRecordNothingAreReplaced() {
    var configuration = AppHangInstrumentationConfiguration()
    configuration.hangThreshold = 0
    configuration.pollInterval = -1
    configuration.maxFrames = 0

    let validated = AppHangInstrumentationConfiguration.validated(configuration)

    XCTAssertEqual(validated.hangThreshold, 0.25)
    XCTAssertEqual(validated.pollInterval, 0.1)
    XCTAssertEqual(validated.maxFrames, 128)
  }

  func testStackTraceThresholdIsNeverAboveTheHangThreshold() {
    var configuration = AppHangInstrumentationConfiguration()
    configuration.hangThreshold = 1
    configuration.stackTraceThreshold = 5

    let validated = AppHangInstrumentationConfiguration.validated(configuration)

    XCTAssertEqual(validated.resolvedStackTraceThreshold, 1)
  }

  func testNegativeStackTraceThresholdFallsBackToTheDefaultShare() {
    var configuration = AppHangInstrumentationConfiguration()
    configuration.stackTraceThreshold = -1

    let validated = AppHangInstrumentationConfiguration.validated(configuration)

    XCTAssertEqual(validated.resolvedStackTraceThreshold, 0.25 * 2 / 3, accuracy: 0.000_001)
  }

  // MARK: - install()

  /// Installs the real instrumentation, which cannot be uninstalled, so it is configured to
  /// report nothing: every later test in this process blocks the main thread, and a watchdog
  /// left running would record those as hangs into whatever exporter that test registered.
  func testInstallIsIdempotent() {
    var configuration = AppHangInstrumentationConfiguration()
    configuration.hangThreshold = 3600
    configuration.pollInterval = 3600
    configuration.capturesStackTrace = false

    AppHangInstrumentation.install(configuration: configuration)
    AppHangInstrumentation.install(configuration: configuration)

    XCTAssertTrue(AppHangInstrumentation.isInstalled)
    XCTAssertEqual(AppHangInstrumentation.instrumentationScope, "io.opentelemetry.apphang")
  }

  // MARK: - Lifecycle

  #if canImport(UIKit) && !os(watchOS)
    /// A cold launch never posts `willEnterForeground`: it goes from background straight to
    /// active. An app that installs the instrumentation from `didFinishLaunching`, where
    /// `applicationState` can still read `.background`, must still record hangs once it is
    /// running, so the watchdog has to treat `didBecomeActive` as reaching the foreground.
    func testActivationAfterABackgroundLaunchRecordsHangsAgain() {
      let clock = TestClock()
      let configuration = AppHangInstrumentationConfiguration()
      let detector = HangDetector(configuration: configuration, clock: clock.clock, isForeground: false)
      let watchdog = makeWatchdog(configuration: configuration, detector: detector)
      watchdog.start()
      defer { watchdog.stop() }

      detector.didWake()
      clock.advance(1)
      XCTAssertNil(detector.willSleep(), "a backgrounded app records nothing")

      NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

      detector.didWake()
      clock.advance(1)
      XCTAssertNotNil(detector.willSleep(), "an activated app records hangs again")
    }
  #endif

  // MARK: - End to end

  /// Blocks the main thread for half a second and expects the hang to be recorded. The trigger is
  /// a fixed sleep, well above the 250 ms threshold, and the wait is long enough that a loaded
  /// machine still passes; the assertion only requires one span of at least 0.4 s, so unrelated
  /// work on the main run loop cannot fail it.
  func testBlockingTheMainThreadRecordsAHangSpan() throws {
    try XCTSkipIf(ConcurrencyTesting.isThreadSanitizerActive,
                  "blocking the main thread and suspending it is not run under Thread Sanitizer")

    var configuration = AppHangInstrumentationConfiguration()
    // Tests often run under a debugger, where hangs are off by default.
    configuration.recordsHangsWhileTraced = true
    let watchdog = makeWatchdog(configuration: configuration)
    watchdog.start()
    defer { watchdog.stop() }
    activate()

    let found = expectation(description: "a device.hang span of at least 0.4 s")
    found.assertForOverFulfill = false
    let poller = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "AppHangTests.poller"))
    poller.schedule(deadline: .now() + 0.1, repeating: 0.1)
    poller.setEventHandler { [exporter] in
      let hangs = exporter?.getFinishedSpanItems().filter {
        $0.name == "device.hang" && $0.endTime.timeIntervalSince($0.startTime) >= 0.4
      }
      if hangs?.isEmpty == false {
        found.fulfill()
      }
    }
    poller.resume()
    defer { poller.cancel() }

    DispatchQueue.main.async {
      Thread.sleep(forTimeInterval: 0.5)
    }

    wait(for: [found], timeout: 30)

    let hang = try XCTUnwrap(exporter.getFinishedSpanItems().first {
      $0.name == "device.hang" && $0.endTime.timeIntervalSince($0.startTime) >= 0.4
    })
    XCTAssertEqual(hang.attributes["exception.type"], .string("hang"))
    let message = try XCTUnwrap(hang.attributes["exception.message"]?.description)
    XCTAssertTrue(message.hasPrefix("Hang detected at "), message)

    let stacktrace = try XCTUnwrap(hang.attributes["exception.stacktrace"]?.description)
    #if CrashReporting
      XCTAssertTrue(stacktrace.contains("Thread 0:"), stacktrace)
      XCTAssertTrue(stacktrace.contains("Binary Images:"), stacktrace)
      XCTAssertTrue(stacktrace.contains("Hang on the main thread for 0."), stacktrace)
    #else
      XCTAssertEqual(stacktrace, "No stack trace captured")
    #endif
  }

  /// The configuration the demo app uses, symbol names and all, because that is the path a
  /// device exercises: the hang's trace is formatted and demangled on the watchdog thread
  /// before the span is built, so a formatter that stalled there would lose every hang.
  func testHangWithSymbolNamesIsRecorded() throws {
    try XCTSkipIf(ConcurrencyTesting.isThreadSanitizerActive,
                  "blocking the main thread and suspending it is not run under Thread Sanitizer")

    var configuration = AppHangInstrumentationConfiguration()
    configuration.recordsHangsWhileTraced = true
    configuration.includesSymbolNames = true
    let watchdog = makeWatchdog(configuration: configuration)
    watchdog.start()
    defer { watchdog.stop() }
    activate()

    DispatchQueue.main.async {
      Thread.sleep(forTimeInterval: 0.5)
    }

    let hang = try waitForHang()
    XCTAssertEqual(hang.attributes["exception.type"], .string("hang"))
    #if CrashReporting
      let stacktrace = try XCTUnwrap(hang.attributes["exception.stacktrace"]?.description)
      XCTAssertTrue(stacktrace.contains("Thread 0:"), stacktrace)
      XCTAssertFalse(stacktrace.contains("$s"), "Swift names are demangled")
    #endif
  }

  /// The watchdog records nothing until the app becomes active, and a test host is not active,
  /// so the activation an app gets on launch is posted here instead.
  private func activate() {
    #if canImport(UIKit) && !os(watchOS)
      NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    #endif
  }

  /// Polls the exporter for a hang of at least 0.4 s, which is what the half-second sleeps in
  /// these tests produce, and gives a loaded machine 30 seconds to get there.
  private func waitForHang(file: StaticString = #filePath, line: UInt = #line) throws -> SpanData {
    let found = expectation(description: "a device.hang span of at least 0.4 s")
    found.assertForOverFulfill = false
    let poller = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "AppHangTests.poller"))
    poller.schedule(deadline: .now() + 0.1, repeating: 0.1)
    poller.setEventHandler { [exporter] in
      if exporter?.getFinishedSpanItems().contains(where: Self.isHang) == true {
        found.fulfill()
      }
    }
    poller.resume()
    defer { poller.cancel() }

    wait(for: [found], timeout: 30)
    return try XCTUnwrap(exporter.getFinishedSpanItems().first(where: Self.isHang), file: file, line: line)
  }

  private static func isHang(_ span: SpanData) -> Bool {
    span.name == "device.hang" && span.endTime.timeIntervalSince(span.startTime) >= 0.4
  }

  /// The pieces `install()` wires together, built directly so the test can stop them again.
  private func makeWatchdog(configuration: AppHangInstrumentationConfiguration,
                            detector: HangDetector? = nil) -> AppHangWatchdog {
    let reader = makeReader(configuration: configuration)
    return AppHangWatchdog(
      configuration: configuration,
      detector: detector ?? HangDetector(configuration: configuration),
      recorder: HangRecorder(scope: AppHangInstrumentation.instrumentationScope,
                             stackTraceReader: reader,
                             isTraced: DebuggerDetection.isTraced,
                             recordsHangsWhileTraced: configuration.recordsHangsWhileTraced),
      stackTraceReader: reader
    )
  }

  private func makeReader(configuration: AppHangInstrumentationConfiguration) -> MainThreadStackTraceReader {
    #if CrashReporting
      KSCrashStackTraceReader(maxFrames: configuration.maxFrames,
                              includesSymbolNames: configuration.includesSymbolNames)
    #else
      NoMainThreadStackTraceReader()
    #endif
  }
}
