//
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//

import Foundation
import OpenTelemetryProtocolExporterCommon
import SwiftProtobuf
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import OpenTelemetryApi

final class OtlpHttpExporterBase<Signal: Sendable>: @unchecked Sendable {
  let endpoint: URL
  let httpClient: HTTPClient
  let envVarHeaders: [(String, String)]?
  let config: OtlpConfiguration
  let requeueOnFailure: Bool
  let retryPolicy: OtlpRetryPolicy

  /// Reads a monotonic clock, in seconds. Tests replace it to advance time by hand.
  private let now: @Sendable () -> TimeInterval

  private let lock = Lock()
  private var pendingSignals: [Signal] = []
  /// Failed sends in a row. A success, or a dropped batch, resets it to zero.
  private var consecutiveFailures = 0
  /// The earliest time `export` may send again. `nil` when no backoff applies.
  private var retryNotBefore: TimeInterval?
  /// Signals discarded because the queue was full, or because a batch failed for good.
  private var droppedCount = 0

  // MARK: - Init

  // New initializer with HTTPClient support
  init(endpoint: URL,
       config: OtlpConfiguration = OtlpConfiguration(),
       httpClient: HTTPClient = BaseHTTPClient(),
       envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
       requeueOnFailure: Bool = true,
       retryPolicy: OtlpRetryPolicy = .default,
       now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.envVarHeaders = envVarHeaders
    self.endpoint = endpoint
    self.config = config
    self.httpClient = httpClient
    self.requeueOnFailure = requeueOnFailure
    self.retryPolicy = retryPolicy
    self.now = now
  }

  // Deprecated initializer for backward compatibility
  @available(*, deprecated, message: "Use init(endpoint:config:httpClient:envVarHeaders:requeueOnFailure:) instead")
  init(endpoint: URL,
       config: OtlpConfiguration = OtlpConfiguration(),
       useSession: URLSession? = nil,
       envVarHeaders: [(String, String)]? = EnvVarHeaders.attributes,
       requeueOnFailure: Bool = true) {
    self.envVarHeaders = envVarHeaders
    self.endpoint = endpoint
    self.config = config
    self.requeueOnFailure = requeueOnFailure
    self.retryPolicy = .default
    self.now = { ProcessInfo.processInfo.systemUptime }
    if let providedSession = useSession {
      self.httpClient = BaseHTTPClient(session: providedSession)
    } else {
      self.httpClient = BaseHTTPClient()
    }
  }

  /// Takes the oldest `maxExportBatchSize` queued signals, after adding `signals` to the queue.
  /// The rest stay queued for the next send, so one request never grows with the queue.
  func drainPending(adding signals: [Signal]) -> [Signal] {
    lock.withLock {
      pendingSignals.append(contentsOf: signals)
      let sending = Array(pendingSignals.prefix(retryPolicy.maxExportBatchSize))
      pendingSignals.removeFirst(sending.count)
      return sending
    }
  }

  /// The oldest `maxExportBatchSize` queued signals, left in the queue until `dropFlushed`.
  func snapshotNextBatch() -> [Signal] {
    lock.withLock { Array(pendingSignals.prefix(retryPolicy.maxExportBatchSize)) }
  }

  var hasPending: Bool {
    lock.withLock { !pendingSignals.isEmpty }
  }

  func requeue(_ signals: [Signal]) {
    guard requeueOnFailure else { return }
    lock.withLockVoid {
      appendBounded(signals)
    }
  }

  /// Holds `signals` for a later send when a backoff interval is still running.
  ///
  /// Returns `true` when the caller must not send now. The signals then sit in the queue.
  func deferIfBackingOff(adding signals: [Signal]) -> Bool {
    guard requeueOnFailure else { return false }
    return lock.withLock {
      guard let notBefore = retryNotBefore, now() < notBefore else { return false }
      appendBounded(signals)
      return true
    }
  }

  /// Records that an export of `signals` succeeded. Ends any backoff.
  func recordSuccess() {
    lock.withLockVoid {
      consecutiveFailures = 0
      retryNotBefore = nil
    }
  }

