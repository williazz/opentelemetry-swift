/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf

/// Where one launch's exported telemetry is read back from.
///
/// `Scripts/run-integration-tests.sh --backend collector` collects a launch
/// into files and reads the files back. `--backend grafana` pushes the same
/// launch to a hosted OTLP endpoint and queries it back out of Tempo. The
/// assertions see `ExportedSpan` and `ExportedLog` either way and cannot tell
/// the two apart.
protocol TelemetrySource: Sendable {
  /// Names this source in a diagnostic: a directory, or a query.
  var label: String { get }

  func spans() -> [ExportedSpan]
  func logs() -> [ExportedLog]
}

/// Reads the OpenTelemetry Collector's `file` exporter output in `proto`
/// format: a stream of 4-byte big-endian length prefixes, each followed by an
/// `Export<Signal>ServiceRequest`.
struct CollectorFileSource: TelemetrySource {
  let directory: URL

  var label: String { directory.path }

  func spans() -> [ExportedSpan] {
    Self.decodeMessages(file: directory.appendingPathComponent("traces.pb"),
                        as: Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.self)
      .flatMap { $0.resourceSpans }
      .flatMap(exportedSpans(in:))
  }

  func logs() -> [ExportedLog] {
    Self.decodeMessages(file: directory.appendingPathComponent("logs.pb"),
                        as: Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.self)
      .flatMap { $0.resourceLogs }
      .flatMap { resourceLogs in
        resourceLogs.scopeLogs.flatMap { scopeLogs in
          scopeLogs.logRecords.map {
            ExportedLog(resource: resourceLogs.resource.attributes, scope: scopeLogs.scope, record: $0)
          }
        }
      }
  }

  private static func decodeMessages<M: SwiftProtobuf.Message>(file url: URL, as type: M.Type) -> [M] {
    guard let data = try? Data(contentsOf: url) else {
      print("[IntegrationTests] missing \(url.path); run Scripts/run-integration-tests.sh first")
      return []
    }
    var messages: [M] = []
    var offset = data.startIndex
    while offset + 4 <= data.endIndex {
      let length = data[offset ..< offset + 4].reduce(0) { Int($0) << 8 | Int($1) }
      offset += 4
      guard offset + length <= data.endIndex else {
        print("[IntegrationTests] truncated message in \(url.lastPathComponent)")
        break
      }
      do {
        messages.append(try M(serializedBytes: data[offset ..< offset + length]))
      } catch {
        print("[IntegrationTests] could not decode message in \(url.lastPathComponent): \(error)")
      }
      offset += length
    }
    return messages
  }
}

/// Reads one launch's spans back out of Grafana Tempo.
///
/// The launch is identified by the two resource attributes the runner gives it,
/// `integration.run.id` and `integration.launch`, so two runs and two launches
/// of one run never see each other's spans. Tempo is eventually consistent, so
/// the fetch polls: it returns once the launch's completion marker has arrived
/// and the span count has stopped growing, and on timeout it prints what it
/// asked for and what came back.
///
/// Logs and metrics are not implemented; see `logs()`.
final class TempoSource: TelemetrySource, @unchecked Sendable {
  struct Configuration: Sendable {
    /// Tempo's API base, including any gateway prefix. Grafana Cloud serves the
    /// API under `/tempo`, a Tempo of your own serves it at the root.
    let baseURL: URL
    /// `<instance id>:<token>` for HTTP basic auth, or nil for an unauthenticated Tempo.
    let credentials: String?
    /// Identifies the run, as the `integration.run.id` resource attribute.
    let runId: String
    /// Lower bound of the search window. Tempo returns nothing without one.
    let start: Date
    /// How long to wait for a launch's spans to arrive.
    let timeout: TimeInterval
    /// Interval between polls.
    let pollInterval: TimeInterval

    static let baseURLEnvironmentKey = "OTEL_INTEGRATION_TEMPO_URL"
    static let credentialsEnvironmentKey = "OTEL_INTEGRATION_TEMPO_AUTH"
    static let runIdEnvironmentKey = "OTEL_INTEGRATION_RUN_ID"
    static let startEnvironmentKey = "OTEL_INTEGRATION_RUN_START"
    static let timeoutEnvironmentKey = "OTEL_INTEGRATION_FETCH_TIMEOUT"

