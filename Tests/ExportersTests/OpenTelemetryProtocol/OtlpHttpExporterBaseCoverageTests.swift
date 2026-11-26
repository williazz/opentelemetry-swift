/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
@testable import OpenTelemetryProtocolExporterHttp
@testable import OpenTelemetrySdk
import XCTest

/// Exercises configuration branches of `OtlpHttpExporterBase` that the
/// existing tests don't reach: env-var headers, config headers, the deprecated
/// URLSession initializer, and body fallback paths.
final class OtlpHttpExporterBaseCoverageTests: XCTestCase {
  private func makeBody() -> Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest {
    Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest()
  }

  func testEnvVarHeadersAppliedOnRequest() {
    let exporter = OtlpHttpExporterBase<SpanData>(
      endpoint: URL(string: "http://example.com")!,
      config: OtlpConfiguration(compression: .none),
      httpClient: BaseHTTPClient(),
      envVarHeaders: [("X-Env-Header", "env-value")])
    let request = exporter.createRequest(body: makeBody(), endpoint: URL(string: "http://example.com")!)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Env-Header"), "env-value")
  }

  func testConfigHeadersAppliedWhenEnvVarHeadersNil() {
    let exporter = OtlpHttpExporterBase<SpanData>(
      endpoint: URL(string: "http://example.com")!,
      config: OtlpConfiguration(headers: [("X-Cfg-Header", "cfg-value")]),
      httpClient: BaseHTTPClient(),
      envVarHeaders: nil)
    let request = exporter.createRequest(body: makeBody(), endpoint: URL(string: "http://example.com")!)
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Cfg-Header"), "cfg-value")
  }

  func testHeadersProviderIsEvaluatedForEveryRequest() throws {
    let provider = MutableHeadersProvider([("Authorization", "Bearer first")])
    let exporter = try OtlpHttpExporterBase<SpanData>(
      endpoint: XCTUnwrap(URL(string: "http://example.com")),
      config: OtlpConfiguration(
        headers: [
          ("X-Static-Header", "static-value"),
          ("authorization", "Bearer static")
        ],
        headersProvider: provider.currentHeaders
      ),
      httpClient: BaseHTTPClient(),
      envVarHeaders: nil
    )

    let firstRequest = try exporter.createRequest(
      body: makeBody(),
      endpoint: XCTUnwrap(URL(string: "http://example.com"))
    )
    provider.update([("Authorization", "Bearer second")])
    let secondRequest = try exporter.createRequest(
      body: makeBody(),
      endpoint: XCTUnwrap(URL(string: "http://example.com"))
    )

    XCTAssertEqual(firstRequest.value(forHTTPHeaderField: "Authorization"), "Bearer first")
    XCTAssertEqual(secondRequest.value(forHTTPHeaderField: "Authorization"), "Bearer second")
    XCTAssertEqual(firstRequest.value(forHTTPHeaderField: "X-Static-Header"), "static-value")
    XCTAssertEqual(secondRequest.value(forHTTPHeaderField: "X-Static-Header"), "static-value")
    XCTAssertEqual(provider.callCount, 2)
  }

  func testEnvVarHeadersTakePrecedenceOverHeadersProvider() throws {
    let provider = MutableHeadersProvider([("Authorization", "Bearer provider")])
    let exporter = try OtlpHttpExporterBase<SpanData>(
      endpoint: XCTUnwrap(URL(string: "http://example.com")),
      config: OtlpConfiguration(headersProvider: provider.currentHeaders),
      httpClient: BaseHTTPClient(),
      envVarHeaders: [("Authorization", "Bearer environment")]
    )

    let request = try exporter.createRequest(
      body: makeBody(),
      endpoint: XCTUnwrap(URL(string: "http://example.com"))
    )

    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer environment")
    XCTAssertEqual(provider.callCount, 0)
  }

  func testNilHeadersProviderRetainsStaticHeaders() throws {
    let provider = MutableHeadersProvider(nil)
    let exporter = try OtlpHttpExporterBase<SpanData>(
      endpoint: XCTUnwrap(URL(string: "http://example.com")),
      config: OtlpConfiguration(
        headers: [("Authorization", "Bearer static")],
        headersProvider: provider.currentHeaders
      ),
      httpClient: BaseHTTPClient(),
      envVarHeaders: nil
    )

    let request = try exporter.createRequest(
      body: makeBody(),
      endpoint: XCTUnwrap(URL(string: "http://example.com"))
    )

    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer static")
    XCTAssertEqual(provider.callCount, 1)
  }

