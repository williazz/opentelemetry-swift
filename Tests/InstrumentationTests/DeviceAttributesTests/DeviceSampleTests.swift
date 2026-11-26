/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import XCTest
@testable import DeviceAttributesInstrumentation

final class DeviceSampleTests: XCTestCase {
  func testUnknownBatteryLevelIsNil() {
    // UIKit reports -1 when the level is unknown, as it does on a simulator.
    XCTAssertNil(DeviceSample.charge(fromBatteryLevel: -1))
  }

  func testOutOfRangeBatteryLevelIsNil() {
    XCTAssertNil(DeviceSample.charge(fromBatteryLevel: 1.01))
    XCTAssertNil(DeviceSample.charge(fromBatteryLevel: .nan))
    XCTAssertNil(DeviceSample.charge(fromBatteryLevel: .infinity))
  }

  func testBatteryLevelBoundsAreCharges() {
    XCTAssertEqual(DeviceSample.charge(fromBatteryLevel: 0), 0)
    XCTAssertEqual(DeviceSample.charge(fromBatteryLevel: 1), 1)
  }

  func testBatteryLevelDropsFloatingPointNoise() {
    XCTAssertEqual(DeviceSample.charge(fromBatteryLevel: 0.55000001), 0.55)
  }

  func testMonitorStoresChargeAndClearsItWhenLevelBecomesUnknown() {
    let monitor = BatteryMonitor()
    XCTAssertNil(monitor.charge)

    monitor.store(batteryLevel: 0.8)
    XCTAssertEqual(monitor.charge, 0.8)

    monitor.store(batteryLevel: -1)
    XCTAssertNil(monitor.charge)
  }
}