    /// Reads the configuration the runner exported. A missing or unusable value
    /// is the runner's mistake, not a test failure, so it stops the process
    /// with the name of what is missing.
    static func fromEnvironment() -> Configuration {
      let environment = ProcessInfo.processInfo.environment
      func required(_ key: String) -> String {
        guard let value = environment[key], !value.isEmpty else {
          fatalError("[IntegrationTests] \(key) is not set; the grafana backend needs it")
        }
        return value
      }
      guard let baseURL = URL(string: required(baseURLEnvironmentKey)) else {
        fatalError("[IntegrationTests] \(baseURLEnvironmentKey) is not a URL")
      }
      let start = environment[startEnvironmentKey].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
      return Configuration(baseURL: baseURL,
                           credentials: environment[credentialsEnvironmentKey].flatMap { $0.isEmpty ? nil : $0 },
                           runId: required(runIdEnvironmentKey),
                           start: start ?? Date().addingTimeInterval(-3600),
                           timeout: environment[timeoutEnvironmentKey].flatMap(TimeInterval.init) ?? 180,
                           pollInterval: 2)
    }
  }

  /// The `integration.launch` resource attribute of the launch to read.
  let launch: String
  /// The span whose arrival means the launch finished exporting.
  let completionMarker: String

  private let configuration: Configuration
  private let lock = NSLock()
  private var cachedSpans: [ExportedSpan]?

  static let runIdAttribute = "integration.run.id"
  static let launchAttribute = "integration.launch"

  init(launch: String, completionMarker: String, configuration: Configuration) {
    self.launch = launch
    self.completionMarker = completionMarker
    self.configuration = configuration
  }

  var label: String { "Tempo \(configuration.baseURL.absoluteString) \(query)" }

  /// Selects only this launch's spans, so neither another run nor another
  /// launch of this run can leak in.
  private var query: String {
    "{resource.\(Self.runIdAttribute)=\"\(configuration.runId)\""
      + " && resource.\(Self.launchAttribute)=\"\(launch)\"}"
  }

  /// Fetched once per launch per test process: every suite that asks for the
  /// same launch shares one round trip.
  func spans() -> [ExportedSpan] {
    lock.lock()
    defer { lock.unlock() }
    if let cachedSpans { return cachedSpans }
    let fetched = fetchUntilSettled()
    cachedSpans = fetched
    return fetched
  }

  /// Not implemented. Loki would go here: the same shape as `spans()`, a
  /// `query_range` against `{integration_run_id="…", integration_launch="…"}`
  /// in place of the TraceQL search, and Loki's OTLP log entries mapped onto
  /// `ExportedLog`. Until then the runner only selects span assertions for this
  /// backend.
  func logs() -> [ExportedLog] {
    print("""
    [IntegrationTests] the grafana backend reads traces only; \(label) has no log source. \
    Loki is not implemented, so run log assertions with --backend collector.
    """)
    return []
  }

  // MARK: Fetching

  private func fetchUntilSettled() -> [ExportedSpan] {
    let deadline = Date().addingTimeInterval(configuration.timeout)
    var previousCount = -1
    var lastFailure: String?
    while true {
      let result = fetchOnce()
      lastFailure = result.failure
      let spans = result.spans
      let settled = spans.count == previousCount && spans.contains { $0.span.name == completionMarker }
      if settled { return spans }
      if Date() >= deadline {
        print("""
        [IntegrationTests] timed out after \(Int(configuration.timeout))s reading launch '\(launch)' from \(label)
          expected: the '\(completionMarker)' span, and a span count that stopped growing
          arrived:  \(spans.count) spans\(spans.isEmpty ? "" : " (\(Set(spans.map(\.span.name)).sorted().joined(separator: ", ")))")
          \(lastFailure.map { "last error: \($0)" } ?? "no request failed; the spans never arrived")
        """)
        return spans
      }
      previousCount = spans.count
      Thread.sleep(forTimeInterval: configuration.pollInterval)
    }
  }

