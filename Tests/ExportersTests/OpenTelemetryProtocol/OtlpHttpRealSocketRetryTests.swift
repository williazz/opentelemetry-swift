/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

#if canImport(Network)
import Foundation
import Network
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
@testable import OpenTelemetryProtocolExporterHttp
@testable import OpenTelemetrySdk
import XCTest

/// A real HTTP/1.1 server on an ephemeral TCP port. It records every request body and answers by request number.
final class SocketServer: @unchecked Sendable {
  struct Record { let at: TimeInterval; let status: Int; let names: [String] }
  private let lock = NSLock()
  private var records: [Record] = []
  private var count = 0
  private var listener: NWListener?
  /// The port the operating system assigned. Valid after `start()`.
  private(set) var port: UInt16
  let respond: @Sendable (Int) -> (Int, [String: String])
  let t0 = Date()

  init(port: UInt16 = 0, respond: @escaping @Sendable (Int) -> (Int, [String: String])) {
    self.port = port; self.respond = respond
  }

  func start() throws {
    let l = try port == 0 ? NWListener(using: .tcp) : NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
    l.newConnectionHandler = { [self] c in handle(c, Data()) }
    let ready = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    l.start(queue: .global())
    XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
    port = l.port?.rawValue ?? port
    listener = l
  }

  func stop() { listener?.cancel(); listener = nil }

  private func handle(_ c: NWConnection, _ buf: Data) {
    c.start(queue: .global())
    receive(c, buf)
  }

  private func receive(_ c: NWConnection, _ buf: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, err in
      var buf = buf
      if let data { buf.append(data) }
      if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
        let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
        let len = head.split(separator: "\r\n").compactMap { l -> Int? in
          let p = l.split(separator: ":", maxSplits: 1)
          return p.count == 2 && p[0].lowercased() == "content-length" ? Int(p[1].trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 0
        if buf.count - r.upperBound >= len {
          let body = buf[r.upperBound ..< r.upperBound + len]
          reply(c, Data(body)); return
        }
      }
      if done || err != nil { c.cancel(); return }
      receive(c, buf)
    }
  }

  private func reply(_ c: NWConnection, _ body: Data) {
    lock.lock(); count += 1; let n = count; lock.unlock()
    let (status, headers) = respond(n)
    let names = ((try? Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: body))?
      .resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans).map(\.name)) ?? []
    lock.lock(); records.append(Record(at: Date().timeIntervalSince(t0), status: status, names: names)); lock.unlock()
    var head = "HTTP/1.1 \(status) X\r\nContent-Length: 0\r\nConnection: close\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    c.send(content: Data((head + "\r\n").utf8), completion: .contentProcessed { _ in c.cancel() })
  }

  var all: [Record] { lock.lock(); defer { lock.unlock() }; return records }
  var accepted: [String] { all.filter { (200 ..< 300).contains($0.status) }.flatMap(\.names) }
}

private func span(_ name: String) -> SpanData {
  SpanData(traceId: TraceId.random(), spanId: SpanId.random(), traceFlags: TraceFlags(), traceState: TraceState(),
           resource: Resource(), instrumentationScope: InstrumentationScopeInfo(), name: name, kind: .internal,
           startTime: Date(), endTime: Date(), hasRemoteParent: false)
}

/// Runs the real exporter and `BaseHTTPClient` against a local TCP server and checks that the server
/// receives every span exactly once through outages, throttling and oversize rejections.
final class OtlpHttpRealSocketRetryTests: XCTestCase {
  private func exporter(_ server: SocketServer, policy: OtlpRetryPolicy) -> OtlpHttpTraceExporter {
    OtlpHttpTraceExporter(endpoint: URL(string: "http://127.0.0.1:\(server.port)/v1/traces")!,
                          config: OtlpConfiguration(timeout: 5, compression: .none),
                          httpClient: BaseHTTPClient(), envVarHeaders: nil, retryPolicy: policy)
  }

  private func report(_ title: String, _ s: SocketServer) {
    print("RETRYREPORT \(title)")
    for (i, r) in s.all.enumerated().prefix(12) {
      print(String(format: "RETRYREPORT   request %d at %.2fs status %d spans %d", i + 1, r.at, r.status, r.names.count))
    }
  }

  /// Offer `total` spans, one per 20 ms, then keep exporting until the server has them all.
  private func drive(_ e: OtlpHttpTraceExporter, total: Int, server: SocketServer) -> [String] {
    var offered: [String] = []
    for i in 0 ..< total {
      let n = "s\(i)"; offered.append(n)
      _ = e.export(spans: [span(n)])
      Thread.sleep(forTimeInterval: 0.02)
    }
    let deadline = Date().addingTimeInterval(20)
    while Set(server.accepted).count < total, Date() < deadline {
      _ = e.export(spans: [])
      Thread.sleep(forTimeInterval: 0.05)
    }
    return offered
  }

  func testRecoversFromServerOutage503WithRetryAfter() throws {
    let s = SocketServer { n in n <= 2 ? (503, ["Retry-After": "1"]) : (200, [:]) }
    try s.start(); defer { s.stop() }
    let e = exporter(s, policy: OtlpRetryPolicy())
    let offered = drive(e, total: 60, server: s)
    report("503 x2 with Retry-After: 1, then 200", s)
    XCTAssertEqual(s.accepted.sorted(), offered.sorted(), "every span arrives exactly once")
    let t = s.all.map(\.at)
    XCTAssertGreaterThanOrEqual(t[1] - t[0], 1.0, "second attempt waits for Retry-After")
    XCTAssertGreaterThanOrEqual(t[2] - t[1], 1.0, "third attempt waits for Retry-After")
  }