  func testContentTypeAndUserAgentSet() {
    let exporter = OtlpHttpExporterBase<SpanData>(
      endpoint: URL(string: "http://example.com")!,
      config: OtlpConfiguration(compression: .none),
      httpClient: BaseHTTPClient(),
      envVarHeaders: nil)
    let request = exporter.createRequest(body: makeBody(), endpoint: URL(string: "http://example.com")!)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
    XCTAssertNotNil(request.value(forHTTPHeaderField: Constants.HTTP.userAgent))
    XCTAssertEqual(request.httpMethod, "POST")
  }

  @available(*, deprecated)
  func testDeprecatedInitWithURLSession() {
    let session = URLSession(configuration: .ephemeral)
    let exporter = OtlpHttpExporterBase<SpanData>(
      endpoint: URL(string: "http://example.com")!,
      config: OtlpConfiguration(),
      useSession: session,
      envVarHeaders: nil)
    XCTAssertNotNil(exporter)
  }

  @available(*, deprecated)
  func testDeprecatedInitWithNilURLSessionUsesDefault() {
    let exporter = OtlpHttpExporterBase<SpanData>(
      endpoint: URL(string: "http://example.com")!,
      config: OtlpConfiguration(),
      useSession: nil,
      envVarHeaders: nil)
    XCTAssertNotNil(exporter)
  }

  private func makePendingQueueBase(requeueOnFailure: Bool = true) -> OtlpHttpExporterBase<String> {
    OtlpHttpExporterBase<String>(endpoint: URL(string: "http://example.com")!,
                                 httpClient: BaseHTTPClient(),
                                 envVarHeaders: nil,
                                 requeueOnFailure: requeueOnFailure)
  }

  func testSnapshotPendingStartsEmpty() {
    XCTAssertEqual(makePendingQueueBase().snapshotPending(), [])
  }

  func testDrainPendingReturnsAddedSignalsAndClearsPending() {
    let base = makePendingQueueBase()
    XCTAssertEqual(base.drainPending(adding: ["a", "b"]), ["a", "b"])
    XCTAssertEqual(base.snapshotPending(), [])
  }

  func testDrainPendingIncludesPreviouslyRequeuedSignals() {
    let base = makePendingQueueBase()
    base.requeue(["prev"])
    XCTAssertEqual(base.drainPending(adding: ["new"]), ["prev", "new"])
    XCTAssertEqual(base.snapshotPending(), [])
  }

  func testRequeueAppendsSignalsToPending() {
    let base = makePendingQueueBase()
    base.requeue(["a"])
    base.requeue(["b", "c"])
    XCTAssertEqual(base.snapshotPending(), ["a", "b", "c"])
  }

  func testRequeueIsNoOpWhenDisabled() {
    let base = makePendingQueueBase(requeueOnFailure: false)
    base.requeue(["a"])
    XCTAssertEqual(base.snapshotPending(), [])
  }

  func testDropFlushedRemovesSentCountFromPending() {
    let base = makePendingQueueBase()
    base.requeue(["a", "b", "c"])
    base.dropFlushed(count: 2)
    XCTAssertEqual(base.snapshotPending(), ["c"])
  }

  func testDropFlushedDoesNotRemoveMoreThanPending() {
    let base = makePendingQueueBase()
    base.requeue(["a"])
    base.dropFlushed(count: 5)
    XCTAssertEqual(base.snapshotPending(), [])
  }

  func testDropFlushedOnEmptyPendingIsNoOp() {
    let base = makePendingQueueBase()
    base.dropFlushed(count: 1)
    XCTAssertEqual(base.snapshotPending(), [])
  }

  func testPendingQueueOperationsAreThreadSafe() {
    let base = makePendingQueueBase()
    let iterations = 100
    let group = DispatchGroup()

    for i in 0 ..< iterations {
      group.enter()
      DispatchQueue.global().async {
        base.requeue(["\(i)"])
        _ = base.snapshotPending()
        group.leave()
      }
    }

    group.wait()
    XCTAssertEqual(base.snapshotPending().count, iterations)
  }

  // MARK: - Retry and backoff

  private func status(_ code: Int, retryAfter: TimeInterval? = nil) -> HTTPClientError {
    HTTPClientError(description: "status \(code)", statusCode: code, retryAfter: retryAfter)
  }