  private func fetchOnce() -> (spans: [ExportedSpan], failure: String?) {
    let searched = searchTraceIds()
    guard let traceIds = searched.traceIds else { return ([], searched.failure) }
    var spans: [ExportedSpan] = []
    var failure: String?
    for traceId in traceIds {
      let fetched = fetchTrace(traceId)
      guard let resourceSpans = fetched.resourceSpans else {
        failure = fetched.failure
        continue
      }
      spans += resourceSpans.filter(belongsToThisLaunch).flatMap(exportedSpans(in:))
    }
    return (spans, failure)
  }

  /// A trace can hold spans exported by more than one resource. Keep only the
  /// ones this launch exported.
  private func belongsToThisLaunch(_ resourceSpans: Opentelemetry_Proto_Trace_V1_ResourceSpans) -> Bool {
    let attributes = resourceSpans.resource.attributes
    return attributes.string(Self.runIdAttribute) == configuration.runId
      && attributes.string(Self.launchAttribute) == launch
  }

  private struct SearchResponse: Decodable {
    struct Trace: Decodable { let traceID: String }
    let traces: [Trace]?
  }

  private func searchTraceIds() -> (traceIds: [String]?, failure: String?) {
    var components = URLComponents(url: configuration.baseURL.appendingPathComponent("api/search"),
                                   resolvingAgainstBaseURL: false)
    // Tempo needs an explicit window: without `start` and `end` a search that
    // matches on resource attributes returns no traces at all.
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "start", value: String(Int(configuration.start.timeIntervalSince1970))),
      URLQueryItem(name: "end", value: String(Int(Date().timeIntervalSince1970) + 60)),
      URLQueryItem(name: "limit", value: "1000")
    ]
    guard let url = components?.url else { return (nil, "could not build a search URL") }
    let response = get(url, accept: "application/json")
    guard let data = response.data else { return (nil, response.failure) }
    do {
      return (try JSONDecoder().decode(SearchResponse.self, from: data).traces?.map(\.traceID) ?? [], nil)
    } catch {
      return (nil, "could not decode the search response: \(error)")
    }
  }

  private func fetchTrace(_ traceId: String) -> (resourceSpans: [Opentelemetry_Proto_Trace_V1_ResourceSpans]?, failure: String?) {
    let url = configuration.baseURL.appendingPathComponent("api/traces").appendingPathComponent(traceId)
    // Tempo answers this route with `tempopb.Trace`, whose only field is
    // `repeated ResourceSpans batches = 1`, the same field number and type as
    // ExportTraceServiceRequest.resource_spans, so the exporters' own generated
    // struct decodes it. Only `application/protobuf` selects protobuf;
    // `application/x-protobuf` silently falls back to OTLP/JSON, which
    // hex-encodes ids and which SwiftProtobuf's JSON decoder rejects.
    let response = get(url, accept: "application/protobuf")
    guard let data = response.data else { return (nil, response.failure) }
    do {
      let request = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(serializedBytes: data)
      return (request.resourceSpans, nil)
    } catch {
      return (nil, "could not decode trace \(traceId): \(error)")
    }
  }

  private func get(_ url: URL, accept: String) -> (data: Data?, failure: String?) {
    var request = URLRequest(url: url)
    request.setValue(accept, forHTTPHeaderField: "Accept")
    if let credentials = configuration.credentials,
       let encoded = credentials.data(using: .utf8)?.base64EncodedString() {
      request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
    request.timeoutInterval = 30

    var result: (Data?, String?) = (nil, "no response")
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
      defer { done.signal() }
      if let error {
        result = (nil, "\(url.path): \(error.localizedDescription)")
        return
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard status == 200 else {
        let body = data.flatMap { String(data: $0.prefix(400), encoding: .utf8) } ?? ""
        result = (nil, "\(url.path): HTTP \(status) \(body)")
        return
      }
      result = (data, nil)
    }.resume()
    done.wait()
    return result
  }
}

/// Flattens one `ResourceSpans` into the assertions' view of a span, keeping
/// the resource and scope it was exported under.
private func exportedSpans(in resourceSpans: Opentelemetry_Proto_Trace_V1_ResourceSpans) -> [ExportedSpan] {
  resourceSpans.scopeSpans.flatMap { scopeSpans in
    scopeSpans.spans.map {
      ExportedSpan(resource: resourceSpans.resource.attributes, scope: scopeSpans.scope, span: $0)
    }
  }
}
