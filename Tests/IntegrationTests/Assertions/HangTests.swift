/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest

// The hang launch blocks the main thread for `Scenario.hangDuration`, which the AppHang
// instrumentation must report as one `device.hang` span carrying the main thread's stack trace,
// captured while the thread was still blocked.
final class HangTests: XCTestCase {
  private static let scope = "io.opentelemetry.apphang"
  private static let spanName = "device.hang"
  private static let exceptionTypeKey = "exception.type"
  private static let exceptionMessageKey = "exception.message"
  private static let exceptionStacktraceKey = "exception.stacktrace"
  private static let sessionIdKey = "session.id"

  /// Only the deliberate hang, not the shorter ones a launch produces on the way to it.
  private func deliberateHangs() -> [ExportedSpan] {
    OTLPOutput.launch(.hang).spans.filter {
      $0.scope.name == Self.scope
        && $0.span.name == Self.spanName
        && duration(of: $0) >= Scenario.hangDuration * 0.9
    }
  }

  private func duration(of span: ExportedSpan) -> TimeInterval {
    TimeInterval(span.span.endTimeUnixNano - span.span.startTimeUnixNano) / 1_000_000_000
  }

  func testTheHangIsReportedAsOneSpan() throws {
    let hangs = deliberateHangs()
    XCTAssertEqual(hangs.count, 1, "expected exactly one span for a single blocked main thread")

    let hang = try XCTUnwrap(hangs.first)
    XCTAssertEqual(hang.span.kind, .internal)
    XCTAssertTrue(hang.span.parentSpanID.isEmpty, "a hang belongs to no operation")
    XCTAssertEqual(hang.span.attributes.string(Self.exceptionTypeKey), "hang")
  }

  func testTheSpanLastsAsLongAsTheMainThreadWasBlocked() throws {
    let hang = try XCTUnwrap(deliberateHangs().first)

    // The run loop pass holds the sleep and the work around it, so the span is at least as long
    // as the sleep and not much longer.
    XCTAssertGreaterThanOrEqual(duration(of: hang), Scenario.hangDuration * 0.9)
    XCTAssertLessThan(duration(of: hang), Scenario.hangDuration + 1)
  }

  func testTheHangCarriesTheMainThreadsLiveStackTrace() throws {
    let hang = try XCTUnwrap(deliberateHangs().first)
    let stacktrace = try XCTUnwrap(hang.span.attributes.string(Self.exceptionStacktraceKey))

    XCTAssertTrue(stacktrace.contains("Thread 0:"), stacktrace)
    XCTAssertTrue(stacktrace.contains("Binary Images:"), stacktrace)
    // The main thread was asleep in the kernel, which only a trace taken during the hang shows.
    XCTAssertTrue(stacktrace.contains("libsystem_kernel.dylib"), stacktrace)
    // The frames run through the app's own binary, so the hang is attributable.
    XCTAssertTrue(stacktrace.contains("HackerNewsDemo"), stacktrace)

    let message = try XCTUnwrap(hang.span.attributes.string(Self.exceptionMessageKey))
    XCTAssertTrue(message.hasPrefix("Hang detected at "), message)
    XCTAssertFalse(message.contains("unknown location"), message)
  }

  func testTheHangIsAttributedToTheSessionItHappenedIn() throws {
    let hang = try XCTUnwrap(deliberateHangs().first)
    let probe = try XCTUnwrap(OTLPOutput.launch(.hang).spans.first {
      $0.span.name == Scenario.probeSpanName
    }, "no probe span from the hang launch")

    let session = try XCTUnwrap(probe.span.attributes.string(Self.sessionIdKey))
    XCTAssertEqual(hang.span.attributes.string(Self.sessionIdKey), session)
  }
}
