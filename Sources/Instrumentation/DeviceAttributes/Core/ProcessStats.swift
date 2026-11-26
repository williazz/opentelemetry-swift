/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Reads the process's CPU use and resident memory from the Mach kernel.
enum ProcessStats {
  #if canImport(Darwin)
    /// The process's resident memory in bytes, from `task_info`, or `nil` if the call fails.
    static func residentMemory() -> Int? {
      var info = mach_task_basic_info()
      var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
          task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
      }
      guard result == KERN_SUCCESS else { return nil }
      return Int(clamping: info.resident_size)
    }

    /// The share of the device's CPU capacity the process uses, from 0 to 1, or `nil` if the
    /// kernel can't list the threads.
    ///
    /// Sums the kernel's `cpu_usage` for each thread. The kernel decays that figure over about a
    /// second, so one call gives a recent average and keeps no state between calls. `cpu_usage` is
    /// scaled so `TH_USAGE_SCALE` means one busy core, so the sum divided by the processor count
    /// is 1 when every core is busy.
    static func cpuUtilization(processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Double? {
      var threads: thread_act_array_t?
      var threadCount = mach_msg_type_number_t(0)
      guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS, let threads else {
        return nil
      }
      // The kernel allocated the list in this process. Return it whatever else happens.
      defer {
        for index in 0 ..< Int(threadCount) {
          mach_port_deallocate(mach_task_self_, threads[index])
        }
        vm_deallocate(
          mach_task_self_,
          vm_address_t(UInt(bitPattern: threads)),
          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
        )
      }

      var usages: [(cpuUsage: Int32, isIdle: Bool)] = []
      for index in 0 ..< Int(threadCount) {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
          pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
          }
        }
        // A thread that exits between the two calls fails here. Skip it.
        guard result == KERN_SUCCESS else { continue }
        usages.append((info.cpu_usage, info.flags & TH_FLAGS_IDLE != 0))
      }
      return utilization(threadUsages: usages, processorCount: processorCount)
    }

    /// The arithmetic of `cpuUtilization`, apart from the kernel calls, so a test can feed it
    /// known thread readings. Each `cpuUsage` is scaled so `TH_USAGE_SCALE` is one busy core.
    static func utilization(threadUsages: [(cpuUsage: Int32, isIdle: Bool)], processorCount: Int) -> Double {
      var busyCores = 0.0
      for usage in threadUsages where !usage.isIdle {
        busyCores += Double(usage.cpuUsage) / Double(TH_USAGE_SCALE)
      }
      // Dividing by the processor count gives upstream's 0 to 1 range. ADOT reports the undivided
      // sum, 0 to the core count, so removing the division restores its dashboards' scale.
      return DeviceSample.rounded(min(1, busyCores / Double(max(1, processorCount))))
    }
  #else
    static func residentMemory() -> Int? { nil }
    static func cpuUtilization(processorCount: Int = 1) -> Double? { nil }
  #endif
}
