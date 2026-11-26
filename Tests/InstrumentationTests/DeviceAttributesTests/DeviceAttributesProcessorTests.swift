/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation
import InMemoryExporter
import InstrumentationSemanticConventions
import OpenTelemetryApi
import XCTest
@testable import DeviceAttributesInstrumentation
@testable import OpenTelemetrySdk

final class CapturingLogRecordProcessor: LogRecordProcessor {
  var records: [ReadableLogRecord] = []
  func onEmit(logRecord: ReadableLogRecord) { records.append(logRecord) }
  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult { .success }
  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .success }
}

final class DeviceAttributesProcessorTests: XCTestCase {
  private let batteryKey = "hw.battery.charge"
  private let cpuKey = "process.cpu.utilization"
  private let memoryKey = "process.memory.usage"

  private func sampler(_ sample: DeviceSample) -> DeviceSampler {
    DeviceSampler(reader: CountingReader(sample: sample), interval: 1)
  }

  private func finishedSpan(with sampler: DeviceSampler) -> SpanData {
    let exporter = InMemoryExporter()
    let provider = TracerProviderBuilder()
      .add(spanProcessor: DeviceAttributesSpanProcessor(sampler: sampler))
      .add(spanProcessor: SimpleSpanProcessor(spanExporter: exporter))
      .build()
    provider.get(instrumentationName: "test").spanBuilder(spanName: "work").startSpan().end()
    provider.forceFlush()
    return exporter.getFinishedSpanItems()[0]
  }

  func testRegistryKeysMatchTheKeysTheProcessorsWrite() {
    XCTAssertEqual(FederatedSemanticConventions.Hw.batteryCharge.rawValue, batteryKey)
    XCTAssertEqual(FederatedSemanticConventions.Process.cpuUtilization.rawValue, cpuKey)
    XCTAssertEqual(FederatedSemanticConventions.Process.memoryUsage.rawValue, memoryKey)
  }

  func testSpanCarriesAllThreeValuesWithTheirTypes() {
    let span = finishedSpan(with: sampler(DeviceSample(batteryCharge: 0.55, cpuUtilization: 0.125, memoryUsage: 123_456_789)))

    XCTAssertEqual(span.attributes[batteryKey], .double(0.55))
    XCTAssertEqual(span.attributes[cpuKey], .double(0.125))
    XCTAssertEqual(span.attributes[memoryKey], .int(123_456_789))
  }

  func testSpanOmitsAnUnavailableBatteryInsteadOfExportingASentinel() {
    let span = finishedSpan(with: sampler(DeviceSample(batteryCharge: nil, cpuUtilization: 0.1, memoryUsage: 10)))

    XCTAssertNil(span.attributes[batteryKey])
    XCTAssertNotNil(span.attributes[cpuKey])
    XCTAssertNotNil(span.attributes[memoryKey])
  }

  func testSpansInOneIntervalShareOneRead() {
    let reader = CountingReader()
    let shared = DeviceSampler(reader: reader, interval: 60)
    let processor = DeviceAttributesSpanProcessor(sampler: shared)
    let provider = TracerProviderBuilder().add(spanProcessor: processor).build()
    let tracer = provider.get(instrumentationName: "test")

    for _ in 0 ..< 50 { tracer.spanBuilder(spanName: "work").startSpan().end() }

    XCTAssertEqual(reader.readCount, 1)
  }

  func testSpanProcessorStartsButDoesNotEnd() {
    let processor = DeviceAttributesSpanProcessor(sampler: sampler(DeviceSample()))

    XCTAssertTrue(processor.isStartRequired)
    XCTAssertFalse(processor.isEndRequired)
  }

  func testLogRecordCarriesAllThreeValuesAndKeepsItsOwn() {
    let next = CapturingLogRecordProcessor()
    let processor = DeviceAttributesLogRecordProcessor(
      nextProcessor: next,
      sampler: sampler(DeviceSample(batteryCharge: 0.9, cpuUtilization: 0.5, memoryUsage: 42))
    )
    let record = ReadableLogRecord(
      resource: Resource(attributes: [:]),
      instrumentationScopeInfo: InstrumentationScopeInfo(),
      timestamp: Date(),
      observedTimestamp: Date(),
      spanContext: nil,
      severity: .info,
      body: .string("hello"),
      attributes: ["own": .string("kept")]
    )

    processor.onEmit(logRecord: record)

    let received = next.records[0]
    XCTAssertEqual(received.attributes[batteryKey], .double(0.9))
    XCTAssertEqual(received.attributes[cpuKey], .double(0.5))
    XCTAssertEqual(received.attributes[memoryKey], .int(42))
    XCTAssertEqual(received.attributes["own"], .string("kept"))
  }

  func testLogRecordOmitsAnUnavailableBattery() {
    let next = CapturingLogRecordProcessor()
    let processor = DeviceAttributesLogRecordProcessor(
      nextProcessor: next,
      sampler: sampler(DeviceSample(batteryCharge: nil, cpuUtilization: 0.5, memoryUsage: 42))
    )
    let record = ReadableLogRecord(
      resource: Resource(attributes: [:]),
      instrumentationScopeInfo: InstrumentationScopeInfo(),
      timestamp: Date(),
      observedTimestamp: Date(),
      spanContext: nil,
      severity: .info,
      body: .string("hello"),
      attributes: [:]
    )

    processor.onEmit(logRecord: record)

    XCTAssertNil(next.records[0].attributes[batteryKey])
  }

  func testInstallIsIdempotentAndTheInstalledSamplerReadsTheRealDevice() throws {
    DeviceAttributesInstrumentation.install(configuration: DeviceAttributesConfiguration(sampleInterval: 5))
    let first = DeviceAttributesInstrumentation.sampler
    DeviceAttributesInstrumentation.install(configuration: DeviceAttributesConfiguration(sampleInterval: 0))

    XCTAssertTrue(DeviceAttributesInstrumentation.isInstalled)
    XCTAssertTrue(DeviceAttributesInstrumentation.sampler === first)
    #if canImport(Darwin)
      XCTAssertNotNil(first.sample().memoryUsage)
      XCTAssertNotNil(first.sample().cpuUtilization)
    #endif
  }
}