  /// Handles a failed `export` of `signals`, which `drainPending` already removed from the queue.
  ///
  /// A retryable failure requeues the batch and starts a backoff. A permanent failure, or the
  /// failure that exhausts `maxRetries`, drops the batch.
  func recordFailure(of signals: [Signal], error: Error) {
    guard requeueOnFailure else { return }
    lock.withLockVoid {
      if scheduleRetry(after: error) {
        // The failed batch is the oldest data. It goes back to the head of the queue.
        pendingSignals.insert(contentsOf: signals, at: 0)
        trimToBound()
      } else {
        drop(signals.count, because: error)
      }
    }
  }

  /// Handles a failed `flush`. The flushed signals are still at the head of the queue.
  func recordFlushFailure(sentCount: Int, error: Error) {
    guard requeueOnFailure else { return }
    lock.withLockVoid {
      if !scheduleRetry(after: error) {
        let n = min(sentCount, pendingSignals.count)
        pendingSignals.removeFirst(n)
        drop(n, because: error)
      }
    }
  }

  /// The count of signals discarded so far.
  func droppedSignalCount() -> Int {
    lock.withLock { droppedCount }
  }

  /// Updates the failure count and the backoff deadline. Returns `false` when the batch must be dropped.
  /// The caller holds `lock`.
  private func scheduleRetry(after error: Error) -> Bool {
    guard retryPolicy.isRetryable(error), consecutiveFailures < retryPolicy.maxRetries else {
      consecutiveFailures = 0
      retryNotBefore = nil
      return false
    }
    consecutiveFailures += 1
    let delay = retryPolicy.delay(afterFailure: consecutiveFailures,
                                  retryAfter: (error as? HTTPClientError)?.retryAfter)
    retryNotBefore = now() + delay
    return true
  }

  /// Appends to the queue and discards the oldest signals beyond `maxPendingSignals`.
  /// The caller holds `lock`.
  private func appendBounded(_ signals: [Signal]) {
    pendingSignals.append(contentsOf: signals)
    trimToBound()
  }

  /// The caller holds `lock`.
  private func trimToBound() {
    let excess = pendingSignals.count - retryPolicy.maxPendingSignals
    if excess > 0 {
      pendingSignals.removeFirst(excess)
      droppedCount += excess
      OpenTelemetry.instance.feedbackHandler?("OTLP retry queue full: dropped \(excess) oldest signals")
    }
  }

  /// The caller holds `lock`.
  private func drop(_ count: Int, because error: Error) {
    guard count > 0 else { return }
    droppedCount += count
    OpenTelemetry.instance.feedbackHandler?("OTLP export dropped \(count) signals: \(error)")
  }

  func snapshotPending() -> [Signal] {
    lock.withLock { pendingSignals }
  }

  func dropFlushed(count sentCount: Int) {
    lock.withLockVoid {
      let n = min(sentCount, pendingSignals.count)
      pendingSignals.removeFirst(n)
    }
  }

  func createRequest(body: Message, endpoint: URL) -> URLRequest {
    var request = URLRequest(url: endpoint)

    if let headers = envVarHeaders ?? config.headersForExport() {
      headers.forEach { key, value in
        request.addValue(value, forHTTPHeaderField: key)
      }
    }

    do {
      let rawData = try body.serializedData()
      request.httpMethod = "POST"
      request.setValue(Headers.getUserAgentHeader(), forHTTPHeaderField: Constants.HTTP.userAgent)
      request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")

      var compressedData = rawData

      #if canImport(Compression)
        switch config.compression {
        case .gzip:
          if let data = rawData.gzip() {
            compressedData = data
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
          }

        case .deflate:
          if let data = rawData.deflate() {
            compressedData = data
            request.setValue("deflate", forHTTPHeaderField: "Content-Encoding")
          }

        case .none:
          break
        }
      #endif

      // Apply final data. Could be compressed or raw
      // but it doesn't matter here
      request.httpBody = compressedData
    } catch {
      OpenTelemetry.instance.feedbackHandler?("Error serializing body: \(error)")
    }
    return request
  }
}
