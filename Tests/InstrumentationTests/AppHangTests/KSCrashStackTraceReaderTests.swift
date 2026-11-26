/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

#if CrashReporting

  @testable import AppHang
  import Foundation
  import SharedTestUtils
  import XCTest

  /// Holds a thread blocked on a semaphore for as long as the test needs, so a capture of a
  /// thread that cannot run is deterministic: the thread is parked in `semaphore_wait_trap` from
  /// before the capture until after it.
  final class BlockedThread {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let threadID = Box()

    final class Box: @unchecked Sendable {
      private let lock = NSLock()
      private var value: MainThreadID = 0
      var id: MainThreadID {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
      }
    }

    /// Starts the thread and returns once it is blocked.
    init() {
      let thread = Thread { [started, release, threadID] in
        threadID.id = MainThread.currentID()
        started.signal()
        release.wait()
      }
      thread.name = "AppHangTests.BlockedThread"
      thread.start()
      started.wait()
      // The thread signalled before blocking; give it the moment it needs to park.
      Thread.sleep(forTimeInterval: 0.05)
    }

    var id: MainThreadID { threadID.id }

    func resume() {
      release.signal()
    }
  }

  final class KSCrashStackTraceReaderTests: XCTestCase {
    private var blocked: BlockedThread?

    override func setUpWithError() throws {
      try super.setUpWithError()
      // Suspending a thread under Thread Sanitizer stalls the whole process: TSan takes its own
      // locks around the memory the unwinder reads. The capture is exercised in the ordinary
      // test job instead.
      try XCTSkipIf(ConcurrencyTesting.isThreadSanitizerActive,
                    "capturing a blocked thread's stack is not run under Thread Sanitizer")
    }

    override func tearDown() {
      blocked?.resume()
      blocked = nil
      super.tearDown()
    }

    private func makeBlockedThread() -> BlockedThread {
      let thread = BlockedThread()
      blocked = thread
      return thread
    }

    func testCapturesABlockedThreadsFrames() throws {
      let thread = makeBlockedThread()
      let reader = KSCrashStackTraceReader(maxFrames: 128, includesSymbolNames: false)

      let capture = try XCTUnwrap(reader.capture(thread: thread.id))

      XCTAssertGreaterThan(capture.addresses.count, 1)
      XCTAssertFalse(capture.addresses.contains(0))
    }

    func testCaptureStopsAtMaxFrames() throws {
      let thread = makeBlockedThread()
      let reader = KSCrashStackTraceReader(maxFrames: 2, includesSymbolNames: false)

      let capture = try XCTUnwrap(reader.capture(thread: thread.id))

      XCTAssertEqual(capture.addresses.count, 2)
      XCTAssertTrue(capture.isTruncated)
    }

    func testFormatsACaptureAsAnAppleStyleReport() throws {
      let thread = makeBlockedThread()
      let reader = KSCrashStackTraceReader(maxFrames: 128, includesSymbolNames: false)
      let capture = try XCTUnwrap(reader.capture(thread: thread.id))

      let formatted = reader.format(capture, duration: 1.25)

      XCTAssertTrue(formatted.stacktrace.contains("Hang on the main thread for 1.250 seconds."),
                    formatted.stacktrace)
      XCTAssertTrue(formatted.stacktrace.contains("Thread 0:"), formatted.stacktrace)
      XCTAssertTrue(formatted.stacktrace.contains("Binary Images:"), formatted.stacktrace)
      XCTAssertTrue(formatted.message.hasPrefix("Hang detected at "), formatted.message)

      // The innermost frame of a thread blocked on a semaphore is in the kernel library, and the
      // image is reported for every frame.
      let frameLines = formatted.stacktrace
        .components(separatedBy: "\n")
        .filter { $0.hasPrefix("0 ") || $0.hasPrefix("1 ") || $0.hasPrefix("2 ") }
      XCTAssertEqual(frameLines.count, 3, formatted.stacktrace)
      for line in frameLines {
        XCTAssertTrue(line.contains(" + "), "frame has no offset into its image: \(line)")
        XCTAssertTrue(line.contains("0x"), "frame has no address: \(line)")
      }
    }

    func testEveryImageOnTheStackIsListedOnceWithItsUUID() throws {
      let thread = makeBlockedThread()
      let reader = KSCrashStackTraceReader(maxFrames: 128, includesSymbolNames: false)
      let capture = try XCTUnwrap(reader.capture(thread: thread.id))

      let formatted = reader.format(capture, duration: 1)
      let images = formatted.stacktrace
        .components(separatedBy: "Binary Images:\n").last?
        .components(separatedBy: "\n")
        .filter { !$0.isEmpty } ?? []

      XCTAssertFalse(images.isEmpty, formatted.stacktrace)
      XCTAssertEqual(Set(images).count, images.count, "an image is listed once")
      for image in images {
        let uuid = try XCTUnwrap(image.components(separatedBy: "<").last?.components(separatedBy: ">").first)
        XCTAssertEqual(uuid.count, 32, "image line has no 16-byte UUID: \(image)")
      }
    }

    func testSymbolNamesAreLeftOutByDefault() throws {
      let thread = makeBlockedThread()
      let capture = try XCTUnwrap(
        KSCrashStackTraceReader(maxFrames: 8, includesSymbolNames: false).capture(thread: thread.id)
      )

      let plain = KSCrashStackTraceReader(maxFrames: 8, includesSymbolNames: false)
        .format(capture, duration: 1).stacktrace
      let symbolicated = KSCrashStackTraceReader(maxFrames: 8, includesSymbolNames: true)
        .format(capture, duration: 1).stacktrace

      XCTAssertFalse(plain.contains("("), plain)
      XCTAssertTrue(symbolicated.contains("("), symbolicated)
    }

    /// The device resolves the mangled name, so a trace that carried it would read as
    /// `$s10AppHangTests...`. Swift names go through the same demangler a crash report uses.
    func testSymbolNamesAreDemangled() throws {
      let thread = makeBlockedThread()
      let reader = KSCrashStackTraceReader(maxFrames: 32, includesSymbolNames: true)
      let capture = try XCTUnwrap(reader.capture(thread: thread.id))

      let stacktrace = reader.format(capture, duration: 1).stacktrace

      XCTAssertFalse(stacktrace.contains("$s"), stacktrace)
      XCTAssertTrue(stacktrace.contains("semaphore_wait_trap"), stacktrace)
    }

    func testAnEmptyCaptureReportsTheDefaults() {
      let reader = KSCrashStackTraceReader(maxFrames: 8, includesSymbolNames: false)

      let formatted = reader.format(CapturedStackTrace(addresses: [], isTruncated: false), duration: 1)

      XCTAssertEqual(formatted.message, "Hang detected at unknown location")
      XCTAssertEqual(formatted.stacktrace, "No stack trace captured")
    }

    func testAnAddressInNoImageIsStillAFrame() {
      let reader = KSCrashStackTraceReader(maxFrames: 8, includesSymbolNames: false)

      let formatted = reader.format(CapturedStackTrace(addresses: [0x1], isTruncated: false), duration: 1)

      XCTAssertTrue(formatted.stacktrace.contains("???"), formatted.stacktrace)
      XCTAssertEqual(formatted.message, "Hang detected at ???")
    }

    func testCapturingAThreadThatIsGoneReportsNoFrames() {
      let reader = KSCrashStackTraceReader(maxFrames: 8, includesSymbolNames: false)

      // MACH_PORT_NULL names no thread, which is what a thread that has exited leaves behind.
      XCTAssertNil(reader.capture(thread: 0))
    }
  }

#endif
