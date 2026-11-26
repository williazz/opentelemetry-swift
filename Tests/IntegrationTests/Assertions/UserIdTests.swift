/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import XCTest

final class UserIdTests: XCTestCase {
  private static let key = "user.id"
  private static let userId = "integration-user-1"

  private func spans(_ launch: Scenario.Launch) -> [ExportedSpan] {
    OTLPOutput.launch(launch).spans
  }

  private func logs(_ launch: Scenario.Launch) -> [ExportedLog] {
    OTLPOutput.launch(launch).logs
  }

  func testNoLaunchBeforeOptInCarriesUserId() {
    for launch in [Scenario.Launch.main, .restoreFirst, .restoreSecond, .noRestore, .logLimits] {
      let spans = spans(launch)
      XCTAssertFalse(spans.isEmpty, "\(launch) exported no spans")
      XCTAssertTrue(spans.allSatisfy { $0.span.attributes.string(Self.key) == nil }, "\(launch) spans")
      XCTAssertTrue(logs(launch).allSatisfy { $0.record.attributes.string(Self.key) == nil }, "\(launch) logs")
    }
  }

  func testSetUserIdReachesEverySpanAndLog() {
    let spans = spans(.userIdSet)
    XCTAssertFalse(spans.isEmpty)
    XCTAssertTrue(spans.allSatisfy { $0.span.attributes.string(Self.key) == Self.userId })
    let logs = logs(.userIdSet).filter { $0.record.eventName == Scenario.logEventName }
    XCTAssertEqual(logs.count, 1)
    XCTAssertEqual(logs.first?.record.attributes.string(Self.key), Self.userId)
  }

  func testUserIdSurvivesRelaunch() {
    let spans = spans(.userIdRestored)
    XCTAssertFalse(spans.isEmpty)
    XCTAssertTrue(spans.allSatisfy { $0.span.attributes.string(Self.key) == Self.userId })
    let logs = logs(.userIdRestored).filter { $0.record.eventName == Scenario.logEventName }
    XCTAssertEqual(logs.first?.record.attributes.string(Self.key), Self.userId)
  }

  func testClearedUserIdIsGone() {
    let spans = spans(.userIdCleared)
    XCTAssertFalse(spans.isEmpty)
    XCTAssertTrue(spans.allSatisfy { $0.span.attributes.string(Self.key) == nil })
    XCTAssertTrue(logs(.userIdCleared).allSatisfy { $0.record.attributes.string(Self.key) == nil })
  }
}
