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

/// Minimal HTTPClient stub that the HTTP exporters delegate to, so we can drive
/// them through success/failure paths without needing a live server. Keeps test
/// semantics deterministic and exercises the exporter's fallback / metric
/// branches.
private final class StubHTTPClient: HTTPClient {
  enum Outcome {
    case success
    case failure(Error)
    /// A rejected request, as `BaseHTTPClient` reports it.
    case http(status: Int, retryAfter: TimeInterval? = nil)
  }
  var outcomes: [Outcome]
  private(set) var sentRequests: [URLRequest] = []
  init(outcomes: [Outcome]) { self.outcomes = outcomes }
  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sentRequests.append(request)
    let next = outcomes.isEmpty ? .success : outcomes.removeFirst()
    switch next {
    case .success:
      let resp = HTTPURLResponse(url: request.url!,
                                 statusCode: 200,
                                 httpVersion: "HTTP/1.1",
                                 headerFields: nil)!
      completion(.success(resp))
    case .failure(let err):
      completion(.failure(err))
    case let .http(status, retryAfter):
      completion(.failure(HTTPClientError(description: "status \(status)", statusCode: status, retryAfter: retryAfter)))
    }
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sentRequests.append(request)
    let next = outcomes.isEmpty ? .success : outcomes.removeFirst()
    switch next {
    case .success:
      return HTTPURLResponse(url: request.url!,
                             statusCode: 200,
                             httpVersion: "HTTP/1.1",
                             headerFields: nil)!
    case .failure(let err):
      throw err
    case let .http(status, retryAfter):
      throw HTTPClientError(description: "status \(status)", statusCode: status, retryAfter: retryAfter)
    }
  }
}

private struct TransientNetworkError: Error {}

/// Fails the first request, then never invokes the completion handler. This gives
/// `flush()` pending data to send and no response to wait on — the shape that made
/// an unbounded `semaphore.wait()` block the calling thread forever.
private final class HangingHTTPClient: HTTPClient {
  private(set) var sentRequests: [URLRequest] = []
  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sentRequests.append(request)
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sentRequests.append(request)
    return await withCheckedContinuation { (_: CheckedContinuation<HTTPURLResponse, Never>) in }
  }
}

private final class DelayedFailureHTTPClient: HTTPClient {
  private let delay: TimeInterval
  private(set) var sentRequests: [URLRequest] = []

  init(delay: TimeInterval) {
    self.delay = delay
  }

  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sentRequests.append(request)
    nonisolated(unsafe) let completion = completion
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
      completion(.failure(TransientNetworkError()))
    }
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sentRequests.append(request)
    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    throw TransientNetworkError()
  }
}

private final class HangingAfterFirstFailureHTTPClient: HTTPClient {
  private var sendCount = 0
  func send(request: URLRequest,
            completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
    sendCount += 1
    if sendCount == 1 {
      completion(.failure(TransientNetworkError()))
    }
  }

  func send(request: URLRequest) async throws -> HTTPURLResponse {
    sendCount += 1
    if sendCount == 1 {
      throw TransientNetworkError()
    }
    return await withCheckedContinuation { (_: CheckedContinuation<HTTPURLResponse, Never>) in }
  }
}

private func sampleLogRecord() -> ReadableLogRecord {
  let ctx = SpanContext.create(traceId: TraceId.random(),
                               spanId: SpanId.random(),
                               traceFlags: TraceFlags(),
                               traceState: TraceState())
  return ReadableLogRecord(resource: Resource(),
                           instrumentationScopeInfo: InstrumentationScopeInfo(name: "scope"),
                           timestamp: Date(),
                           observedTimestamp: Date(),
                           spanContext: ctx,
                           severity: .info,
                           body: .string("hello"),
                           attributes: [:])
}

private func sampleSpanData() -> SpanData {
  SpanData(traceId: TraceId.random(),
           spanId: SpanId.random(),
           traceFlags: TraceFlags(),
           traceState: TraceState(),
           resource: Resource(),
           instrumentationScope: InstrumentationScopeInfo(),
           name: "span",
           kind: .internal,
           startTime: Date(),
           endTime: Date(),
           hasRemoteParent: false)
}

