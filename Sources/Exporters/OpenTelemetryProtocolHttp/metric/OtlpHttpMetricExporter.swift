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

public func defaultOtlpHttpMetricsEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/metrics")!
}

@available(*, deprecated, renamed: "defaultOtlpHttpMetricsEndpoint")
public func defaultStableOtlpHTTPMetricsEndpoint() -> URL {
  URL(string: "http://localhost:4318/v1/metrics")!
}

@available(*, deprecated, renamed: "OtlpHttpMetricExporter")
public typealias StableOtlpHTTPMetricExporter = OtlpHttpMetricExporter

@available(*, deprecated, renamed: "OtlpHttpMetricExporter")
public typealias OtlpHTTPMetricExporter = OtlpHttpMetricExporter

public final class OtlpHttpMetricExporter: MetricExporter, @unchecked Sendable {
  var aggregationTemporalitySelector: AggregationTemporalitySelector
  var defaultAggregationSelector: DefaultAggregationSelector

  private let base: OtlpHttpExporterBase<MetricData>
  private var exporterMetrics: ExporterMetrics?

  // MARK: - Init

  init(base: OtlpHttpExporterBase<MetricData>,
       aggregationTemporalitySelector: AggregationTemporalitySelector,
       defaultAggregationSelector: DefaultAggregationSelector) {
    self.base = base
    self.aggregationTemporalitySelector = aggregationTemporalitySelector
    self.defaultAggregationSelector = defaultAggregationSelector
  }

  /// A `convenience` constructor to configure the OTLP HTTP metric exporter
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - aggregationTemporalitySelector: aggregator
  ///    - defaultAggregationSelector: default aggregator
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  ///    - retryPolicy: Backoff, attempt limit and queue bound for retries. See `OtlpRetryPolicy`.
  public convenience init(endpoint: URL,
                          config: OtlpConfiguration = OtlpConfiguration(),
                          aggregationTemporalitySelector: AggregationTemporalitySelector =
                          AggregationTemporality.alwaysCumulative(),
                          defaultAggregationSelector: DefaultAggregationSelector = AggregationSelector.instance,
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true,
                          retryPolicy: OtlpRetryPolicy = .default) {
    self.init(base: OtlpHttpExporterBase(endpoint: endpoint,
                                         config: config,
                                         httpClient: httpClient,
                                         envVarHeaders: envVarHeaders,
                                         requeueOnFailure: requeueOnFailure,
                                         retryPolicy: retryPolicy),
              aggregationTemporalitySelector: aggregationTemporalitySelector,
              defaultAggregationSelector: defaultAggregationSelector)
  }

  /// A `convenience` constructor to provide support for exporter metric using`StableMeterProvider` type
  /// - Parameters:
  ///    - endpoint: Exporter endpoint injected as dependency
  ///    - config: Exporter configuration including type of exporter
  ///    - meterProvider: Injected `StableMeterProvider` for metric
  ///    - aggregationTemporalitySelector: aggregator
  ///    - defaultAggregationSelector: default aggregator
  ///    - httpClient: Custom HTTPClient implementation
  ///    - envVarHeaders: Extra header key-values
  ///    - requeueOnFailure: Re-append failed batches to the in-memory pending queue
  ///    - retryPolicy: Backoff, attempt limit and queue bound for retries. See `OtlpRetryPolicy`.
  public convenience init(endpoint: URL,
                          config: OtlpConfiguration = OtlpConfiguration(),
                          meterProvider: any MeterProvider,
                          aggregationTemporalitySelector: AggregationTemporalitySelector =
                            AggregationTemporality.alwaysCumulative(),
                          defaultAggregationSelector: DefaultAggregationSelector = AggregationSelector
                            .instance,
                          httpClient: HTTPClient = BaseHTTPClient(),
                          envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
                          requeueOnFailure: Bool = true,
                          retryPolicy: OtlpRetryPolicy = .default) {
    self.init(endpoint: endpoint,
              config: config,
              aggregationTemporalitySelector: aggregationTemporalitySelector,
              defaultAggregationSelector: defaultAggregationSelector,
              httpClient: httpClient,
              envVarHeaders: envVarHeaders,
              requeueOnFailure: requeueOnFailure,
              retryPolicy: retryPolicy)
    exporterMetrics = ExporterMetrics(type: "metric",
                                      meterProvider: meterProvider,
                                      exporterName: "otlp",
                                      transportName: config.exportAsJson
                                        ? ExporterMetrics.TransporterType.httpJson
                                        : ExporterMetrics.TransporterType.grpc)
  }

