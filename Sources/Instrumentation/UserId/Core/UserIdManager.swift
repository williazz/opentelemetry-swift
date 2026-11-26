/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Holds the application's user ID and persists it across launches.
///
/// The manager never invents an ID. It stays empty until the application calls
/// `setUserId(_:)`, and the processors attach nothing while it is empty.
public final class UserIdManager: @unchecked Sendable {
  private let persistence: UserIdPersistence
  private let lock = NSLock()
  private var current: String?

  /// Creates a manager and restores the ID the application stored on an earlier launch.
  public init(persistence: UserIdPersistence = UserDefaultsUserIdPersistence()) {
    self.persistence = persistence
    current = Self.normalized(persistence.read())
  }

  /// The current user ID, or `nil` when none is set.
  public var userId: String? {
    lock.withLock { current }
  }

  /// Sets the user ID and persists it.
  ///
  /// A `nil`, empty, or whitespace-only value clears the ID, as `clearUserId()` does.
  /// Spans and log records created after the call carry the new value.
  public func setUserId(_ userId: String?) {
    let value = Self.normalized(userId)
    lock.withLock {
      current = value
      persistence.write(value)
    }
  }

  /// Removes the user ID from memory and from persistent storage.
  public func clearUserId() {
    setUserId(nil)
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }
}
