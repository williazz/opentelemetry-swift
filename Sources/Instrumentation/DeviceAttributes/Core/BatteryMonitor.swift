/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
#if os(iOS)
  import UIKit
#endif

/// Keeps the battery's charge where any thread can read it.
///
/// UIKit may be read only from the main thread, and spans start on any thread. So the monitor
/// reads `UIDevice` on the main thread, once when it starts and again on each
/// `batteryLevelDidChangeNotification`, and stores the result behind a lock. A reader costs one
/// lock, and the app does no polling. Only iOS reports a level. Elsewhere `charge` stays `nil`.
final class BatteryMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private var storedCharge: Double?
  private var started = false

  var charge: Double? {
    lock.lock()
    defer { lock.unlock() }
    return storedCharge
  }

  func store(batteryLevel: Float) {
    let charge = DeviceSample.charge(fromBatteryLevel: batteryLevel)
    lock.lock()
    storedCharge = charge
    lock.unlock()
  }

  /// Turns on battery monitoring, which is off by default and which UIKit shares across the app,
  /// and keeps `charge` current. Safe to call from any thread, and more than once.
  func start() {
    #if os(iOS)
      lock.lock()
      let alreadyStarted = started
      started = true
      lock.unlock()
      guard !alreadyStarted else { return }

      if Thread.isMainThread {
        MainActor.assumeIsolated { observeBattery() }
      } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.observeBattery() } }
      }
    #endif
  }

  #if os(iOS)
    @MainActor
    private func observeBattery() {
      let device = UIDevice.current
      device.isBatteryMonitoringEnabled = true
      store(batteryLevel: device.batteryLevel)
      NotificationCenter.default.addObserver(
        forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.store(batteryLevel: UIDevice.current.batteryLevel) }
      }
    }
  #endif
}
