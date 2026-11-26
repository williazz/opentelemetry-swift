/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest
@testable import UserId

final class UserIdManagerTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suiteName = "UserIdManagerTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  private func makeManager() -> UserIdManager {
    UserIdManager(persistence: UserDefaultsUserIdPersistence(defaults: defaults))
  }

  func testStartsEmptyAndGeneratesNothing() {
    XCTAssertNil(makeManager().userId)
    XCTAssertNil(defaults.string(forKey: UserDefaultsUserIdPersistence.defaultKey))
  }

  func testSetUserIdIsReadBack() {
    let manager = makeManager()
    manager.setUserId("account-1")
    XCTAssertEqual(manager.userId, "account-1")
  }

  func testUserIdSurvivesANewManager() {
    makeManager().setUserId("account-1")
    XCTAssertEqual(makeManager().userId, "account-1")
  }

  func testSetOverwritesThePersistedValue() {
    makeManager().setUserId("account-1")
    makeManager().setUserId("account-2")
    XCTAssertEqual(makeManager().userId, "account-2")
  }

  func testClearRemovesMemoryAndStorage() {
    let manager = makeManager()
    manager.setUserId("account-1")
    manager.clearUserId()
    XCTAssertNil(manager.userId)
    XCTAssertNil(defaults.string(forKey: UserDefaultsUserIdPersistence.defaultKey))
    XCTAssertNil(makeManager().userId)
  }

  func testEmptyAndWhitespaceValuesClear() {
    let manager = makeManager()
    for blank in ["", "   ", "\n\t", nil] as [String?] {
      manager.setUserId("account-1")
      manager.setUserId(blank)
      XCTAssertNil(manager.userId, "blank value \(String(describing: blank))")
      XCTAssertNil(defaults.string(forKey: UserDefaultsUserIdPersistence.defaultKey))
    }
  }

  func testBlankStoredValueIsIgnored() {
    defaults.set("  ", forKey: UserDefaultsUserIdPersistence.defaultKey)
    XCTAssertNil(makeManager().userId)
  }

  func testConcurrentSetsLeaveAStoredValue() {
    let manager = makeManager()
    DispatchQueue.concurrentPerform(iterations: 200) { i in
      manager.setUserId("account-\(i)")
      _ = manager.userId
    }
    XCTAssertNotNil(manager.userId)
    XCTAssertEqual(manager.userId, makeManager().userId)
  }

  func testProviderReturnsRegisteredManager() {
    let manager = makeManager()
    UserIdManagerProvider.register(userIdManager: manager)
    XCTAssertTrue(UserIdManagerProvider.getInstance() === manager)
  }
}
