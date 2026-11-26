/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// How `ScreenInstrumentation.install(config:)` behaves.
public struct ScreenInstrumentationConfig: Sendable {
  /// The bundle a view controller's class must come from to be tracked. Defaults to the main
  /// bundle, which keeps the frameworks' own view controllers out of the data.
  public var bundle: Bundle

  /// Whether to detect UIKit screens by swizzling `viewDidLoad` and `viewDidAppear(_:)`.
  /// Swizzling is process-wide and cannot be undone, so turn it off to drive the tracker by
  /// hand or from SwiftUI alone.
  public var tracksUIKitScreens: Bool

  /// Whether to record an `app.screen.time_to_first_appear` span for each screen, alongside the
  /// `app.navigation.complete` event.
  public var recordsTimeToFirstAppear: Bool

  /// Whether UIKit detection also reports SwiftUI hosting controllers. Off by default: the
  /// `.otelScreen` modifier names what a hosting controller hosts, and reporting both gives one
  /// view two screens. Turn it on to see SwiftUI screens without touching the views, accepting
  /// the hosting controller's class name as the screen name.
  public var tracksHostingControllers: Bool

  public init(bundle: Bundle = .main,
              tracksUIKitScreens: Bool = true,
              recordsTimeToFirstAppear: Bool = true,
              tracksHostingControllers: Bool = false) {
    self.bundle = bundle
    self.tracksUIKitScreens = tracksUIKitScreens
    self.recordsTimeToFirstAppear = recordsTimeToFirstAppear
    self.tracksHostingControllers = tracksHostingControllers
  }

  public static let `default` = ScreenInstrumentationConfig()
}
