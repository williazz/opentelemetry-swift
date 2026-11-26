/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Darwin
import Foundation

/// Whether a debugger has this process traced, read the way Apple's Technical Note TN2151
/// describes: the process's `P_TRACED` flag from `sysctl`.
enum DebuggerDetection {
  static func isTraced() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else {
      return false
    }
    return info.kp_proc.p_flag & P_TRACED != 0
  }
}
