import XCTest
@testable import Sessions
@testable import OpenTelemetryApi
@testable import OpenTelemetrySdk

final class AwsSessionSpanSamplerTests: XCTestCase {
  var mockSessionManager: MockSpanSamplerSessionManager!
  var sampler: SessionSpanSampler!

  override func setUp() {
    super.setUp()
    mockSessionManager = MockSpanSamplerSessionManager()
    sampler = SessionSpanSampler(sessionManager: mockSessionManager)
  }

  func testShouldSampleWithSampledSession() {
    mockSessionManager.setSessionSampled(true)

    let decision = sampler.shouldSample(
      parentContext: nil,
      traceId: TraceId.random(),
      name: "test-span",
      kind: .client,
      attributes: [:],
      parentLinks: []
    )

    XCTAssertTrue(decision.isSampled)
    XCTAssertTrue(decision.attributes.isEmpty)
  }

  func testShouldSampleWithUnsampledSession() {
    mockSessionManager.setSessionSampled(false)

    let decision = sampler.shouldSample(
      parentContext: nil,
      traceId: TraceId.random(),
      name: "test-span",
      kind: .server,
      attributes: ["key": AttributeValue.string("value")],
      parentLinks: []
    )

    XCTAssertFalse(decision.isSampled)
    XCTAssertTrue(decision.attributes.isEmpty)
  }

  func testDescription() {
    XCTAssertEqual(sampler.description, "SessionSpanSampler")
  }

  func testSessionSamplingDecisionStruct() {
    let sampledDecision = SessionSamplingDecision(isSampled: true)
    XCTAssertTrue(sampledDecision.isSampled)
    XCTAssertTrue(sampledDecision.attributes.isEmpty)

    let unsampledDecision = SessionSamplingDecision(isSampled: false)
    XCTAssertFalse(unsampledDecision.isSampled)
    XCTAssertTrue(unsampledDecision.attributes.isEmpty)
  }

  func testSamplerUsesDefaultSessionManager() {
    // Test that sampler can be created without explicit session manager
    let defaultSampler = SessionSpanSampler()
    XCTAssertNotNil(defaultSampler)
    XCTAssertEqual(defaultSampler.description, "SessionSpanSampler")
  }
}

// MARK: - Mock Classes

class MockSpanSamplerSessionManager: SessionManager {
  private var _isSessionSampled: Bool = true

  override var isSessionSampled: Bool {
    return _isSessionSampled
  }

  func setSessionSampled(_ sampled: Bool) {
    _isSessionSampled = sampled
  }

  override init(configuration: SessionConfig = .default) {
    super.init(configuration: configuration)
  }
}
