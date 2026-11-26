/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import OpenTelemetryApi

/// Records each main-thread hang as a `device.hang` span, with the stack trace of the main
/// thread taken while it was still blocked.
///
/// A hang is a pass of the main run loop that takes longer than `hangThreshold`, 250 ms by
/// default: for that long the app answered neither a touch nor a frame. The span runs from when
/// the main thread started that work to when it finished, and carries `exception.type`,
/// `exception.message` and `exception.stacktrace`.
///
/// Install it as early as possible, from the main thread, after the `TracerProvider` is
/// registered:
///
/// ```swift
/// AppHangInstrumentation.install()
/// ```
///
/// The live stack trace needs the `CrashReporting` package trait, which brings in KSCrash;
/// without it hangs are still reported, with their timing only. See the module README.
public final class AppHangInstrumentation {
  /// The instrumentation scope every `device.hang` span is reported in.
  public static let instrumentationScope = "io.opentelemetry.apphang"

  /// Whether the main thread is being watched.
  public static var isInstalled: Bool {
    lock.withLock { watchdog != nil }
  }

  /// Guards `watchdog`, and makes the check-then-set in `install(configuration:)` one step.
  private static let lock = NSLock()
  nonisolated(unsafe) private static var watchdog: AppHangWatchdog?

  /// Starts watching the main thread, the same as `install(configuration:)`. If it is already
  /// installed, `configuration` is ignored.
  public init(configuration: AppHangInstrumentationConfiguration = .init()) {
    Self.install(configuration: configuration)
  }

  /// Starts watching the main thread. Idempotent and thread-safe; only the first call takes
  /// effect. A call from off the main thread installs the run loop observer on the next pass of
  /// the main run loop, so hangs before that are not recorded.
  public static func install(configuration: AppHangInstrumentationConfiguration = .init()) {
    let configuration = AppHangInstrumentationConfiguration.validated(configuration)
    let watchdog: AppHangWatchdog? = lock.withLock {
      guard Self.watchdog == nil else {
        return nil
      }
      let reader = makeStackTraceReader(configuration: configuration)
      let watchdog = AppHangWatchdog(
        configuration: configuration,
        detector: HangDetector(configuration: configuration),
        recorder: HangRecorder(
          scope: instrumentationScope,
          stackTraceReader: reader,
          isTraced: DebuggerDetection.isTraced,
          recordsHangsWhileTraced: configuration.recordsHangsWhileTraced
        ),
        stackTraceReader: reader
      )
      Self.watchdog = watchdog
      return watchdog
    }
    // Started outside the lock: it hops to the main thread, which may be waiting on something
    // that installs instrumentation of its own.
    watchdog?.start()
  }

  private static func makeStackTraceReader(
    configuration: AppHangInstrumentationConfiguration
  ) -> MainThreadStackTraceReader {
    #if CrashReporting
      guard configuration.capturesStackTrace else {
        return NoMainThreadStackTraceReader()
      }
      return KSCrashStackTraceReader(maxFrames: configuration.maxFrames,
                                     includesSymbolNames: configuration.includesSymbolNames)
    #else
      if configuration.capturesStackTrace {
        OpenTelemetry.instance.feedbackHandler?(
          "AppHangInstrumentation: a hang's stack trace needs the `CrashReporting` package trait, "
            + "so hangs are reported with their timing only."
        )
      }
      return NoMainThreadStackTraceReader()
    #endif
  }
}
