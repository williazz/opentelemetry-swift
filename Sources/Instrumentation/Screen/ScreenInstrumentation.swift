/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// Installs screen tracking.
///
/// Call `install()` once, after registering the tracer and logger providers, and add
/// `ScreenSpanProcessor` and `ScreenLogRecordProcessor` to those providers so spans and log
/// records carry `app.screen.name`.
///
/// ```swift
/// let tracerProvider = TracerProviderBuilder()
///   .add(spanProcessor: ScreenSpanProcessor())
///   .add(spanProcessor: BatchSpanProcessor(spanExporter: spanExporter))
///   .build()
/// OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
///
/// ScreenInstrumentation.install()
/// ```
///
/// On UIKit, installing swizzles `UIViewController`. That is process-wide and permanent, so
/// `install()` does it once and later calls return.
public enum ScreenInstrumentation {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var isInstalled = false

  /// Installs screen tracking with `config`, or returns if it is already installed.
  ///
  /// - Parameters:
  ///   - config: What to detect and what to record.
  ///   - screenTracker: The tracker to feed. Defaults to the shared one.
  @MainActor
  public static func install(config: ScreenInstrumentationConfig = .default,
                             screenTracker: ScreenTracker? = nil) {
    let shouldInstall: Bool = lock.withLock {
      guard !isInstalled else { return false }
      isInstalled = true
      return true
    }
    guard shouldInstall else { return }

    let tracker = screenTracker ?? ScreenTrackerProvider.getInstance()
    if let screenTracker {
      ScreenTrackerProvider.register(screenTracker: screenTracker)
    }

    #if canImport(UIKit) && !os(watchOS)
      guard config.tracksUIKitScreens else { return }
      let handler = ViewControllerScreenHandler(config: config, screenTracker: tracker)
      UIViewController.installScreenTracking(handler: handler)
    #else
      _ = tracker
    #endif
  }
}
