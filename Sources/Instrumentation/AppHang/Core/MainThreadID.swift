/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Darwin

/// The main thread's Mach port, which is what suspending it and walking its stack needs.
typealias MainThreadID = thread_t

enum MainThread {
  /// The calling thread's Mach port. Call it on the main thread, at install, and keep the value:
  /// it is the port the watchdog thread captures a stack trace from.
  ///
  /// `pthread_mach_thread_np` doesn't take a reference on the port, unlike `mach_thread_self`,
  /// so the value needs no matching deallocation.
  static func currentID() -> MainThreadID {
    pthread_mach_thread_np(pthread_self())
  }
}
