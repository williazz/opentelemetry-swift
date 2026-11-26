/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// How `AppHangInstrumentation` decides what a hang is and what it records about one.
public struct AppHangInstrumentationConfiguration: Sendable {
  /// How long the main thread must stay busy for the hang to be recorded. 250 ms is the
  /// threshold Apple's Hangs instrument uses for a microhang and the one ADOT records.
  public var hangThreshold: TimeInterval = 0.25

  /// How long a hang must last before the main thread's stack trace is captured. It is below
  /// `hangThreshold` so the trace is taken while the main thread is still blocked, which is the
  /// only moment it says anything. `nil` means two thirds of `hangThreshold`.
  public var stackTraceThreshold: TimeInterval?

  /// How often the watchdog thread looks for an ongoing hang.
  public var pollInterval: TimeInterval = 0.1

  /// Whether a hang carries the main thread's stack trace. Turning this off leaves the hang's
  /// timing and drops `exception.stacktrace`.
  public var capturesStackTrace: Bool = true

  /// How many frames of the main thread to record. The trace is bounded by this instead of by a
  /// byte count, so a deep stack is cut at the bottom, furthest from where the thread is stuck.
  public var maxFrames: Int = 128

  /// Whether each frame also names the symbol it falls in, as KSCrash's
  /// `symbolicatedSideBySide` report style does. Off by default, so a backend symbolicates from
  /// the app's dSYMs, which is what [`Crash`](../Crash/README.md) defaults to for the same reason.
  public var includesSymbolNames: Bool = false

  /// Whether hangs are recorded while a debugger has the process traced. Off by default: a
  /// breakpoint stops the main thread, and every resume would otherwise be reported as a hang.
  public var recordsHangsWhileTraced: Bool = false

  public init() {}

  /// The threshold the watchdog captures a stack trace at, resolved from `stackTraceThreshold`.
  var resolvedStackTraceThreshold: TimeInterval {
    stackTraceThreshold ?? hangThreshold * 2 / 3
  }
}

extension AppHangInstrumentationConfiguration {
  /// Replaces any value that would stop the instrumentation reporting anything with the default,
  /// and reports why. A `stackTraceThreshold` above `hangThreshold` is lowered to it, because a
  /// trace captured after the hang ended shows the main thread idle.
  static func validated(_ configuration: AppHangInstrumentationConfiguration) -> AppHangInstrumentationConfiguration {
    let defaults = AppHangInstrumentationConfiguration()
    var validated = configuration

    if !(configuration.hangThreshold > 0) {
      report("`hangThreshold` must be a number of seconds above 0, so the default is used.")
      validated.hangThreshold = defaults.hangThreshold
    }
    if !(configuration.pollInterval > 0) {
      report("`pollInterval` must be a number of seconds above 0, so the default is used.")
      validated.pollInterval = defaults.pollInterval
    }
    if configuration.maxFrames < 1 {
      report("`maxFrames` must be at least 1, so the default is used.")
      validated.maxFrames = defaults.maxFrames
    }
    if let threshold = configuration.stackTraceThreshold {
      if !(threshold > 0) {
        report("`stackTraceThreshold` must be a number of seconds above 0, so two thirds of `hangThreshold` is used.")
        validated.stackTraceThreshold = nil
      } else if threshold > validated.hangThreshold {
        report("`stackTraceThreshold` must not be above `hangThreshold`, so `hangThreshold` is used.")
        validated.stackTraceThreshold = validated.hangThreshold
      }
    }

    return validated
  }

  private static func report(_ message: String) {
    OpenTelemetry.instance.feedbackHandler?("AppHangInstrumentation: \(message)")
  }
}
