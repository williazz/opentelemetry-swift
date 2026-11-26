/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import InstrumentationSemanticConventions
import OpenTelemetryApi

/// Turns a finished hang into a `device.hang` span.
///
/// It runs on the watchdog thread, never on the main thread: an app that has just recovered from
/// a hang should not be handed the work of formatting the report of it.
struct HangRecorder {
  static let spanName = FederatedSemanticConventions.SpanName.deviceHang.rawValue
  /// `exception.type`, which says which kind of event this is among the ones that carry
  /// `exception.*`. `Crash` reports the kind of crash here; a hang has only one kind.
  static let exceptionType = "hang"

  let scope: String
  let stackTraceReader: MainThreadStackTraceReader
  let isTraced: () -> Bool
  let recordsHangsWhileTraced: Bool

  /// Read per hang, not held, so a `TracerProvider` registered after the instrumentation was
  /// installed still receives hangs. `Crash` reads its `Logger` the same way.
  var tracer: Tracer {
    OpenTelemetry.instance.tracerProvider.get(instrumentationName: scope)
  }

  func record(_ hang: HangDetector.Hang) {
    // A debugger stops the main thread at every breakpoint, so each resume would otherwise be
    // reported as a hang as long as it stays attached. Checked per hang rather than at install,
    // because a debugger can attach at any point.
    guard recordsHangsWhileTraced || !isTraced() else {
      return
    }

    let stackTrace = hang.stackTrace.map { stackTraceReader.format($0, duration: hang.duration) }
    let span = tracer.spanBuilder(spanName: Self.spanName)
      .setSpanKind(spanKind: .internal)
      .setNoParent()
      .setStartTime(time: hang.start)
      .setAttribute(key: SemanticConventions.Exception.type.rawValue, value: Self.exceptionType)
      .setAttribute(key: SemanticConventions.Exception.message.rawValue,
                    value: stackTrace?.message ?? HangStackTraceDefaults.message)
      .setAttribute(key: SemanticConventions.Exception.stacktrace.rawValue,
                    value: stackTrace?.stacktrace ?? HangStackTraceDefaults.stacktrace)
      .startSpan()
    span.end(time: hang.start.addingTimeInterval(hang.duration))
  }
}