  private func makeRetryBase(policy: OtlpRetryPolicy = .default,
                             clock: FakeClock,
                             requeueOnFailure: Bool = true) -> OtlpHttpExporterBase<String> {
    OtlpHttpExporterBase<String>(endpoint: URL(string: "http://example.com")!,
                                 httpClient: BaseHTTPClient(),
                                 envVarHeaders: nil,
                                 requeueOnFailure: requeueOnFailure,
                                 retryPolicy: policy,
                                 now: clock.read)
  }

  /// Fails the batch the base is sending, then returns the time the next send may start.
  private func failOnce(_ base: OtlpHttpExporterBase<String>, error: Error) {
    let sending = base.drainPending(adding: [])
    base.recordFailure(of: sending, error: error)
  }

  /// Asserts that the base refuses to send `delay - 1ms` after the failure and accepts at `delay`.
  private func assertBackoff(_ delay: TimeInterval,
                             base: OtlpHttpExporterBase<String>,
                             clock: FakeClock,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
    clock.advance(by: delay - 0.001)
    XCTAssertTrue(base.deferIfBackingOff(adding: []), "must still back off at \(delay - 0.001)s", file: file, line: line)
    clock.advance(by: 0.001)
    XCTAssertFalse(base.deferIfBackingOff(adding: []), "must send again at \(delay)s", file: file, line: line)
  }

