/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// The two readings a hang needs: when it began, and how long it lasted.
///
/// A hang is timed on the monotonic clock, so a wall clock that steps during the hang can't
/// produce a negative duration or a span that ends before it starts, while the span's start is
/// still a wall clock time a backend can line up with the rest of the app's telemetry.
struct HangClock: Sendable {
  /// The wall clock, read when the main thread starts work.
  var now: @Sendable () -> Date
  /// Seconds on a monotonic clock. It doesn't advance while the device is asleep, which is
  /// outside the window a hang is measured over anyway.
  var uptime: @Sendable () -> TimeInterval

  static let system = HangClock(
    now: { Date() },
    uptime: { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
  )
}
