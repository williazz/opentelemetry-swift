/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import XCTest
@testable import DeviceAttributesInstrumentation

#if canImport(Darwin)
  final class ProcessStatsTests: XCTestCase {
    func testResidentMemoryIsAPlausibleByteCount() throws {
      let memory = try XCTUnwrap(ProcessStats.residentMemory())

      // A running test process holds more than 1 MB and less than the machine's memory.
      XCTAssertGreaterThan(memory, 1_000_000)
      XCTAssertLessThan(UInt64(memory), ProcessInfo.processInfo.physicalMemory)
    }

    func testResidentMemoryGrowsWhenTheProcessTouchesMemory() throws {
      let before = try XCTUnwrap(ProcessStats.residentMemory())
      var block = [UInt8](repeating: 1, count: 64 * 1024 * 1024)
      for index in stride(from: 0, to: block.count, by: 4096) { block[index] = 2 }
      let after = try XCTUnwrap(ProcessStats.residentMemory())

      XCTAssertGreaterThan(after - before, 32 * 1024 * 1024)
      XCTAssertEqual(block[0], 2)
    }

    // The arithmetic tests feed known thread readings, so no scheduler or machine load is involved.
    private let oneCore = Int32(TH_USAGE_SCALE)

    func testUtilizationDividesBusyCoresByTheProcessorCount() {
      // Two threads each using half a core, on a four-processor device: one core busy of four.
      let value = ProcessStats.utilization(
        threadUsages: [(oneCore / 2, false), (oneCore / 2, false)], processorCount: 4)

      XCTAssertEqual(value, 0.25)
    }

    func testUtilizationIsOneWhenEveryCoreIsBusy() {
      let value = ProcessStats.utilization(
        threadUsages: Array(repeating: (oneCore, false), count: 6), processorCount: 6)

      XCTAssertEqual(value, 1)
    }

    func testUtilizationCapsAtOne() {
      // More runnable threads than processors can sum past the capacity.
      let value = ProcessStats.utilization(
        threadUsages: Array(repeating: (oneCore, false), count: 10), processorCount: 4)

      XCTAssertEqual(value, 1)
    }

    func testUtilizationIgnoresIdleThreads() {
      let value = ProcessStats.utilization(
        threadUsages: [(oneCore, true), (oneCore / 2, false)], processorCount: 1)

      XCTAssertEqual(value, 0.5)
    }

    func testUtilizationOfNoThreadsIsZero() {
      XCTAssertEqual(ProcessStats.utilization(threadUsages: [], processorCount: 4), 0)
    }

    func testUtilizationTreatsAZeroProcessorCountAsOne() {
      XCTAssertEqual(ProcessStats.utilization(threadUsages: [(oneCore / 2, false)], processorCount: 0), 0.5)
    }

    func testUtilizationRoundsToFourDecimals() {
      XCTAssertEqual(ProcessStats.utilization(threadUsages: [(1, false)], processorCount: 3), 0.0003)
    }

    // The live test proves the real `task_threads` path moves with load. It polls for up to 10
    // seconds against a floor far below any plausible share, so a busy machine slows it and
    // doesn't fail it.
    func testLiveCPUUtilizationRisesWhileAThreadSpins() throws {
      let stop = ManagedFlag()
      let spinner = Thread {
        while !stop.isSet { _ = (0 ..< 1000).reduce(0, +) }
      }
      spinner.start()
      defer { stop.set() }

      var observed = 0.0
      let deadline = Date().addingTimeInterval(10)
      while observed <= 0.001, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
        observed = try XCTUnwrap(ProcessStats.cpuUtilization(processorCount: 1))
      }

      XCTAssertGreaterThan(observed, 0.001, "utilization never rose above the floor in 10 s")
    }

    func testCPUUtilizationStaysWithinBounds() throws {
      let value = try XCTUnwrap(ProcessStats.cpuUtilization())

      XCTAssertGreaterThanOrEqual(value, 0)
      XCTAssertLessThanOrEqual(value, 1)
    }

    func testRepeatedReadsLeakNoMachPorts() throws {
      _ = ProcessStats.cpuUtilization()
      let before = try XCTUnwrap(Self.portCount())

      for _ in 0 ..< 2000 { _ = ProcessStats.cpuUtilization() }

      // `task_threads` hands back a send right per thread. Each left unreleased adds a name.
      let after = try XCTUnwrap(Self.portCount())
      XCTAssertLessThan(after - before, 50)
    }

    private static func portCount() -> Int? {
      var names: mach_port_name_array_t?
      var nameCount = mach_msg_type_number_t(0)
      var types: mach_port_type_array_t?
      var typeCount = mach_msg_type_number_t(0)
      guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS else {
        return nil
      }
      if let names {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)), vm_size_t(Int(nameCount) * MemoryLayout<mach_port_name_t>.stride))
      }
      if let types {
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)), vm_size_t(Int(typeCount) * MemoryLayout<mach_port_type_t>.stride))
      }
      return Int(nameCount)
    }
  }

  final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
  }
#endif
