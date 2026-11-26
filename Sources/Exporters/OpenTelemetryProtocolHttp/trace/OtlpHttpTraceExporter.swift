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

public func defaultOltpHttpTracesEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/traces")!
}

public final class OtlpHttpTraceExporter: SpanExporter, @unchecked Sendable {
  private let base: OtlpHttpExporterBase<SpanData>
  private var exporterMetrics: ExporterMetrics?

  init(base: OtlpHttpExporterBase<SpanData>) {
    self.base = base
  }

  /// A `convenience` constructor to configure the OTLP HTTP trace exporter
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  ///    - retryPolicy: Backoff, attempt limit and queue bound for retries. See `OtlpRetryPolicy`.
  public convenience init(endpoint: URL = defaultOltpHttpTracesEndpoint(),
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
  public convenience init(endpoint: URL,
                          config: OtlpConfiguration,
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
    exporterMetrics = ExporterMetrics(type: "span",
                                      meterProvider: meterProvider,
                                      exporterName: "otlp",
                                      transportName: config.exportAsJson
                                        ? ExporterMetrics.TransporterType.httpJson
                                        : ExporterMetrics.TransporterType.grpc)
  }

  public func export(spans: [SpanData], explicitTimeout: TimeInterval? = nil)
    -> SpanExporterResultCode {
    var resultValue: SpanExporterResultCode = .success
    if base.deferIfBackingOff(adding: spans) { return .failure }
    let sendingSpans = base.drainPending(adding: spans)

    let body =
      Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
        $0.resourceSpans = SpanAdapter.toProtoResourceSpans(
          spanDataList: sendingSpans)
      }
    let semaphore = DispatchSemaphore(value: 0)
    var request = base.createRequest(body: body, endpoint: base.endpoint)

    let timeout = min(explicitTimeout ?? TimeInterval.greatestFiniteMagnitude, base.config.timeout)
    request.timeoutInterval = timeout

    exporterMetrics?.addSeen(value: sendingSpans.count)
    base.httpClient.send(request: request) { [weak self] result in
      switch result {
      case .success:
        self?.exporterMetrics?.addSuccess(value: sendingSpans.count)
        self?.base.recordSuccess()
      case let .failure(error):
        self?.exporterMetrics?.addFailed(value: sendingSpans.count)
        self?.base.recordFailure(of: sendingSpans, error: error)
        OpenTelemetry.instance.feedbackHandler?("\(error)")
        resultValue = .failure
      }
      semaphore.signal()
    }

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    if waitResult == .timedOut {
      exporterMetrics?.addFailed(value: sendingSpans.count)
      return .failure
    }
    return resultValue
  }

  public func flush(explicitTimeout: TimeInterval? = nil)
    -> SpanExporterResultCode {
    var resultValue: SpanExporterResultCode = .success
    let started = Date()
    let pendingSpans = base.snapshotNextBatch()
    if !pendingSpans.isEmpty {
      let sentCount = pendingSpans.count
      let body =
        Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest.with {
          $0.resourceSpans = SpanAdapter.toProtoResourceSpans(
            spanDataList: pendingSpans)
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
        case let .failure(error):
          self?.exporterMetrics?.addFailed(value: sentCount)
          self?.base.recordFlushFailure(sentCount: sentCount, error: error)
          OpenTelemetry.instance.feedbackHandler?("\(error)")
          resultValue = .failure
        }
        semaphore.signal()
      }

      let waitResult = semaphore.wait(timeout: .now() + timeout)
      if waitResult == .timedOut {
        exporterMetrics?.addFailed(value: sentCount)
        return .failure
      }
      // A queue larger than one batch leaves in several requests, within the caller's time.
      if resultValue == .success, base.hasPending {
        let left = explicitTimeout.map { $0 - Date().timeIntervalSince(started) }
        if left == nil || left! > 0 { return flush(explicitTimeout: left) }
      }
    }
    return resultValue
  }

  /// Makes one last send of the queued signals, ignoring any backoff. The send waits no longer
  /// than `explicitTimeout`, or `retryPolicy.shutdownTimeout` when the caller gives none.
  public func shutdown(explicitTimeout: TimeInterval? = nil) {
    _ = flush(explicitTimeout: explicitTimeout ?? base.retryPolicy.shutdownTimeout)
  }
}
