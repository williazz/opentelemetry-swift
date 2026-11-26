/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

/// Stores the user ID between launches.
///
/// The default, `UserDefaultsUserIdPersistence`, keeps the value in `UserDefaults`.
/// Supply your own conformance to store it elsewhere, for example in the Keychain.
public protocol UserIdPersistence: Sendable {
  /// Returns the stored user ID, or `nil` when none is stored.
  func read() -> String?
  /// Stores `userId`. A `nil` value removes the stored ID.
  func write(_ userId: String?)
}

/// Keeps the user ID in `UserDefaults`.
///
/// `UserDefaults` is deleted with the app. A Keychain item survives uninstall,
/// which would let an identifier outlive the app the person removed.
public struct UserDefaultsUserIdPersistence: UserIdPersistence, @unchecked Sendable {
  public static let defaultKey = "opentelemetry.user.id"

  private let defaults: UserDefaults
  private let key: String

  public init(defaults: UserDefaults = .standard, key: String = UserDefaultsUserIdPersistence.defaultKey) {
    self.defaults = defaults
    self.key = key
  }

  public func read() -> String? {
    defaults.string(forKey: key)
  }

  public func write(_ userId: String?) {
    if let userId {
      defaults.set(userId, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}