  func testExponentialBackoffOverRealSocket() throws {
    let s = SocketServer { n in n <= 4 ? (503, [:]) : (200, [:]) }
    try s.start(); defer { s.stop() }
    let e = exporter(s, policy: OtlpRetryPolicy(initialBackoff: 0.2))
    let offered = drive(e, total: 100, server: s)
    report("503 x4, no Retry-After, initialBackoff 0.2 (expect gaps >= 0.2, 0.4, 0.8, 1.6)", s)
    XCTAssertEqual(s.accepted.sorted(), offered.sorted())
    let t = s.all.map(\.at)
    for (i, minGap) in [0.2, 0.4, 0.8, 1.6].enumerated() {
      XCTAssertGreaterThanOrEqual(t[i + 1] - t[i], minGap - 0.01, "gap \(i + 1)")
    }
  }

  func testConnectionRefusedThenServerAppears() throws {
    // Reserve a port, then release it so connections to it are refused.
    let probe = SocketServer { _ in (200, [:]) }
    try probe.start()
    let port = probe.port
    probe.stop()
    Thread.sleep(forTimeInterval: 0.2)

    let late = SocketServer(port: port) { _ in (200, [:]) }
    let e = OtlpHttpTraceExporter(endpoint: URL(string: "http://127.0.0.1:\(port)/v1/traces")!,
                                  config: OtlpConfiguration(timeout: 5, compression: .none),
                                  httpClient: BaseHTTPClient(), envVarHeaders: nil,
                                  retryPolicy: OtlpRetryPolicy(initialBackoff: 0.05))
    for i in 0 ..< 20 { _ = e.export(spans: [span("s\(i)")]); Thread.sleep(forTimeInterval: 0.02) }
    try late.start(); defer { late.stop() }
    var offered = (0 ..< 20).map { "s\($0)" }
    for i in 20 ..< 30 { offered.append("s\(i)"); _ = e.export(spans: [span("s\(i)")]); Thread.sleep(forTimeInterval: 0.02) }
    let deadline = Date().addingTimeInterval(20)
    while Set(late.accepted).count < 30, Date() < deadline { _ = e.export(spans: []); Thread.sleep(forTimeInterval: 0.05) }
    report("connection refused, then a listener binds the same port", late)
    XCTAssertEqual(late.accepted.sorted(), offered.sorted())
  }

  func testLargeQueueAfterOutageLeavesInBoundedRequests() throws {
    let s = SocketServer { n in n == 1 ? (503, [:]) : (200, [:]) }
    try s.start(); defer { s.stop() }
    let e = exporter(s, policy: OtlpRetryPolicy(initialBackoff: 0.05))
    _ = e.export(spans: [span("s0")])           // 503: s0 queued
    var offered = ["s0"]
    for i in 1 ..< 1500 { offered.append("s\(i)"); _ = e.export(spans: [span("s\(i)")]) } // all deferred or sent in-bound
    Thread.sleep(forTimeInterval: 0.1)
    let deadline = Date().addingTimeInterval(20)
    while Set(s.accepted).count < 1500, Date() < deadline { _ = e.export(spans: []); Thread.sleep(forTimeInterval: 0.05) }
    report("1500 spans queued behind one 503", s)
    XCTAssertEqual(s.accepted.sorted(), offered.sorted())
    XCTAssertLessThanOrEqual(s.all.map(\.names.count).max() ?? 0, 512)
  }

  func testPayloadTooLargeDropsOneBatchOnly() throws {
    let s = SocketServer { n in n == 2 ? (413, [:]) : (200, [:]) }
    try s.start(); defer { s.stop() }
    let e = exporter(s, policy: OtlpRetryPolicy(initialBackoff: 0.05, maxExportBatchSize: 10))
    _ = e.export(spans: (0 ..< 5).map { span("a\($0)") })   // request 1: 200
    _ = e.export(spans: (0 ..< 25).map { span("b\($0)") })  // request 2: 10 spans, 413 -> dropped, 15 stay queued
    let deadline = Date().addingTimeInterval(10)
    while s.accepted.count < 20, Date() < deadline { _ = e.export(spans: []); Thread.sleep(forTimeInterval: 0.05) }
    _ = e.flush()
    report("413 on the second request (batch bound 10)", s)
    let got = Set(s.accepted)
    XCTAssertEqual(got.count, 20, "5 + 15 delivered; the 10 rejected spans dropped, none lost beyond them")
    XCTAssertEqual(s.accepted.count, 20, "no duplicates")
  }

  func testShutdownDrainsQueueBatchByBatch() throws {
    let s = SocketServer { n in n == 1 ? (503, [:]) : (200, [:]) }
    try s.start(); defer { s.stop() }
    let e = exporter(s, policy: OtlpRetryPolicy(initialBackoff: 60, maxBackoff: 60, maxExportBatchSize: 100, shutdownTimeout: 5))
    _ = e.export(spans: [span("s0")])
    for i in 1 ..< 450 { _ = e.export(spans: [span("s\(i)")]) }   // all inside the 60 s backoff
    XCTAssertEqual(s.all.count, 1)
    e.shutdown()
    report("shutdown inside a 60 s backoff with 450 queued", s)
    XCTAssertEqual(Set(s.accepted).count, 450)
    XCTAssertEqual(s.accepted.count, 450)
  }
}
#endif
