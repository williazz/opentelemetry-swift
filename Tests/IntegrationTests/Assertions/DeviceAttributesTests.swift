/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest

// The demo installs DeviceAttributesInstrumentation with its default one-second interval, so
// every exported span and log record carries a reading taken at most a second earlier. A
// simulator reports no battery level, so the battery attribute is optional here: when present it
// must be a charge from 0 to 1, and a -1 sentinel fails the test.
final class DeviceAttributesTests: XCTestCase {
  private let batteryKey = "hw.battery.charge"
  private let cpuKey = "process.cpu.utilization"
  private let memoryKey = "process.memory.usage"

  private func assertDeviceAttributes(_ attributes: ProtoAttributes, file: StaticString = #filePath, line: UInt = #line) {
    guard case let .doubleValue(cpu)? = attributes[cpuKey]?.value else {
      return XCTFail("\(cpuKey) is missing or not a double", file: file, line: line)
    }
    XCTAssertGreaterThanOrEqual(cpu, 0, file: file, line: line)
    XCTAssertLessThanOrEqual(cpu, 1, file: file, line: line)

    guard let memory = attributes.int(memoryKey) else {
      return XCTFail("\(memoryKey) is missing or not an int", file: file, line: line)
    }
    // An iOS app's resident memory is more than 1 MB and, in a test run, less than 8 GB.
    XCTAssertGreaterThan(memory, 1_000_000, file: file, line: line)
    XCTAssertLessThan(memory, 8_000_000_000, file: file, line: line)

    if let battery = attributes[batteryKey] {
      guard case let .doubleValue(charge)? = battery.value else {
        return XCTFail("\(batteryKey) is not a double", file: file, line: line)
      }
      XCTAssertGreaterThanOrEqual(charge, 0, file: file, line: line)
      XCTAssertLessThanOrEqual(charge, 1, file: file, line: line)
    }
  }

  func testSpansCarryDeviceAttributes() {
    XCTAssertFalse(OTLPOutput.spans.isEmpty)
    for exported in OTLPOutput.spans {
      assertDeviceAttributes(exported.span.attributes)
    }
  }

  func testLogsCarryDeviceAttributes() {
    XCTAssertFalse(OTLPOutput.logs.isEmpty)
    for exported in OTLPOutput.logs {
      assertDeviceAttributes(exported.record.attributes)
    }
  }
}
