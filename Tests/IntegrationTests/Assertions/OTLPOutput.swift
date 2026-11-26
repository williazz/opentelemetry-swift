/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf
import XCTest

typealias ProtoSpan = Opentelemetry_Proto_Trace_V1_Span
typealias ProtoLogRecord = Opentelemetry_Proto_Logs_V1_LogRecord
typealias ProtoScope = Opentelemetry_Proto_Common_V1_InstrumentationScope
typealias ProtoAttributes = [Opentelemetry_Proto_Common_V1_KeyValue]

// A span or log together with the resource and scope it was exported under.
struct ExportedSpan {
  let resource: ProtoAttributes
  let scope: ProtoScope
  let span: ProtoSpan
}

struct ExportedLog {
  let resource: ProtoAttributes
  let scope: ProtoScope
  let record: ProtoLogRecord
}

extension Array where Element == Opentelemetry_Proto_Common_V1_KeyValue {
  subscript(key: String) -> Opentelemetry_Proto_Common_V1_AnyValue? {
    first { $0.key == key }?.value
  }

  func string(_ key: String) -> String? {
    guard case let .stringValue(value)? = self[key]?.value else { return nil }
    return value
  }

  func int(_ key: String) -> Int64? {
    guard case let .intValue(value)? = self[key]?.value else { return nil }
    return value
  }

  func double(_ key: String) -> Double? {
    guard case let .doubleValue(value)? = self[key]?.value else { return nil }
    return value
  }

  func bool(_ key: String) -> Bool? {
    guard case let .boolValue(value)? = self[key]?.value else { return nil }
    return value
  }
}

// The telemetry one app launch of a run of Scripts/run-integration-tests.sh
// exported, whichever backend the runner used. `OTLPOutput.main` is the primary
// launch, `OTLPOutput.launch(...)` selects the others.
//
// With `--backend collector` (the default) each launch is read back from its
// own directory under OTEL_INTEGRATION_OUTPUT_DIR, where the OpenTelemetry
// Collector's `file` exporter wrote it. With `--backend grafana` each launch is
// queried back out of Tempo by the `integration.run.id` and
// `integration.launch` resource attributes the runner gave it. Both backends
// hand the assertions the same ExportedSpan and ExportedLog.
struct OTLPOutput: Sendable {
  static let outputDirectoryEnvironmentKey = "OTEL_INTEGRATION_OUTPUT_DIR"
  static let backendEnvironmentKey = "OTEL_INTEGRATION_BACKEND"

  enum Backend: String {
    case collector
    case grafana
  }

  static let backend: Backend = {
    guard let raw = ProcessInfo.processInfo.environment[backendEnvironmentKey], !raw.isEmpty else {
      return .collector
    }
    guard let backend = Backend(rawValue: raw) else {
      fatalError("[IntegrationTests] \(backendEnvironmentKey)=\(raw) is not one of collector, grafana")
    }
    return backend
  }()

  static let baseDirectory: URL = {
    if let path = ProcessInfo.processInfo.environment[outputDirectoryEnvironmentKey], !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("out", isDirectory: true)
  }()

  static let main = OTLPOutput(slot: Scenario.Launch.main.rawValue)

  static func launch(_ launch: Scenario.Launch) -> OTLPOutput {
    OTLPOutput(slot: launch.rawValue)
  }

  /// Output collected under a name other than a launch tag, e.g. `crash-examples/<type>`.
  static func subdirectory(_ path: String) -> OTLPOutput {
    OTLPOutput(slot: path)
  }

  // Convenience accessors for the main launch, which most suites assert on.
  static var spans: [ExportedSpan] { main.spans }
  static var logs: [ExportedLog] { main.logs }

  let source: TelemetrySource

  var spans: [ExportedSpan] { source.spans() }
  var logs: [ExportedLog] { source.logs() }

  private init(slot: String) {
    source = Self.sources.source(for: slot)
  }

  // One source per slot per test process. The collector's files can be read
  // again at no cost, but a remote backend must not be queried once per
  // assertion, so the source that caches owns that decision.
  private static let sources = SourceCache()

  private final class SourceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var bySlot: [String: TelemetrySource] = [:]

    func source(for slot: String) -> TelemetrySource {
      lock.lock()
      defer { lock.unlock() }
      if let existing = bySlot[slot] { return existing }
      let created = make(slot)
      bySlot[slot] = created
      return created
    }

    private func make(_ slot: String) -> TelemetrySource {
      switch OTLPOutput.backend {
      case .collector:
        return CollectorFileSource(directory: OTLPOutput.baseDirectory
          .appendingPathComponent(slot, isDirectory: true))
      case .grafana:
        return TempoSource(launch: slot,
                           completionMarker: Scenario.completionSpanName,
                           configuration: TempoSource.Configuration.fromEnvironment())
      }
    }
  }
}
