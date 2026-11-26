/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

@testable import AppHang
import Foundation
import InMemoryExporter
@testable import OpenTelemetryApi
import OpenTelemetrySdk
import SharedTestUtils
import XCTest

/// Returns the frames and text it is told to, so a span's attributes can be asserted exactly.
struct StubStackTraceReader: MainThreadStackTraceReader {
  var capture: CapturedStackTrace?
  var stackTrace = HangStackTrace(message: "Hang detected at MyApp + 128", stacktrace: "Thread 0:\n0 MyApp")
  /// The durations `format` was called with, in order.
  let durations = Durations()

  final class Durations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    var all: [TimeInterval] { lock.withLock { values } }
    func append(_ value: TimeInterval) { lock.withLock { values.append(value) } }
  }

  func capture(thread: MainThreadID) -> CapturedStackTrace? { capture }

  func format(_ capture: CapturedStackTrace, duration: TimeInterval) -> HangStackTrace {
    durations.append(duration)
    return stackTrace
  }
}

final class HangRecorderTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)
  private var exporter: InMemoryExporter!
  private var provider: TracerProviderSdk!

  override func setUp() {
    super.setUp()
    exporter = InMemoryExporter()
    provider = TracerProviderSdk(spanProcessors: [SimpleSpanProcessor(spanExporter: exporter)])
    OpenTelemetry.registerTracerProvider(tracerProvider: provider)
  }

  override func tearDown() {
    exporter.reset()
    super.tearDown()
  }

  private func makeRecorder(reader: MainThreadStackTraceReader = StubStackTraceReader(),
                            isTraced: @escaping () -> Bool = { false },
                            recordsHangsWhileTraced: Bool = false) -> HangRecorder {
    HangRecorder(scope: AppHangInstrumentation.instrumentationScope,
                 stackTraceReader: reader,
                 isTraced: isTraced,
                 recordsHangsWhileTraced: recordsHangsWhileTraced)
  }

  /// `SimpleSpanProcessor` exports on its own queue, so the flush is what makes reading the
  /// exporter deterministic rather than a race with the export.
  private func exportedSpans() -> [SpanData] {
    provider.forceFlush()
    return exporter.getFinishedSpanItems()
  }

  private func hang(duration: TimeInterval, stackTrace: CapturedStackTrace?) -> HangDetector.Hang {
    HangDetector.Hang(start: start, duration: duration, stackTrace: stackTrace)
  }

  func testHangWithAStackTraceIsOneSpan() throws {
    let reader = StubStackTraceReader()
    makeRecorder(reader: reader)
      .record(hang(duration: 1.5, stackTrace: CapturedStackTrace(addresses: [0x1000], isTruncated: false)))

    let span = try XCTUnwrap(exportedSpans().first)
    XCTAssertEqual(exportedSpans().count, 1)
    XCTAssertEqual(span.name, "device.hang")
    XCTAssertEqual(span.kind, .internal)
    XCTAssertEqual(span.startTime, start)
    XCTAssertEqual(span.endTime, start.addingTimeInterval(1.5))
    XCTAssertEqual(span.attributes["exception.type"], .string("hang"))
    XCTAssertEqual(span.attributes["exception.message"], .string(reader.stackTrace.message))
    XCTAssertEqual(span.attributes["exception.stacktrace"], .string(reader.stackTrace.stacktrace))
    XCTAssertEqual(reader.durations.all, [1.5], "the formatted trace reports the hang's duration")
  }

  func testHangWithoutAStackTraceStillRecordsItsTiming() throws {
    makeRecorder().record(hang(duration: 0.4, stackTrace: nil))

    let span = try XCTUnwrap(exportedSpans().first)
    XCTAssertEqual(span.name, "device.hang")
    XCTAssertEqual(span.endTime.timeIntervalSince(span.startTime), 0.4, accuracy: 0.000_001)
    XCTAssertEqual(span.attributes["exception.type"], .string("hang"))
    XCTAssertEqual(span.attributes["exception.message"], .string("Hang detected at unknown location"))
    XCTAssertEqual(span.attributes["exception.stacktrace"], .string("No stack trace captured"))
  }

  /// The context manager is swapped for the thread-local one, because the activity-based
  /// default leaves the span active for the rest of the process and the spans of every later
  /// test in this bundle would inherit it.
  func testHangIsARootSpan() throws {
    try OpenTelemetry.withContextManager(ThreadLocalContextManager()) {
      let parent = provider.get(instrumentationName: "test").spanBuilder(spanName: "parent").startSpan()
      OpenTelemetry.instance.contextProvider.setActiveSpan(parent)
      defer {
        OpenTelemetry.instance.contextProvider.removeContextForSpan(parent)
        parent.end()
      }

      makeRecorder().record(hang(duration: 1, stackTrace: nil))

      let span = try XCTUnwrap(exportedSpans().first { $0.name == "device.hang" })
      XCTAssertNil(span.parentSpanId, "a hang belongs to no operation, so it starts its own trace")
    }
  }

  func testHangIsDroppedWhileADebuggerIsAttached() {
    makeRecorder(isTraced: { true }).record(hang(duration: 1, stackTrace: nil))

    XCTAssertEqual(exportedSpans().count, 0)
  }

  func testHangIsRecordedUnderADebuggerWhenAskedFor() {
    makeRecorder(isTraced: { true }, recordsHangsWhileTraced: true).record(hang(duration: 1, stackTrace: nil))

    XCTAssertEqual(exportedSpans().count, 1)
  }
}