  // MARK: - StableMetricsExporter

  public func export(metrics: [MetricData]) -> ExportResult {
    var resultValue: ExportResult = .success
    if base.deferIfBackingOff(adding: metrics) { return .failure }
    let sendingMetrics = base.drainPending(adding: metrics)
    let body =
      Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest.with {
        $0.resourceMetrics = MetricsAdapter.toProtoResourceMetrics(
          metricData: sendingMetrics)
      }
    exporterMetrics?.addSeen(value: sendingMetrics.count)
    let timeout = min(TimeInterval.greatestFiniteMagnitude, base.config.timeout)
    let semaphore = DispatchSemaphore(value: 0)
    var request = base.createRequest(body: body, endpoint: base.endpoint)
    request.timeoutInterval = timeout
    base.httpClient.send(request: request) { [weak self] result in
      switch result {
      case .success:
        self?.exporterMetrics?.addSuccess(value: sendingMetrics.count)
        self?.base.recordSuccess()
      case let .failure(error):
        self?.exporterMetrics?.addFailed(value: sendingMetrics.count)
        self?.base.recordFailure(of: sendingMetrics, error: error)
        OpenTelemetry.instance.feedbackHandler?("\(error)")
        resultValue = .failure
      }
      semaphore.signal()
    }

    let waitResult = semaphore.wait(timeout: .now() + timeout)
    if waitResult == .timedOut {
      exporterMetrics?.addFailed(value: sendingMetrics.count)
      return .failure
    }
    return resultValue
  }

  public func flush() -> ExportResult {
    flush(timeout: base.config.timeout)
  }

  private func flush(timeout flushTimeout: TimeInterval) -> ExportResult {
    var exporterResult: ExportResult = .success
    let started = Date()
    let pendingMetrics = base.snapshotNextBatch()
    if !pendingMetrics.isEmpty {
      let sentCount = pendingMetrics.count
      let body =
        Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest
          .with {
            $0.resourceMetrics = MetricsAdapter.toProtoResourceMetrics(
              metricData: pendingMetrics)
          }
      let semaphore = DispatchSemaphore(value: 0)
      var request = base.createRequest(body: body, endpoint: base.endpoint)
      let timeout = min(flushTimeout, base.config.timeout)
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
          exporterResult = .failure
        }
        semaphore.signal()
      }

      let waitResult = semaphore.wait(timeout: .now() + timeout)
      if waitResult == .timedOut {
        exporterMetrics?.addFailed(value: sentCount)
        return .failure
      }
      if exporterResult == .success, base.hasPending {
        let left = flushTimeout - Date().timeIntervalSince(started)
        if left > 0 { return flush(timeout: left) }
      }
    }

    return exporterResult
  }

  /// Makes one last send of the queued metrics, ignoring any backoff, and waits no longer
  /// than `retryPolicy.shutdownTimeout`.
  public func shutdown() -> ExportResult {
    _ = flush(timeout: base.retryPolicy.shutdownTimeout)
    return .success
  }

  // MARK: - AggregationTemporalitySelectorProtocol

  public func getAggregationTemporality(
    for instrument: OpenTelemetrySdk.InstrumentType
  ) -> OpenTelemetrySdk.AggregationTemporality {
    return aggregationTemporalitySelector.getAggregationTemporality(
      for: instrument)
  }

  // MARK: - DefaultAggregationSelector

  public func getDefaultAggregation(
    for instrument: OpenTelemetrySdk.InstrumentType
  ) -> OpenTelemetrySdk.Aggregation {
    return defaultAggregationSelector.getDefaultAggregation(for: instrument)
  }
}
