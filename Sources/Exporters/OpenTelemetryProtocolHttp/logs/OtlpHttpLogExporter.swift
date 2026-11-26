//
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public func defaultOltpHttpLoggingEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/logs")!
}

public final class OtlpHttpLogExporter: LogRecordExporter, @unchecked Sendable {
  private let base: OtlpHttpExporterBase<ReadableLogRecord>
  private var exporterMetrics: ExporterMetrics?

  init(base: OtlpHttpExporterBase<ReadableLogRecord>) {
    self.base = base
  }

  /// A `convenience` constructor to configure the OTLP HTTP log exporter
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  ///    - retryPolicy: Backoff, attempt limit and queue bound for retries. See `OtlpRetryPolicy`.
  public convenience init(endpoint: URL = defaultOltpHttpLoggingEndpoint(),
                          config: OtlpConfiguration = OtlpConfiguration(),
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true,
                          retryPolicy: OtlpRetryPolicy = .default) {
    self.init(base: OtlpHttpExporterBase(endpoint: endpoint,
                                         config: config,
                                         httpClient: httpClient,
                                         envVarHeaders: envVarHeaders,
                                         requeueOnFailure: requeueOnFailure,
                                         retryPolicy: retryPolicy))
  }

  /// A `convenience` constructor to provide support for exporter metric using`StableMeterProvider` type
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - meterProvider: Injected `StableMeterProvider` for metric
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  ///    - retryPolicy: Backoff, attempt limit and queue bound for retries. See `OtlpRetryPolicy`.
  public convenience init(endpoint: URL = defaultOltpHttpLoggingEndpoint(),
                          config: OtlpConfiguration = OtlpConfiguration(),
                          meterProvider: any MeterProvider,
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true,
                          retryPolicy: OtlpRetryPolicy = .default) {
    self.init(endpoint: endpoint,
              config: config,
              httpClient: httpClient,
              envVarHeaders: envVarHeaders,
              requeueOnFailure: requeueOnFailure,
              retryPolicy: retryPolicy)
    exporterMetrics = ExporterMetrics(type: "log",
                                      meterProvider: meterProvider,
                                      exporterName: "otlp",
                                      transportName: config.exportAsJson
                                        ? ExporterMetrics.TransporterType.httpJson
                                        : ExporterMetrics.TransporterType.grpc)
  }

  public func export(logRecords: [OpenTelemetrySdk.ReadableLogRecord],
                     explicitTimeout: TimeInterval? = nil) -> OpenTelemetrySdk.ExportResult {
    var resultValue: ExportResult = .success
    if base.deferIfBackingOff(adding: logRecords) { return .failure }
    let sendingLogRecords = base.drainPending(adding: logRecords)

    let body =
      Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.with { request in
        request.resourceLogs = LogRecordAdapter.toProtoResourceRecordLog(
          logRecordList: sendingLogRecords)
      }

    var request = base.createRequest(body: body, endpoint: base.endpoint)
    exporterMetrics?.addSeen(value: sendingLogRecords.count)
    let timeout = min(explicitTimeout ?? TimeInterval.greatestFiniteMagnitude, base.config.timeout)
    let semaphore = DispatchSemaphore(value: 0)
    request.timeoutInterval = timeout
    base.httpClient.send(request: request) { [weak self] result in
      switch result {
      case .success:
        self?.exporterMetrics?.addSuccess(value: sendingLogRecords.count)
        self?.base.recordSuccess()
      case let .failure(error):
        self?.exporterMetrics?.addFailed(value: sendingLogRecords.count)
        self?.base.recordFailure(of: sendingLogRecords, error: error)
        OpenTelemetry.instance.feedbackHandler?("\(error)")
        resultValue = .failure
      }
      semaphore.signal()
    }

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    if waitResult == .timedOut {
      exporterMetrics?.addFailed(value: sendingLogRecords.count)
      return .failure
    }
    return resultValue
  }

  public func forceFlush(explicitTimeout: TimeInterval? = nil) -> ExportResult {
    flush(explicitTimeout: explicitTimeout)
  }

  public func flush(explicitTimeout: TimeInterval? = nil) -> ExportResult {
    var exporterResult: ExportResult = .success
    let started = Date()
    let pendingLogRecords = base.snapshotNextBatch()

    if !pendingLogRecords.isEmpty {
      let sentCount = pendingLogRecords.count
      let body =
        Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest.with { request in
          request.resourceLogs = LogRecordAdapter.toProtoResourceRecordLog(
            logRecordList: pendingLogRecords)
        }
      let semaphore = DispatchSemaphore(value: 0)
      var request = base.createRequest(body: body, endpoint: base.endpoint)
      let timeout = min(explicitTimeout ?? TimeInterval.greatestFiniteMagnitude, base.config.timeout)
      request.timeoutInterval = timeout
      base.httpClient.send(request: request) { [weak self] result in
        switch result {
        case .success:
          self?.exporterMetrics?.addSuccess(value: sentCount)
          self?.base.dropFlushed(count: sentCount)
          self?.base.recordSuccess()
          exporterResult = ExportResult.success
        case let .failure(error):
          self?.exporterMetrics?.addFailed(value: sentCount)
          self?.base.recordFlushFailure(sentCount: sentCount, error: error)
          OpenTelemetry.instance.feedbackHandler?("\(error)")
          exporterResult = ExportResult.failure
        }
        semaphore.signal()
      }

      let waitResult = semaphore.wait(timeout: .now() + timeout)
      if waitResult == .timedOut {
        exporterMetrics?.addFailed(value: sentCount)
        return .failure
      }
      // A queue larger than one batch leaves in several requests, within the caller's time.
      if exporterResult == .success, base.hasPending {
        let left = explicitTimeout.map { $0 - Date().timeIntervalSince(started) }
        if left == nil || left! > 0 { return flush(explicitTimeout: left) }
      }
    }

    return exporterResult
  }

  /// Makes one last send of the queued signals, ignoring any backoff. The send waits no longer
  /// than `explicitTimeout`, or `retryPolicy.shutdownTimeout` when the caller gives none.
  public func shutdown(explicitTimeout: TimeInterval? = nil) {
    _ = flush(explicitTimeout: explicitTimeout ?? base.retryPolicy.shutdownTimeout)
  }
}