  func testBackoffDoublesAfterEachConsecutiveFailure() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["batch"])

    for expected in [1.0, 2.0, 4.0, 8.0, 16.0] {
      failOnce(base, error: status(503))
      assertBackoff(expected, base: base, clock: clock)
    }
    XCTAssertEqual(base.snapshotPending(), ["batch"])
  }

  func testBackoffStopsGrowingAtMaxBackoff() {
    let clock = FakeClock()
    let policy = OtlpRetryPolicy(maxRetries: 10, initialBackoff: 1, maxBackoff: 4)
    let base = makeRetryBase(policy: policy, clock: clock)
    base.requeue(["batch"])

    for expected in [1.0, 2.0, 4.0, 4.0, 4.0] {
      failOnce(base, error: status(429))
      assertBackoff(expected, base: base, clock: clock)
    }
  }

  func testRetryAfterReplacesExponentialDelay() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["batch"])

    failOnce(base, error: status(429, retryAfter: 30))
    assertBackoff(30, base: base, clock: clock)
  }

  func testRetryAfterShorterThanBackoffIsStillHonoured() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["batch"])
    failOnce(base, error: status(503))
    assertBackoff(1, base: base, clock: clock)
    failOnce(base, error: status(503))
    assertBackoff(2, base: base, clock: clock)
    failOnce(base, error: status(503, retryAfter: 0.5))
    assertBackoff(0.5, base: base, clock: clock)
  }

  func testRetryAfterIsCappedAtMaxRetryAfter() {
    let clock = FakeClock()
    let policy = OtlpRetryPolicy(maxRetryAfter: 120)
    let base = makeRetryBase(policy: policy, clock: clock)
    base.requeue(["batch"])

    failOnce(base, error: status(503, retryAfter: 86400))
    assertBackoff(120, base: base, clock: clock)
  }

  func testBatchIsDroppedAfterMaxRetriesAndBackoffResets() {
    let clock = FakeClock()
    let policy = OtlpRetryPolicy(maxRetries: 2)
    let base = makeRetryBase(policy: policy, clock: clock)
    base.requeue(["batch"])

    failOnce(base, error: status(503)) // first send fails: retry 1 of 2
    XCTAssertEqual(base.snapshotPending(), ["batch"])
    clock.advance(by: 1)
    failOnce(base, error: status(503)) // retry 1 fails: retry 2 of 2
    XCTAssertEqual(base.snapshotPending(), ["batch"])
    clock.advance(by: 2)
    failOnce(base, error: status(503)) // retry 2 fails: no retries left
    XCTAssertEqual(base.snapshotPending(), [])
    XCTAssertEqual(base.droppedSignalCount(), 1)
    XCTAssertFalse(base.deferIfBackingOff(adding: ["next"]), "a dropped batch ends the backoff")
  }

  func testNonRetryableStatusDropsTheBatchAtOnce() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["bad"])

    failOnce(base, error: status(400))

    XCTAssertEqual(base.snapshotPending(), [])
    XCTAssertEqual(base.droppedSignalCount(), 1)
    XCTAssertFalse(base.deferIfBackingOff(adding: []), "a 400 starts no backoff")
  }

  func testOnlySpecifiedStatusCodesRetry() {
    let retried = [429, 502, 503, 504]
    let dropped = [400, 401, 403, 404, 413, 500, 501, 505, 507]
    for code in retried + dropped {
      let base = makeRetryBase(clock: FakeClock())
      base.requeue(["batch"])
      failOnce(base, error: status(code))
      XCTAssertEqual(base.snapshotPending().count, retried.contains(code) ? 1 : 0, "status \(code)")
    }
  }

  func testTransportErrorRetries() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["batch"])

    failOnce(base, error: URLError(.networkConnectionLost))

    XCTAssertEqual(base.snapshotPending(), ["batch"])
    assertBackoff(1, base: base, clock: clock)
  }

  func testSuccessEndsBackoffAndResetsTheSchedule() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["batch"])
    failOnce(base, error: status(503))
    assertBackoff(1, base: base, clock: clock)
    failOnce(base, error: status(503))
    XCTAssertTrue(base.deferIfBackingOff(adding: []))

    base.recordSuccess()
    XCTAssertFalse(base.deferIfBackingOff(adding: []))

    base.requeue(["again"])
    failOnce(base, error: status(503))
    assertBackoff(1, base: base, clock: clock) // back to the first step, not 4s
  }

  func testDeferredSignalsWaitInOrderForTheNextSend() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["a"])
    failOnce(base, error: status(503))

    XCTAssertTrue(base.deferIfBackingOff(adding: ["b"]))
    XCTAssertTrue(base.deferIfBackingOff(adding: ["c"]))
    XCTAssertEqual(base.snapshotPending(), ["a", "b", "c"])

    clock.advance(by: 1)
    XCTAssertFalse(base.deferIfBackingOff(adding: ["d"]))
    XCTAssertEqual(base.drainPending(adding: ["d"]), ["a", "b", "c", "d"])
  }

  func testQueueKeepsTheNewestSignalsWhenFull() {
    let policy = OtlpRetryPolicy(maxPendingSignals: 3)
    let base = makeRetryBase(policy: policy, clock: FakeClock())

    base.requeue(["1", "2"])
    base.requeue(["3", "4", "5"])

    XCTAssertEqual(base.snapshotPending(), ["3", "4", "5"])
    XCTAssertEqual(base.droppedSignalCount(), 2)
  }

  func testDeferredSignalsRespectTheQueueBound() {
    let clock = FakeClock()
    let policy = OtlpRetryPolicy(maxPendingSignals: 3)
    let base = makeRetryBase(policy: policy, clock: clock)
    base.requeue(["1", "2"])
    failOnce(base, error: status(503))

    XCTAssertTrue(base.deferIfBackingOff(adding: ["3", "4", "5"]))

    XCTAssertEqual(base.snapshotPending(), ["3", "4", "5"])
    XCTAssertEqual(base.droppedSignalCount(), 2)
  }

  func testQueueOverflowReportsToTheFeedbackHandler() {
    let previous = OpenTelemetry.instance.feedbackHandler
    defer { OpenTelemetry.registerFeedbackHandler(previous ?? { _ in }) }
    let messages = MessageBox()
    OpenTelemetry.registerFeedbackHandler { messages.append($0) }
    let base = makeRetryBase(policy: OtlpRetryPolicy(maxPendingSignals: 1), clock: FakeClock())

    base.requeue(["1", "2"])

    XCTAssertTrue(messages.all.contains { $0.contains("dropped 1 oldest") }, "\(messages.all)")
  }

  func testNoBackoffWhenRequeueIsDisabled() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock, requeueOnFailure: false)

    base.recordFailure(of: ["a"], error: status(503))

    XCTAssertFalse(base.deferIfBackingOff(adding: ["b"]))
    XCTAssertEqual(base.snapshotPending(), [])
    XCTAssertEqual(base.droppedSignalCount(), 0)
  }

  func testFlushFailureStartsBackoffButKeepsTheQueue() {
    let clock = FakeClock()
    let base = makeRetryBase(clock: clock)
    base.requeue(["a", "b"])

    base.recordFlushFailure(sentCount: 2, error: status(503))

    XCTAssertEqual(base.snapshotPending(), ["a", "b"])
    assertBackoff(1, base: base, clock: clock)
  }

  func testFlushFailureWithPermanentErrorDropsTheFlushedSignals() {
    let base = makeRetryBase(clock: FakeClock())
    base.requeue(["a", "b", "c"])

    base.recordFlushFailure(sentCount: 2, error: status(400))

    XCTAssertEqual(base.snapshotPending(), ["c"])
    XCTAssertEqual(base.droppedSignalCount(), 2)
  }

  func testDrainTakesTheOldestBatchAndLeavesTheRest() {
    let policy = OtlpRetryPolicy(maxExportBatchSize: 2)
    let base = makeRetryBase(policy: policy, clock: FakeClock())
    base.requeue(["1", "2", "3"])

    XCTAssertEqual(base.drainPending(adding: ["4"]), ["1", "2"])
    XCTAssertEqual(base.snapshotPending(), ["3", "4"])
  }

  func testFailedBatchReturnsToTheHeadOfTheQueue() {
    let policy = OtlpRetryPolicy(maxExportBatchSize: 2)
    let base = makeRetryBase(policy: policy, clock: FakeClock())
    base.requeue(["1", "2", "3"])
    let sending = base.drainPending(adding: [])

    base.recordFailure(of: sending, error: status(503))

    XCTAssertEqual(base.snapshotPending(), ["1", "2", "3"])
  }

  // MARK: - Policy

  func testPolicyDelayFormula() {
    let policy = OtlpRetryPolicy(initialBackoff: 0.5, multiplier: 3, maxBackoff: 10)
    XCTAssertEqual(policy.delay(afterFailure: 1), 0.5)
    XCTAssertEqual(policy.delay(afterFailure: 2), 1.5)
    XCTAssertEqual(policy.delay(afterFailure: 3), 4.5)
    XCTAssertEqual(policy.delay(afterFailure: 4), 10)
    XCTAssertEqual(policy.delay(afterFailure: 100), 10)
  }

  func testDefaultRetryableStatusCodesMatchTheSpecification() {
    XCTAssertEqual(OtlpRetryPolicy.default.retryableStatusCodes, [429, 502, 503, 504])
  }

  func testParseRetryAfterSeconds() {
    XCTAssertEqual(OtlpRetryPolicy.parseRetryAfter("120"), 120)
    XCTAssertEqual(OtlpRetryPolicy.parseRetryAfter(" 7 "), 7)
    XCTAssertEqual(OtlpRetryPolicy.parseRetryAfter("0"), 0)
    XCTAssertEqual(OtlpRetryPolicy.parseRetryAfter("-5"), 0)
  }

  func testParseRetryAfterHTTPDate() {
    let now = Date(timeIntervalSince1970: 784_111_777) // Sun, 06 Nov 1994 08:49:37 GMT
    XCTAssertEqual(OtlpRetryPolicy.parseRetryAfter("Sun, 06 Nov 1994 08:50:07 GMT", now: now), 30)
    XCTAssertEqual(OtlpRetryPolicy.parseRetryAfter("Sun, 06 Nov 1994 08:00:00 GMT", now: now), 0)
  }

  func testParseRetryAfterRejectsGarbage() {
    XCTAssertNil(OtlpRetryPolicy.parseRetryAfter(nil))
    XCTAssertNil(OtlpRetryPolicy.parseRetryAfter(""))
    XCTAssertNil(OtlpRetryPolicy.parseRetryAfter("soon"))
    XCTAssertNil(OtlpRetryPolicy.parseRetryAfter("nan"))
  }

  func testHTTPClientResultCarriesStatusAndRetryAfter() throws {
    let url = try XCTUnwrap(URL(string: "http://example.com"))
    let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Retry-After": "42"]))
    guard case let .failure(error) = httpClientResult(for: (nil, response, nil)),
          let clientError = error as? HTTPClientError else {
      return XCTFail("expected an HTTPClientError")
    }
    XCTAssertEqual(clientError.statusCode, 429)
    XCTAssertEqual(clientError.retryAfter, 42)
  }
}

/// A clock the test moves by hand.
final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private var time: TimeInterval = 1000

  func advance(by seconds: TimeInterval) {
    lock.lock(); defer { lock.unlock() }
    time += seconds
  }

  var read: @Sendable () -> TimeInterval {
    { [self] in
      lock.lock(); defer { lock.unlock() }
      return time
    }
  }
}

private final class MessageBox: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [String] = []
  func append(_ message: String) {
    lock.lock(); defer { lock.unlock() }
    messages.append(message)
  }

  var all: [String] {
    lock.lock(); defer { lock.unlock() }
    return messages
  }
}
