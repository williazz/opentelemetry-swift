/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
import InMemoryExporter
@testable import UserId

private final class InMemoryUserIdPersistence: UserIdPersistence, @unchecked Sendable {
  var stored: String?
  func read() -> String? { stored }
  func write(_ userId: String?) { stored = userId }
}

private final class RecordingLogProcessor: LogRecordProcessor, @unchecked Sendable {
  var records: [ReadableLogRecord] = []
  var shutdownCount = 0
  var flushCount = 0
  func onEmit(logRecord: ReadableLogRecord) { records.append(logRecord) }
  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult { shutdownCount += 1; return .success }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { flushCount += 1; return .success }
}

final class UserIdProcessorTests: XCTestCase {
  private let key = SemanticConventions.User.id.rawValue
  private var manager: UserIdManager!
  private var exporter: InMemoryExporter!
  private var tracer: Tracer!
  private var provider: TracerProviderSdk!

  override func setUp() {
    super.setUp()
    manager = UserIdManager(persistence: InMemoryUserIdPersistence())
    exporter = InMemoryExporter()
    provider = TracerProviderBuilder()
      .add(spanProcessor: UserIdSpanProcessor(userIdManager: manager))
      .add(spanProcessor: SimpleSpanProcessor(spanExporter: exporter))
      .build()
    tracer = provider.get(instrumentationName: "UserIdProcessorTests")
  }

  private func finishedSpans() -> [SpanData] {
    provider.forceFlush()
    return exporter.getFinishedSpanItems()
  }

  private func exportedSpan() throws -> SpanData {
    try XCTUnwrap(finishedSpans().last, "no span exported")
  }

  func testSpanKeyIsTheUpstreamUserId() throws {
    XCTAssertEqual(key, "user.id")
  }

  func testSpanCarriesUserId() throws {
    manager.setUserId("account-1")
    tracer.spanBuilder(spanName: "s").startSpan().end()
    XCTAssertEqual(try exportedSpan().attributes[key], .string("account-1"))
  }

  func testSpanCarriesNothingBeforeOptIn() throws {
    tracer.spanBuilder(spanName: "s").startSpan().end()
    XCTAssertNil(try exportedSpan().attributes[key])
  }

  func testSpanCarriesNothingAfterClear() throws {
    manager.setUserId("account-1")
    manager.clearUserId()
    tracer.spanBuilder(spanName: "s").startSpan().end()
    XCTAssertNil(try exportedSpan().attributes[key])
  }

  func testSpanTakesTheCurrentValueAtStart() throws {
    manager.setUserId("account-1")
    let first = tracer.spanBuilder(spanName: "first").startSpan()
    manager.setUserId("account-2")
    let second = tracer.spanBuilder(spanName: "second").startSpan()
    first.end()
    second.end()
    let byName = Dictionary(uniqueKeysWithValues: finishedSpans().map { ($0.name, $0) })
    XCTAssertEqual(byName["first"]?.attributes[key], .string("account-1"))
    XCTAssertEqual(byName["second"]?.attributes[key], .string("account-2"))
  }

  func testSpanKeepsAnExplicitUserId() throws {
    manager.setUserId("account-1")
    let span = tracer.spanBuilder(spanName: "s").setAttribute(key: key, value: "explicit").startSpan()
    span.end()
    XCTAssertEqual(try exportedSpan().attributes[key], .string("explicit"))
  }

  func testSpanProcessorStartsOnlyAndNeedsNoEnd() throws {
    let processor = UserIdSpanProcessor(userIdManager: manager)
    XCTAssertTrue(processor.isStartRequired)
    XCTAssertFalse(processor.isEndRequired)
  }

  // MARK: Logs

  private func record(attributes: [String: AttributeValue] = [:]) -> ReadableLogRecord {
    ReadableLogRecord(
      resource: Resource(attributes: [:]),
      instrumentationScopeInfo: InstrumentationScopeInfo(),
      timestamp: Date(),
      observedTimestamp: Date(),
      spanContext: nil,
      severity: .info,
      body: .string("body"),
      attributes: attributes
    )
  }

  func testLogRecordCarriesUserId() {
    let next = RecordingLogProcessor()
    manager.setUserId("account-1")
    UserIdLogRecordProcessor(nextProcessor: next, userIdManager: manager).onEmit(logRecord: record())
    XCTAssertEqual(next.records.count, 1)
    XCTAssertEqual(next.records[0].attributes[key], .string("account-1"))
  }

  func testLogRecordPassesUnchangedBeforeOptIn() {
    let next = RecordingLogProcessor()
    UserIdLogRecordProcessor(nextProcessor: next, userIdManager: manager)
      .onEmit(logRecord: record(attributes: ["a": .string("b")]))
    XCTAssertEqual(next.records.count, 1)
    XCTAssertNil(next.records[0].attributes[key])
    XCTAssertEqual(next.records[0].attributes["a"], .string("b"))
  }

  func testLogRecordKeepsAnExplicitUserId() {
    let next = RecordingLogProcessor()
    manager.setUserId("account-1")
    UserIdLogRecordProcessor(nextProcessor: next, userIdManager: manager)
      .onEmit(logRecord: record(attributes: [key: .string("explicit")]))
    XCTAssertEqual(next.records[0].attributes[key], .string("explicit"))
  }

  func testLogProcessorDelegatesLifecycle() {
    let next = RecordingLogProcessor()
    let processor = UserIdLogRecordProcessor(nextProcessor: next, userIdManager: manager)
    XCTAssertEqual(processor.forceFlush(explicitTimeout: nil), .success)
    XCTAssertEqual(processor.shutdown(explicitTimeout: nil), .success)
    XCTAssertEqual(next.flushCount, 1)
    XCTAssertEqual(next.shutdownCount, 1)
  }
}