final class OtlpHttpLogExporterCoverageTests: XCTestCase {
  func testExportFailurePutsRecordsBackInPending() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)

    let rec = sampleLogRecord()
    let result = exporter.export(logRecords: [rec])
    XCTAssertEqual(result, .failure)

    // Failure path should put the record back into the pending queue.
    XCTAssertEqual(base.snapshotPending().count, 1)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testExportWaitsForDelayedFailureBeforeReturning() {
    let delay: TimeInterval = 0.05
    let client = DelayedFailureHTTPClient(delay: delay)
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)

    let start = Date()
    let result = exporter.export(logRecords: [sampleLogRecord()])

    XCTAssertEqual(result, .failure)
    XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), delay)
    XCTAssertEqual(base.snapshotPending().count, 1)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testExportTimesOutWhenResponseNeverArrives() {
    let timeout: TimeInterval = 0.05
    let client = HangingHTTPClient()
    let exporter = OtlpHttpLogExporter(config: OtlpConfiguration(timeout: timeout),
                                       httpClient: client)

    let returned = expectation(description: "export returns after its timeout")
    DispatchQueue.global().async {
      XCTAssertEqual(exporter.export(logRecords: [sampleLogRecord()]), .failure)
      returned.fulfill()
    }
    wait(for: [returned], timeout: 5)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testExportFailureWithRequeueDisabledLeavesPendingEmpty() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client,
                                                       requeueOnFailure: false)
    let exporter = OtlpHttpLogExporter(base: base)

    _ = exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testFlushWithPendingLogRecordsSuccess() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)

    _ = exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let flushResult = exporter.flush()
    XCTAssertEqual(flushResult, .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    // flush() must drop successfully-flushed records; otherwise every
    // subsequent flush re-sends them.
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testFlushWithNoPendingReturnsSuccess() {
    let client = StubHTTPClient(outcomes: [])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    XCTAssertEqual(exporter.flush(), .success)
    XCTAssertEqual(client.sentRequests.count, 0)
  }

  func testForceFlushDelegatesToFlush() {
    let client = StubHTTPClient(outcomes: [])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    XCTAssertEqual(exporter.forceFlush(), .success)
  }

  func testFlushWithEnvVarHeadersAppliesHeaders() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let exporter = OtlpHttpLogExporter(
      httpClient: client,
      envVarHeaders: [("X-Test", "value")])
    _ = exporter.export(logRecords: [sampleLogRecord()])
    _ = exporter.flush()
    XCTAssertEqual(client.sentRequests.last?.value(forHTTPHeaderField: "X-Test"), "value")
  }

  func testFlushWithConfigHeadersAppliesHeaders() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let config = OtlpConfiguration(headers: [("X-Config", "c-value")])
    let exporter = OtlpHttpLogExporter(config: config, httpClient: client, envVarHeaders: nil)
    _ = exporter.export(logRecords: [sampleLogRecord()])
    _ = exporter.flush()
    XCTAssertEqual(client.sentRequests.last?.value(forHTTPHeaderField: "X-Config"), "c-value")
  }

  func testFlushRefreshesHeadersProvider() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let provider = MutableHeadersProvider([("Authorization", "Bearer first")])
    let exporter = OtlpHttpLogExporter(
      config: OtlpConfiguration(headersProvider: provider.currentHeaders),
      httpClient: client,
      envVarHeaders: nil
    )

    _ = exporter.export(logRecords: [sampleLogRecord()])
    provider.update([("Authorization", "Bearer second")])
    XCTAssertEqual(exporter.flush(), .success)

    XCTAssertEqual(client.sentRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer first")
    XCTAssertEqual(client.sentRequests[1].value(forHTTPHeaderField: "Authorization"), "Bearer second")
    XCTAssertEqual(provider.callCount, 2)
  }

  func testFlushFailureAfterRetryReturnsFailure() {
    // export fails → record goes back to pending. flush also fails → exporter
    // reports .failure and exercises the failure branch inside flush().
    let client = StubHTTPClient(outcomes: [
      .failure(TransientNetworkError()),
      .failure(TransientNetworkError())
    ])
    let exporter = OtlpHttpLogExporter(httpClient: client)
    _ = exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(exporter.flush(), .failure)
  }

  func testExportDuringBackoffQueuesRecordsWithoutSending() {
    let client = StubHTTPClient(outcomes: [.http(status: 503), .success])
    let clock = FakeClock()
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       httpClient: client,
                                                       envVarHeaders: nil,
                                                       now: clock.read)
    let exporter = OtlpHttpLogExporter(base: base)

    _ = exporter.export(logRecords: [sampleLogRecord()])
    clock.advance(by: 0.5)
    XCTAssertEqual(exporter.export(logRecords: [sampleLogRecord()]), .failure)
    XCTAssertEqual(client.sentRequests.count, 1)
    XCTAssertEqual(base.snapshotPending().count, 2)

    clock.advance(by: 0.5)
    XCTAssertEqual(exporter.export(logRecords: [sampleLogRecord()]), .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }
}

