//
// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Governs how an OTLP HTTP exporter retries a failed export.
///
/// A failed batch stays in the exporter's in-memory queue. The exporter does not send again
/// until the backoff interval has passed; calls to `export` that arrive sooner only enqueue
/// their data. The exporter never sleeps, so a retry cannot block the calling thread.
///
/// The delay after the *n*th consecutive failure is `initialBackoff * multiplier^(n-1)`,
/// capped at `maxBackoff`. A `Retry-After` header replaces that delay, capped at `maxRetryAfter`.
public struct OtlpRetryPolicy: Sendable, Equatable {
  /// The status codes the OTLP specification lists as retryable:
  /// 429, 502, 503 and 504. All other 4xx and 5xx codes MUST NOT be retried.
  public static let specRetryableStatusCodes: Set<Int> = [429, 502, 503, 504]

  /// The default policy: five retries after the first attempt, delays of 1, 2, 4, 8 and 16
  /// seconds, and a queue of 2048 signals (the default queue size of the batch processors).
  public static let `default` = OtlpRetryPolicy()

  /// Retries after the first attempt. A batch that fails `maxRetries + 1` times is dropped.
  public let maxRetries: Int
  /// The delay after the first failure.
  public let initialBackoff: TimeInterval
  /// The factor applied to the delay after each further failure.
  public let multiplier: Double
  /// The longest exponential delay.
  public let maxBackoff: TimeInterval
  /// The longest delay a `Retry-After` header can impose.
  public let maxRetryAfter: TimeInterval
  /// The HTTP status codes that trigger a retry. Any other status drops the batch.
  ///
  /// 413 Payload Too Large is deliberately absent: waiting does not shrink a request. The
  /// exporter prevents it by sending at most `maxExportBatchSize` signals per request, so a
  /// 413 means the server limit is below one batch and the batch is dropped.
  public let retryableStatusCodes: Set<Int>
  /// The most signals one request carries. A longer queue leaves in several requests.
  public let maxExportBatchSize: Int
  /// The most signals the exporter holds for retry. When the queue is full, the oldest signals go first.
  public let maxPendingSignals: Int
  /// The longest `shutdown` waits for its final send when the caller gives no timeout.
  public let shutdownTimeout: TimeInterval

  public init(maxRetries: Int = 5,
              initialBackoff: TimeInterval = 1,
              multiplier: Double = 2,
              maxBackoff: TimeInterval = 60,
              maxRetryAfter: TimeInterval = 300,
              retryableStatusCodes: Set<Int> = OtlpRetryPolicy.specRetryableStatusCodes,
              maxExportBatchSize: Int = 512,
              maxPendingSignals: Int = 2048,
              shutdownTimeout: TimeInterval = 2) {
    self.maxRetries = max(0, maxRetries)
    self.initialBackoff = max(0, initialBackoff)
    self.multiplier = max(1, multiplier)
    self.maxBackoff = max(0, maxBackoff)
    self.maxRetryAfter = max(0, maxRetryAfter)
    self.retryableStatusCodes = retryableStatusCodes
    self.maxExportBatchSize = max(1, maxExportBatchSize)
    self.maxPendingSignals = max(1, maxPendingSignals)
    self.shutdownTimeout = max(0, shutdownTimeout)
  }

  /// The delay before the next send, after `failureCount` consecutive failures (1-based).
  /// A `retryAfter` from the server replaces the exponential delay.
  public func delay(afterFailure failureCount: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
    if let retryAfter {
      return min(max(0, retryAfter), maxRetryAfter)
    }
    let exponent = Double(max(0, failureCount - 1))
    return min(initialBackoff * pow(multiplier, exponent), maxBackoff)
  }

  /// Whether a failed export may be sent again.
  func isRetryable(_ error: Error) -> Bool {
    guard let statusCode = (error as? HTTPClientError)?.statusCode else {
      // No HTTP status: the server disconnected or the network failed. The specification
      // says to retry with exponential backoff.
      return true
    }
    return retryableStatusCodes.contains(statusCode)
  }

  /// Parses a `Retry-After` header: a count of seconds, or an HTTP-date (RFC 9110, section 10.2.3).
  static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
      return nil
    }
    if let seconds = TimeInterval(value), seconds.isFinite {
      return max(0, seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: value) else {
      return nil
    }
    return max(0, date.timeIntervalSince(now))
  }
}
