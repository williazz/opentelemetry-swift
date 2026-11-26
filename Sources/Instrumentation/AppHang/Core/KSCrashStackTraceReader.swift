/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

#if CrashReporting

  import Darwin
  import Foundation
  import KSCrashDemangleFilter
  import KSCrashRecordingCore

  /// Captures the main thread's stack while it is blocked, with KSCrash's unwinder.
  ///
  /// `ksbt_captureBacktraceFromMachThread` suspends the thread, reads its registers, walks its
  /// frames with compact unwind, DWARF and the frame pointer, and resumes it. Between the suspend
  /// and the resume it allocates nothing and takes no mutex -- its only lock is an atomic flag
  /// that makes a second capture return no frames rather than wait -- so it cannot deadlock
  /// against a main thread that holds the allocator's lock. This reader keeps the frame buffer it
  /// writes into for the life of the process for the same reason.
  ///
  /// Everything after the capture, including resolving images and symbols, runs with the main
  /// thread free again.
  final class KSCrashStackTraceReader: MainThreadStackTraceReader {
    private let buffer: UnsafeMutableBufferPointer<UInt>
    private let includesSymbolNames: Bool

    /// KSCrash's cached, lock-free `dladdr`, and the image cache behind it, are what make
    /// resolving a frame safe while the main thread is still blocked. `ksdl_init` fills them;
    /// it is idempotent and `Crash` already calls it when it installs KSCrash.
    init(maxFrames: Int, includesSymbolNames: Bool) {
      buffer = UnsafeMutableBufferPointer<UInt>.allocate(capacity: max(maxFrames, 1))
      buffer.initialize(repeating: 0)
      self.includesSymbolNames = includesSymbolNames
      ksdl_init()
    }

    deinit {
      buffer.deallocate()
    }

    func capture(thread: MainThreadID) -> CapturedStackTrace? {
      guard let addresses = buffer.baseAddress else {
        return nil
      }
      var isTruncated = false
      let count = Int(captureBacktrace(machThread: thread,
                                       addresses: addresses,
                                       count: Int32(buffer.count),
                                       isTruncated: &isTruncated))
      // Zero frames means the unwinder failed or another capture was already in flight.
      guard count > 0 else {
        return nil
      }
      return CapturedStackTrace(
        addresses: Array(UnsafeBufferPointer(start: addresses, count: count)),
        isTruncated: isTruncated
      )
    }

    func format(_ capture: CapturedStackTrace, duration: TimeInterval) -> HangStackTrace {
      let frames = capture.addresses.enumerated().map { resolve(index: $0.offset, address: $0.element) }
      guard !frames.isEmpty else {
        return HangStackTrace(message: HangStackTraceDefaults.message,
                              stacktrace: HangStackTraceDefaults.stacktrace)
      }

      var lines = [
        String(format: "Hang on the main thread for %.3f seconds.", duration),
        "",
        "Thread 0 name:  main",
        "Thread 0:",
      ]
      lines.append(contentsOf: frames.map(frameLine))
      if capture.isTruncated {
        lines.append("... stack deeper than \(buffer.count) frames")
      }
      lines.append("")
      lines.append("Binary Images:")
      lines.append(contentsOf: binaryImageLines(for: frames))

      return HangStackTrace(message: message(for: frames), stacktrace: lines.joined(separator: "\n"))
    }

    // MARK: - Frames

    private struct ResolvedFrame {
      let index: Int
      let address: UInt
      let imageName: String
      let imagePath: String
      let imageBase: UInt
      let imageHeader: UnsafeRawPointer?
      let imagePathC: UnsafePointer<CChar>?
      let symbolName: String?
      let symbolAddress: UInt

      /// Whether the frame is in one of the app's own binaries, which is how
      /// [`CrashSummary`](../Crash/CrashSummary.swift) tells them apart too.
      var isAppImage: Bool { imagePath.contains(".app/") }

      var offsetIntoImage: UInt { address >= imageBase ? address - imageBase : 0 }
    }

    private func resolve(index: Int, address: UInt) -> ResolvedFrame {
      var info = Dl_info()
      guard ksdl_dladdr(address, &info), let header = info.dli_fbase else {
        return ResolvedFrame(index: index, address: address, imageName: "???", imagePath: "",
                             imageBase: 0, imageHeader: nil, imagePathC: nil,
                             symbolName: nil, symbolAddress: 0)
      }
      let path = info.dli_fname.map { String(cString: $0) } ?? ""
      return ResolvedFrame(
        index: index,
        address: address,
        imageName: path.split(separator: "/").last.map(String.init) ?? "???",
        imagePath: path,
        imageBase: UInt(bitPattern: header),
        imageHeader: UnsafeRawPointer(header),
        imagePathC: info.dli_fname,
        symbolName: info.dli_sname.map { String(cString: $0) },
        symbolAddress: info.dli_saddr.map { UInt(bitPattern: $0) } ?? 0
      )
    }

    /// Apple's unsymbolicated frame format, so a report from a hang reads like the one
    /// [`Crash`](../Crash/README.md) sends and the same backend symbolication applies:
    /// `0   Image   <address> <image load address> + <offset>`.
    private func frameLine(_ frame: ResolvedFrame) -> String {
      var line = padded("\(frame.index)", 4)
        + padded(frame.imageName, 30)
        + String(format: "0x%016lx 0x%lx + %lu", frame.address, frame.imageBase, frame.offsetIntoImage)
      if includesSymbolNames, let symbol = frame.symbolName {
        let symbolOffset = frame.address >= frame.symbolAddress ? frame.address - frame.symbolAddress : 0
        line += " (\(demangled(symbol)) + \(symbolOffset))"
      }
      return line
    }

    /// The image each frame falls in, with its UUID, so a backend can pick the matching dSYM.
    /// Only the images on the stack are listed, which keeps a hang's report a few lines long
    /// where a crash report's full image list is most of its size.
    private func binaryImageLines(for frames: [ResolvedFrame]) -> [String] {
      var seen = Set<UInt>()
      return frames.compactMap { frame -> String? in
        guard let header = frame.imageHeader, frame.imageBase != 0, seen.insert(frame.imageBase).inserted else {
          return nil
        }
        var image = KSBinaryImage()
        guard ksdl_binaryImageForHeader(header, frame.imagePathC, &image) else {
          return String(format: "0x%lx - ??? %@ <???> %@", frame.imageBase, frame.imageName, frame.imagePath)
        }
        let end = image.address + (image.size > 0 ? image.size - 1 : 0)
        return String(format: "0x%llx - 0x%llx %@ %@ <%@> %@",
                      image.address,
                      end,
                      frame.imageName,
                      architecture(cpuType: image.cpuType, cpuSubType: image.cpuSubType),
                      uuidString(image.uuid) ?? "???",
                      frame.imagePath)
      }
    }

    /// One line naming where the hang was: the first frame in the app's own code, which says
    /// more than the system call the main thread happens to be parked in, and the innermost
    /// frame when the app has none on the stack. Module and offset rather than a symbol, so the
    /// same hang groups together whether or not symbols were resolved on the device.
    private func message(for frames: [ResolvedFrame]) -> String {
      guard let frame = frames.first(where: \.isAppImage) ?? frames.first else {
        return HangStackTraceDefaults.message
      }
      guard frame.imageBase != 0 else {
        return "Hang detected at \(frame.imageName)"
      }
      return "Hang detected at \(frame.imageName) + \(frame.offsetIntoImage)"
    }

    // MARK: - Formatting helpers

    /// A Swift or C++ name as it was written, through the same demangler
    /// [`Crash`](../Crash/README.md) runs over a crash report. The name the device resolved is
    /// otherwise the mangled one, which reads as `$s14HackerNewsDemo...`.
    private func demangled(_ symbol: String) -> String {
      CrashReportFilterDemangle.demangledSwiftSymbol(symbol)
        ?? CrashReportFilterDemangle.demangledCppSymbol(symbol)
        ?? symbol
    }

    private func padded(_ text: String, _ width: Int) -> String {
      text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private func uuidString(_ bytes: UnsafePointer<UInt8>?) -> String? {
      guard let bytes else {
        return nil
      }
      return (0 ..< 16).map { String(format: "%02x", bytes[$0]) }.joined()
    }

    private func architecture(cpuType: Int32, cpuSubType: Int32) -> String {
      switch cpuType {
      case CPU_TYPE_ARM64:
        // The top byte of a subtype holds feature flags, so it is masked off before comparing.
        return cpuSubType & Int32(bitPattern: ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E ? "arm64e" : "arm64"
      case CPU_TYPE_ARM64_32:
        return "arm64_32"
      case CPU_TYPE_ARM:
        return "arm"
      case CPU_TYPE_X86_64:
        return "x86_64"
      case CPU_TYPE_X86:
        return "i386"
      default:
        return "unknown"
      }
    }
  }

#endif