final class OtlpHttpTraceExporterCoverageTests: XCTestCase {
  func testExportSuccessSendsRequest() {
    let client = StubHTTPClient(outcomes: [.success])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    let result = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(result, .success)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testExportFailureReturnsFailure() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    let result = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(result, .failure)
  }

  func testExportFailureWithRequeueDisabledLeavesPendingEmpty() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              httpClient: client,
                                              requeueOnFailure: false)
    let exporter = OtlpHttpTraceExporter(base: base)
    let result = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(result, .failure)
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }

  func testFlushWithPendingSpans() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError()), .success])
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              httpClient: client)
    let exporter = OtlpHttpTraceExporter(base: base)
    _ = exporter.export(spans: [sampleSpanData()])  // failure → back to pending
    XCTAssertEqual(exporter.flush(), .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    // flush() must drop successfully-flushed spans.
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testFlushWithNoPendingReturnsSuccess() {
    let client = StubHTTPClient(outcomes: [])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    XCTAssertEqual(exporter.flush(), .success)
  }

  func testShutdownReturnsWithoutError() {
    let client = StubHTTPClient(outcomes: [])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    exporter.shutdown()
  }

  func testFlushFailureAfterRetryReturnsFailure() {
    // export fails, then flush also fails — exercises the .failure branch
    // inside flush() and increments the failure metric counter.
    let client = StubHTTPClient(outcomes: [
      .failure(TransientNetworkError()),
      .failure(TransientNetworkError())
    ])
    let exporter = OtlpHttpTraceExporter(httpClient: client)
    _ = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(exporter.flush(), .failure)
  }

  func testFlushFailureWithMeterProviderRecordsFailedCounter() {
    // The failure branch in flush() calls `addFailed` on ExporterMetrics when a
    // meter provider was wired in, exercising a different statement.
    let client = StubHTTPClient(outcomes: [
      .failure(TransientNetworkError()),
      .failure(TransientNetworkError())
    ])
    let provider = MeterProviderSdk.builder().build()
    let exporter = OtlpHttpTraceExporter(endpoint: URL(string: "http://x")!,
                                          config: OtlpConfiguration(),
                                          meterProvider: provider,
                                          httpClient: client,
                                          envVarHeaders: nil)
    _ = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(exporter.flush(), .failure)
  }

  func testDefaultEndpointHelper() {
    XCTAssertEqual(defaultOltpHttpTracesEndpoint().absoluteString,
                   "http://localhost:4318/v1/traces")
  }

  func testConvenienceInitWithMeterProvider() {
    let client = StubHTTPClient(outcomes: [])
    let provider = MeterProviderSdk.builder().build()
    let exporter = OtlpHttpTraceExporter(endpoint: URL(string: "http://x")!,
                                          config: OtlpConfiguration(),
                                          meterProvider: provider,
                                          httpClient: client,
                                          envVarHeaders: nil)
    XCTAssertNotNil(exporter)
  }

  // MARK: - Retry and backoff

  private func makeRetryExporter(client: StubHTTPClient,
                                 clock: FakeClock,
                                 policy: OtlpRetryPolicy = .default)
    -> (OtlpHttpTraceExporter, OtlpHttpExporterBase<SpanData>) {
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              config: OtlpConfiguration(compression: .none),
                                              httpClient: client,
                                              envVarHeaders: nil,
                                              retryPolicy: policy,
                                              now: clock.read)
    return (OtlpHttpTraceExporter(base: base), base)
  }

  private func spanCount(in request: URLRequest) throws -> Int {
    let body = try XCTUnwrap(request.httpBody)
    let message = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: body)
    return message.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans).count
  }

  func testExportDoesNotSendDuringBackoffAndResumesAfterTheDelay() throws {
    let client = StubHTTPClient(outcomes: [.http(status: 503), .success])
    let clock = FakeClock()
    let (exporter, base) = makeRetryExporter(client: client, clock: clock)

    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .failure)
    XCTAssertEqual(client.sentRequests.count, 1)

    // 0.999 s after a 503, the one-second backoff still holds. The span waits in the queue.
    clock.advance(by: 0.999)
    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .failure)
    XCTAssertEqual(client.sentRequests.count, 1, "no request may leave during the backoff")
    XCTAssertEqual(base.snapshotPending().count, 2)

    // At one second the exporter sends both spans in a single request.
    clock.advance(by: 0.001)
    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .success)
    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(try spanCount(in: client.sentRequests[1]), 3)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testExportHonoursRetryAfterFromTheServer() {
    let client = StubHTTPClient(outcomes: [.http(status: 429, retryAfter: 30), .success])
    let clock = FakeClock()
    let (exporter, _) = makeRetryExporter(client: client, clock: clock)

    _ = exporter.export(spans: [sampleSpanData()])
    clock.advance(by: 29.9)
    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .failure)
    XCTAssertEqual(client.sentRequests.count, 1)

    clock.advance(by: 0.1)
    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .success)
    XCTAssertEqual(client.sentRequests.count, 2)
  }

  func testExportBackoffGrowsAcrossRepeatedServerFailures() {
    let client = StubHTTPClient(outcomes: [.http(status: 503), .http(status: 503), .http(status: 503), .success])
    let clock = FakeClock()
    let (exporter, _) = makeRetryExporter(client: client, clock: clock)

    var sentAt: [TimeInterval] = []
    var elapsed: TimeInterval = 0
    // Offer a span every 0.5 s of fake time until the fourth request succeeds. Record when each leaves.
    for _ in 0 ..< 15 {
      let before = client.sentRequests.count
      _ = exporter.export(spans: [sampleSpanData()])
      if client.sentRequests.count > before { sentAt.append(elapsed) }
      clock.advance(by: 0.5)
      elapsed += 0.5
    }

    // Sends at 0 s, then 1 s, 3 s (1 + 2) and 7 s (1 + 2 + 4) after each failure.
    XCTAssertEqual(sentAt, [0, 1, 3, 7])
  }

  func testPermanentRejectionDropsTheSpansAndSendsNoRetry() {
    let client = StubHTTPClient(outcomes: [.http(status: 400), .success])
    let (exporter, base) = makeRetryExporter(client: client, clock: FakeClock())

    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .failure)
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(base.droppedSignalCount(), 1)

    // No backoff follows, so the next export goes out at once, carrying only the new span.
    XCTAssertEqual(exporter.export(spans: [sampleSpanData()]), .success)
    XCTAssertEqual(client.sentRequests.count, 2)
  }

  func testSpansDropAfterTheRetryLimit() {
    let client = StubHTTPClient(outcomes: [.http(status: 503), .http(status: 503), .http(status: 503)])
    let clock = FakeClock()
    let (exporter, base) = makeRetryExporter(client: client, clock: clock, policy: OtlpRetryPolicy(maxRetries: 2))

    _ = exporter.export(spans: [sampleSpanData()])
    clock.advance(by: 1)
    _ = exporter.export(spans: [])
    clock.advance(by: 2)
    _ = exporter.export(spans: [])

    XCTAssertEqual(client.sentRequests.count, 3)
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(base.droppedSignalCount(), 1)
  }

  func testFlushIgnoresTheBackoffAndSendsOnce() {
    let client = StubHTTPClient(outcomes: [.http(status: 503), .success])
    let (exporter, base) = makeRetryExporter(client: client, clock: FakeClock())

    _ = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(exporter.flush(), .success)

    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testShutdownSendsTheQueuedSpansDuringBackoff() {
    let client = StubHTTPClient(outcomes: [.http(status: 503), .success])
    let (exporter, base) = makeRetryExporter(client: client, clock: FakeClock())

    _ = exporter.export(spans: [sampleSpanData()])
    // The batch processor's final export lands inside the backoff and joins the queue.
    _ = exporter.export(spans: [sampleSpanData()])
    XCTAssertEqual(client.sentRequests.count, 1)

    exporter.shutdown()

    XCTAssertEqual(client.sentRequests.count, 2)
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testShutdownReturnsWithinTheShutdownTimeoutWhenTheServerHangs() {
    let client = HangingAfterFirstFailureHTTPClient()
    let base = OtlpHttpExporterBase<SpanData>(endpoint: defaultOltpHttpTracesEndpoint(),
                                              httpClient: client,
                                              retryPolicy: OtlpRetryPolicy(shutdownTimeout: 0.1))
    let exporter = OtlpHttpTraceExporter(base: base)
    _ = exporter.export(spans: [sampleSpanData()])

    let start = Date()
    exporter.shutdown()

    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func testExportDuringBackoffReturnsWithoutWaiting() {
    let client = StubHTTPClient(outcomes: [.http(status: 503)])
    let (exporter, _) = makeRetryExporter(client: client, clock: FakeClock())
    _ = exporter.export(spans: [sampleSpanData()])

    let start = Date()
    _ = exporter.export(spans: [sampleSpanData()])

    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
  }

  func testQueueLargerThanTheBatchBoundLeavesInSeveralRequests() throws {
    let client = StubHTTPClient(outcomes: [])
    let (exporter, base) = makeRetryExporter(client: client, clock: FakeClock(),
                                             policy: OtlpRetryPolicy(maxExportBatchSize: 2))

    XCTAssertEqual(exporter.export(spans: (0 ..< 5).map { _ in sampleSpanData() }), .success)
    XCTAssertEqual(try spanCount(in: client.sentRequests[0]), 2, "one request carries at most the bound")
    XCTAssertEqual(base.snapshotPending().count, 3)

    // flush empties the rest in as many requests as it needs.
    XCTAssertEqual(exporter.flush(), .success)
    XCTAssertEqual(try client.sentRequests.map(spanCount(in:)), [2, 2, 1])
    XCTAssertEqual(base.snapshotPending().count, 0)
  }

  func testPayloadTooLargeDropsOnlyOneBatchNotTheQueue() {
    let client = StubHTTPClient(outcomes: [.http(status: 413)])
    let (exporter, base) = makeRetryExporter(client: client, clock: FakeClock(),
                                             policy: OtlpRetryPolicy(maxExportBatchSize: 2))

    XCTAssertEqual(exporter.export(spans: (0 ..< 5).map { _ in sampleSpanData() }), .failure)

    XCTAssertEqual(base.droppedSignalCount(), 2)
    XCTAssertEqual(base.snapshotPending().count, 3, "the rest of the queue survives a 413")
    XCTAssertFalse(base.deferIfBackingOff(adding: []))
  }
}

final class OtlpHttpExporterFlushTimeoutTests: XCTestCase {
  private let timeout: TimeInterval = 0.5

  func testMetricFlushTimesOutWhenResponseNeverArrives() {
    let client = HangingAfterFirstFailureHTTPClient()
    let endpoint = URL(string: "http://localhost:4318/v1/metrics")!
    let base = OtlpHttpExporterBase<MetricData>(endpoint: endpoint,
                                                config: OtlpConfiguration(timeout: timeout),
                                                httpClient: client)
    let exporter = OtlpHttpMetricExporter(base: base,
                                          aggregationTemporalitySelector: AggregationTemporality.alwaysCumulative(),
                                          defaultAggregationSelector: AggregationSelector.instance)
    _ = exporter.export(metrics: [.empty])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let returned = expectation(description: "flush returns after its timeout")
    DispatchQueue.global().async {
      XCTAssertEqual(exporter.flush(), .failure)
      returned.fulfill()
    }
    wait(for: [returned], timeout: 5)
  }

  func testLogFlushTimesOutWhenResponseNeverArrives() {
    let client = HangingAfterFirstFailureHTTPClient()
    let base = OtlpHttpExporterBase<ReadableLogRecord>(endpoint: defaultOltpHttpLoggingEndpoint(),
                                                       config: OtlpConfiguration(timeout: timeout),
                                                       httpClient: client)
    let exporter = OtlpHttpLogExporter(base: base)
    _ = exporter.export(logRecords: [sampleLogRecord()])
    XCTAssertEqual(base.snapshotPending().count, 1)

    let returned = expectation(description: "flush returns after its timeout")
    DispatchQueue.global().async {
      XCTAssertEqual(exporter.flush(), .failure)
      returned.fulfill()
    }
    wait(for: [returned], timeout: 5)
  }

  func testExportFailureWithRequeueDisabledLeavesPendingEmpty() {
    let client = StubHTTPClient(outcomes: [.failure(TransientNetworkError())])
    let endpoint = URL(string: "http://localhost:4318/v1/metrics")!
    let base = OtlpHttpExporterBase<MetricData>(endpoint: endpoint,
                                                httpClient: client,
                                                requeueOnFailure: false)
    let exporter = OtlpHttpMetricExporter(base: base,
                                          aggregationTemporalitySelector: AggregationTemporality.alwaysCumulative(),
                                          defaultAggregationSelector: AggregationSelector.instance)
    _ = exporter.export(metrics: [.empty])
    XCTAssertEqual(base.snapshotPending().count, 0)
    XCTAssertEqual(client.sentRequests.count, 1)
  }
}

final class OtlpHttpLogExporterDefaultEndpointTests: XCTestCase {
  func testDefaultEndpointHelper() {
    XCTAssertEqual(defaultOltpHttpLoggingEndpoint().absoluteString,
                   "http://localhost:4318/v1/logs")
  }

  func testConvenienceInitWithMeterProvider() {
    let provider = MeterProviderSdk.builder().build()
    let exporter = OtlpHttpLogExporter(endpoint: URL(string: "http://x")!,
                                        config: OtlpConfiguration(),
                                        meterProvider: provider,
                                        httpClient: BaseHTTPClient(),
                                        envVarHeaders: nil)
    XCTAssertNotNil(exporter)
  }
}
