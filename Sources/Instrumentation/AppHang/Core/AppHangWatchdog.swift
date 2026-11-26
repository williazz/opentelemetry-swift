/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Darwin
import Foundation
import OpenTelemetryApi

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// Watches the main thread and reports what it finds.
///
/// Two threads do the work. The main thread's run loop observer marks when a pass of the run loop
/// starts and ends, which is what says a hang happened and how long it lasted. A watchdog thread
/// polls for a pass that is still running, and captures the main thread's stack trace while it is
/// still blocked -- the only time that trace exists. Formatting the trace and recording the span
/// also happen on the watchdog thread.
///
/// `@unchecked Sendable`: `mainThread` is written on the main thread before the first poll is
/// scheduled, and read on the watchdog thread afterwards. `observer` and `lifecycleObservers` are
/// only touched on the main thread and `timer` only on the watchdog queue, each from `start()`.
/// All state the two threads share is in `HangDetector`, behind its lock.
final class AppHangWatchdog: @unchecked Sendable {
  private let configuration: AppHangInstrumentationConfiguration
  private let detector: HangDetector
  private let recorder: HangRecorder
  private let stackTraceReader: MainThreadStackTraceReader
  private let queue: DispatchQueue

  private var mainThread: MainThreadID = 0
  private var timer: DispatchSourceTimer?
  private var observer: CFRunLoopObserver?
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(configuration: AppHangInstrumentationConfiguration,
       detector: HangDetector,
       recorder: HangRecorder,
       stackTraceReader: MainThreadStackTraceReader,
       queue: DispatchQueue = DispatchQueue(label: AppHangInstrumentation.instrumentationScope,
                                            qos: .userInitiated)) {
    self.configuration = configuration
    self.detector = detector
    self.recorder = recorder
    self.stackTraceReader = stackTraceReader
    self.queue = queue
  }

  /// Starts watching. The run loop observer must be added on the main thread, so a call from
  /// anywhere else is forwarded there.
  func start() {
    if Thread.isMainThread {
      startOnMainThread()
    } else {
      DispatchQueue.main.async { self.startOnMainThread() }
    }
  }

  /// Recording waits for the app to become active unless it is active already. During a launch
  /// `applicationState` reads `.background` or `.inactive`, and the main thread is busy bringing
  /// the app up: counting that as a hang would report one on every launch, and launch timing is
  /// the launch instrumentation's to measure. An app that installs the instrumentation later,
  /// when it is already active, records from here.
  private func startOnMainThread() {
    mainThread = MainThread.currentID()
    if !isActive() {
      detector.enteredBackground()
    }
    observeRunLoop()
    observeLifecycle()
    // Dispatched after `mainThread` is set, so the first poll already has a thread to capture.
    queue.async { self.startPolling() }
  }

  /// Stops watching: the run loop observer, the poll timer and the lifecycle observers all go.
  /// Nothing in an app needs this -- hang detection lasts as long as the process -- so it is not
  /// public API. It exists so a test can leave the process as it found it, rather than leaving an
  /// observer behind that reports every later test that blocks the main thread as a hang.
  /// Call it on the main thread, where the observer was added.
  func stop() {
    if let observer {
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
      self.observer = nil
    }
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    lifecycleObservers = []
    queue.sync {
      timer?.cancel()
      timer = nil
    }
  }

  // MARK: - Main thread

  /// `afterWaiting` and `beforeWaiting` bracket the work of one pass of the run loop: the loop
  /// wakes, runs whatever it was woken for, and reports again as it goes back to sleep. The time
  /// between them is how long the main thread was unable to answer the user, which is what a
  /// hang is. A thread parked in `beforeWaiting` is idle, not hung, which is why a backgrounded
  /// or merely quiet app reports nothing.
  ///
  /// `commonModes` covers the tracking mode a scroll or a menu runs in, so a hang during a
  /// gesture is seen too.
  private func observeRunLoop() {
    let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
    let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
      guard let self else {
        return
      }
      if activity == .afterWaiting {
        detector.didWake()
      } else if let hang = detector.willSleep() {
        queue.async { self.recorder.record(hang) }
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    self.observer = observer
  }

  /// `didBecomeActive` as well as `willEnterForeground`, because a cold launch never posts
  /// `willEnterForeground`: it goes from background straight to active. An app that installed
  /// the instrumentation from `didFinishLaunching`, where `applicationState` still reads
  /// `.background`, would otherwise record nothing for the rest of the process.
  private func observeLifecycle() {
    #if canImport(UIKit) && !os(watchOS)
      lifecycleObservers = [
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.detector.enteredBackground() },
        observe(UIApplication.willEnterForegroundNotification) { [weak self] in self?.detector.enteringForeground() },
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.detector.enteringForeground() },
      ]
    #endif
  }

  private func observe(_ name: Notification.Name, handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in handler() }
  }

  /// Whether the app is active right now. Only readable on the main thread, and only on the
  /// platforms that have an application state; elsewhere the watchdog records from install.
  private func isActive() -> Bool {
    #if canImport(UIKit) && !os(watchOS)
      guard Thread.isMainThread else {
        return false
      }
      return MainActor.assumeIsolated {
        // `UIApplication.shared` is unavailable in app extensions, so look it up dynamically.
        let application = UIApplication.value(forKeyPath: #keyPath(UIApplication.shared)) as? UIApplication
        return application?.applicationState == .active
      }
    #else
      return true
    #endif
  }

  // MARK: - Watchdog thread

  private func startPolling() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + configuration.pollInterval,
                   repeating: configuration.pollInterval,
                   leeway: .milliseconds(10))
    timer.setEventHandler { [weak self] in self?.captureStackTraceIfHanging() }
    timer.resume()
    self.timer = timer
  }

  /// Captures the main thread's stack trace if it has been busy for longer than
  /// `stackTraceThreshold`. The capture happens before the hang is known to be one, because by
  /// the time the run loop reports the hang the main thread has moved on and its stack is gone.
  private func captureStackTraceIfHanging() {
    guard let ongoing = detector.stackTraceIsDue() else {
      return
    }
    detector.record(stackTrace: stackTraceReader.capture(thread: mainThread), for: ongoing)
  }
}
