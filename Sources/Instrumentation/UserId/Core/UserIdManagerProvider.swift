/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Provides thread-safe singleton access to `UserIdManager`.
///
/// ```swift
/// UserIdManagerProvider.register(userIdManager: UserIdManager())
/// UserIdManagerProvider.getInstance().setUserId("account-1234")
/// ```
public enum UserIdManagerProvider {
  nonisolated(unsafe) private static var instance: UserIdManager?
  private static let lock = NSLock()

  /// Registers `userIdManager` as the singleton.
  public static func register(userIdManager: UserIdManager) {
    lock.withLock { instance = userIdManager }
  }

  /// Returns the registered manager, creating one with default persistence if none exists.
  public static func getInstance() -> UserIdManager {
    lock.withLock {
      if let instance { return instance }
      let created = UserIdManager()
      instance = created
      return created
    }
  }
}
