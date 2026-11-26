/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// What the main thread's run loop and the watchdog thread agree about the hang in progress.
///
/// The main thread calls `didWake()` and `willSleep()` from a run loop observer; the watchdog
/// thread calls `stackTraceIsDue()` and `record(stackTrace:for:)`. Every call takes one
/// uncontended mutex, so the two run loop calls add a lock and a comparison to each pass of the
/// main run loop.
final class HangDetector {
  /// A finished hang, ready to be recorded.
  struct Hang: Sendable {
    let start: Date
    let duration: TimeInterval
    let stackTrace: CapturedStackTrace?
  }

  /// The main thread is busy and the watchdog may capture its stack trace.
  struct OngoingHang {
    /// Identifies the hang, so a trace that arrives after it ended is dropped.
    let startUptime: TimeInterval
  }

  private struct Busy {
    let start: Date
    let startUptime: TimeInterval
    var stackTrace: CapturedStackTrace?
    var isCapturing: Bool = false
  }

  private let configuration: AppHangInstrumentationConfiguration
  private let clock: HangClock
  private let lock = NSLock()
  private var busy: Busy?
  /// Hangs are only recorded in the foreground. See `enteredBackground()`.
  private var isForeground: Bool

  init(configuration: AppHangInstrumentationConfiguration,
       clock: HangClock = .system,
       isForeground: Bool = true) {
    self.configuration = configuration
    self.clock = clock
    self.isForeground = isForeground
  }

  /// The main run loop woke and started work.
  func didWake() {
    let start = clock.now()
    let startUptime = clock.uptime()
    lock.withLock {
      guard isForeground else {
        busy = nil
        return
      }
      busy = Busy(start: start, startUptime: startUptime)
    }
  }

  /// The main run loop finished its work and is about to sleep. Returns the hang to record, if
  /// the work took longer than `hangThreshold`.
  func willSleep() -> Hang? {
    let endUptime = clock.uptime()
    return lock.withLock { () -> Hang? in
      defer { busy = nil }
      guard let busy, isForeground else {
        return nil
      }
      let duration = endUptime - busy.startUptime
      guard duration >= configuration.hangThreshold else {
        return nil
      }
      return Hang(start: busy.start, duration: duration, stackTrace: busy.stackTrace)
    }
  }

  /// The hang the watchdog should capture a stack trace for, or `nil` when the main thread is
  /// responsive, the hang is still shorter than `stackTraceThreshold`, or its trace was already
  /// taken. The hang is marked as being captured, so one poll can't start a second capture while
  /// the first is still walking the stack.
  func stackTraceIsDue() -> OngoingHang? {
    let now = clock.uptime()
    return lock.withLock { () -> OngoingHang? in
      guard var busy, isForeground, busy.stackTrace == nil, !busy.isCapturing else {
        return nil
      }
      guard now - busy.startUptime >= configuration.resolvedStackTraceThreshold else {
        return nil
      }
      busy.isCapturing = true
      self.busy = busy
      return OngoingHang(startUptime: busy.startUptime)
    }
  }

  /// Attaches a captured stack trace to the hang it was taken during. A trace for a hang that has
  /// already ended is dropped, because it belongs to work the main thread has finished.
  func record(stackTrace: CapturedStackTrace?, for hang: OngoingHang) {
    lock.withLock {
      guard var busy, busy.startUptime == hang.startUptime else {
        return
      }
      busy.isCapturing = false
      busy.stackTrace = stackTrace
      self.busy = busy
    }
  }

  /// The app left the foreground. The system suspends a backgrounded app, which stops the main
  /// thread mid-run-loop-pass and would make the next `willSleep()` report everything from the
  /// suspension to the next activation as one hang. So the hang in progress is dropped and
  /// nothing is recorded until the app returns.
  func enteredBackground() {
    lock.withLock {
      isForeground = false
      busy = nil
    }
  }

  /// The app is returning to the foreground. The run loop pass that delivers the notification
  /// started while the app was still in the background, so it is not treated as a hang; the next
  /// `didWake()` starts the first one that can be.
  func enteringForeground() {
    lock.withLock {
      isForeground = true
      busy = nil
    }
  }
}
