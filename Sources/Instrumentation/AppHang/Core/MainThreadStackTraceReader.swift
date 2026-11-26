/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// The frames of a thread, as they were while it was blocked.
struct CapturedStackTrace: Equatable, Sendable {
  /// Return addresses, innermost first.
  let addresses: [UInt]
  /// Whether the thread's stack was deeper than the frames captured.
  let isTruncated: Bool
}

/// What a hang reports about where the main thread was stuck.
struct HangStackTrace: Equatable, Sendable {
  /// `exception.message`: one line naming where the hang was, short enough to group on.
  let message: String
  /// `exception.stacktrace`: the main thread's frames, and the images they fall in.
  let stacktrace: String
}

/// Captures and formats the main thread's stack while it is blocked.
///
/// `capture(thread:)` runs on the watchdog thread during the hang, so it must neither allocate
/// nor take a lock the main thread could be holding: either would deadlock the app it is
/// measuring. `format(_:duration:)` runs after the capture and is free to do both.
protocol MainThreadStackTraceReader {
  func capture(thread: MainThreadID) -> CapturedStackTrace?
  func format(_ capture: CapturedStackTrace, duration: TimeInterval) -> HangStackTrace
}

/// Records no stack trace. Used when `capturesStackTrace` is off, and on a build without the
/// `CrashReporting` trait, which leaves out the KSCrash dependency the capture needs.
struct NoMainThreadStackTraceReader: MainThreadStackTraceReader {
  func capture(thread: MainThreadID) -> CapturedStackTrace? { nil }

  func format(_ capture: CapturedStackTrace, duration: TimeInterval) -> HangStackTrace {
    HangStackTrace(message: HangStackTraceDefaults.message, stacktrace: HangStackTraceDefaults.stacktrace)
  }
}

/// What a hang reports when no stack trace was captured.
enum HangStackTraceDefaults {
  static let message = "Hang detected at unknown location"
  static let stacktrace = "No stack trace captured"
}
