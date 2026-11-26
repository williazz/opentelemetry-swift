# App Hang Instrumentation

Status: development

Records every stretch where the app's main thread stopped answering, with the stack trace of
that thread taken while it was still blocked. `AppHangInstrumentation` reports each one as a
`device.hang` span in the `io.opentelemetry.apphang` scope, named to pair with the `device.crash`
event that [`Crash`](../Crash/README.md) reports.

```swift
import AppHang

AppHangInstrumentation.install()
```

Install it from the main thread, as early as possible, after the `TracerProvider` is registered.
Supported on Apple platforms. The live stack trace needs the `CrashReporting` package trait; see
[Without the trait](#without-the-trait).

## What a hang is

A pass of the main run loop that takes longer than `hangThreshold`, 250 ms by default. For that
long the app answered neither a touch nor a frame, and 250 ms is the point from which Apple's
Hangs instrument counts a microhang.

A `CFRunLoopObserver` on the main run loop reports `afterWaiting` when the loop wakes and
`beforeWaiting` when it goes back to sleep. The span runs between the two. A thread sitting in
`beforeWaiting` is idle rather than hung, so a quiet app records nothing. The observer watches
`commonModes`, which includes the tracking mode a scroll or a menu runs in, so a hang during a
gesture is seen too.

The main thread does two things per pass: one `NSLock` acquisition and one comparison. Reporting
the hang, formatting its stack trace and building the span all happen on the watchdog thread. An
app that has just recovered from a hang is handed no work on account of it.

### A busy device and a false positive

A hang is measured in wall-clock time, so a pass that the scheduler suspends counts as a hang
even though the app itself did little. That is on purpose: the user waited either way, and
Apple's Hangs instrument, MetricKit's hang rate and OpenTelemetry Android's ANR detection all
measure the same thing. A `device.hang` means the main thread did not answer for that long, not
that the app's code was at fault.

What the instrumentation cannot do is invent a hang:

- An idle app records nothing, however loaded the device is. The run loop is parked in
  `beforeWaiting`, and only the stretch between a wake and the next sleep is measured.
- Both timestamps come from the main thread's own run loop callbacks. A watchdog thread starved
  of CPU delays the stack trace, and loses it if the hang ends first, but it cannot stretch a
  hang or report one that did not happen.
- The duration is read from the monotonic clock, which does not advance while the system sleeps,
  so neither a sleeping device nor a clock adjustment inflates it.
- The three cases that would otherwise produce an invented hang, a launch before the app is
  active, a suspended app and a stopped debugger, are excluded below.

Measured rather than argued: on an 11-core cloud Mac under load averages of 39.8, 94.2 and 52.8,
a deliberate one-second block of the main thread was recorded as a hang of 1.003 s, with its
stack trace. A loaded machine delays the capture; it does not stretch the measurement.

Raise `hangThreshold` for an app that would rather hear only about the long ones.

### What is not a hang

| Case | Why it is excluded |
| --- | --- |
| The app has not become active yet | A launch is not a hang: until the first `didBecomeActive`, the main thread is busy bringing the app up, and every launch would otherwise report one. Recording starts at that activation, whether the app launched into the foreground or returned from the background. |
| The app is in the background | The system suspends a backgrounded app mid-pass, and the next `beforeWaiting` would otherwise report everything from the suspension to the next activation as one hang. The hang in progress is dropped at `didEnterBackgroundNotification`, and recording resumes at `willEnterForegroundNotification` or `didBecomeActiveNotification`, whichever arrives first. |
| A debugger has the process traced | A breakpoint stops the main thread, so every resume would be a hang. The `P_TRACED` flag is read per hang, as Apple's Technical Note TN2151 describes, because a debugger can attach at any time. Set `recordsHangsWhileTraced` to record them anyway. |
| The wall clock stepped during the hang | Durations are measured on the monotonic clock, so a clock adjustment cannot produce a span that ends before it starts. The span's start is still a wall clock time, so it lines up with the rest of the app's telemetry. |

## The live stack trace

A stack trace is only worth having while the main thread is still stuck: once the run loop
reports the hang, the thread has moved on and the frames that caused it are gone. So the
watchdog thread polls every `pollInterval` (100 ms), and captures the trace as soon as the
current pass has run for `stackTraceThreshold`, two thirds of `hangThreshold` by default. The
hang may turn out to be shorter than `hangThreshold` and go unreported, in which case the trace
is thrown away.

The capture is KSCrash's `ksbt_captureBacktraceFromMachThread`, which suspends the thread, reads
its registers, walks its frames with compact unwind, DWARF and the frame pointer, and resumes it.
Between the suspend and the resume it allocates nothing and takes no mutex: its only lock is an
atomic flag that makes a second capture return no frames instead of waiting. That matters because
a suspended main thread may hold the allocator's lock, and a capture that allocated would
deadlock the app it is measuring. For the same reason the frame buffer is allocated once, at
install, and the images and symbols are resolved afterwards, with the main thread free again,
through KSCrash's cached `ksdl_dladdr` rather than `dlopen`'s.

A capture that returns no frames, which is what a concurrent capture elsewhere in the process
looks like, is retried on the next poll. On watchOS no capture ever succeeds: KSCrash suspends
no thread there, so a watchOS hang carries its timing alone.

Only the main thread is captured. A hang is defined by that thread, and every other thread would
have to be suspended to read it.

### Why KSCrash and not PLCrashReporter

[The ADOT implementation](https://github.com/aws-observability/aws-otel-swift/pull/53) takes a
dependency on PLCrashReporter for `generateLiveReport()`. This repository already depends on
KSCrash for crash reporting, and KSCrash's `KSCrashRecordingCore` exposes the same capability as
a C function. Using it adds no second crash reporter to apps that already ship one, and it is
cheaper where the cost is paid: `generateLiveReport()` builds and encodes a whole crash report
for every thread, while this captures one thread's return addresses into a buffer that already
exists.

### What a trace looks like

`exception.stacktrace` holds Apple's unsymbolicated frame format, so a hang reads like the crash
report [`Crash`](../Crash/README.md) sends and the same backend symbolication applies:

```
Hang on the main thread for 1.000 seconds.

Thread 0 name:  main
Thread 0:
0   libsystem_kernel.dylib        0x00000001024d7e5c 0x1024d4000 + 15964
1   libsystem_c.dylib             0x0000000180178b8c 0x180108000 + 461708
2   Foundation                    0x0000000181153890 0x180840000 + 9517200
3   HackerNewsDemo.debug.dylib    0x0000000103b45048 0x103ae4000 + 397384
...
12  CoreFoundation                0x000000018041c904 0x18038f000 + 579844
13  GraphicsServices              0x00000001933599c0 0x193357000 + 10688
14  UIKitCore                     0x00000001864a54cc 0x185289000 + 18990284

Binary Images:
0x1024d4000 - 0x10250ffff libsystem_kernel.dylib arm64 <2144ef5784393be288a37d67766bcb03> /usr/lib/system/libsystem_kernel.dylib
0x180840000 - 0x1815f8ddf Foundation arm64 <2cc9fce008f93a0d8a2f6db229462de5> .../Foundation.framework/Foundation
0x103ae4000 - 0x104283fff HackerNewsDemo.debug.dylib arm64 <2f0a22a0c23e39f28fe8dbfabd102dd0> .../HackerNewsDemo.app/HackerNewsDemo.debug.dylib
```

Those frames are a real hang. The demo app slept one second on the main thread, and the capture
caught it in `nanosleep`, under `+[NSThread sleepForTimeInterval:]`, inside the main queue's
drain of the run loop.

Only the images on the stack are listed, with their UUIDs, which keeps a hang's report a few
lines long where a crash report's full image list is most of its size. The trace is bounded by
`maxFrames` rather than by a byte count, so a deep stack is cut at the bottom, furthest from
where the thread is stuck. Set `includesSymbolNames` to add the name each frame falls in, as
KSCrash's `symbolicatedSideBySide` style does; Swift and C++ names run through the same
demangler [`Crash`](../Crash/README.md) applies to a crash report.

`exception.message` names the first frame in the app's own binaries, as module and offset: `Hang
detected at HackerNewsDemo.debug.dylib + 397384`, frame 3 above. The app's own code says more
about the cause than the system call the thread is parked in, which is the same choice
[`CrashSummary`](../Crash/CrashSummary.swift) makes for a crash. Module and offset rather than a
symbol, so the same hang groups together whether or not symbols were resolved on the device.

## A span, not a log record

A hang has a start, an end and a duration, and a span is OpenTelemetry's signal for a span of
time. Reporting it as a log record would mean carrying the duration as an attribute and losing
the ability to see what else the app was doing meanwhile.

`Crash` reports a crash as a log record for the opposite reason: a crash is one moment, and it is
reported on the next launch rather than when it happened. ADOT reports hangs as spans and crashes
as log events, for the same split. [OpenTelemetry Android](https://github.com/open-telemetry/opentelemetry-android)
reports an ANR as a span with `exception.stacktrace` too, in its `io.opentelemetry.anr` scope.

## Hang attributes

| Attribute | Value |
| --- | --- |
| `exception.type` | `hang` |
| `exception.message` | Where the hang was, see [What a trace looks like](#what-a-trace-looks-like) |
| `exception.stacktrace` | The main thread's frames and their images |

The span is `INTERNAL` and has no parent: a hang belongs to no operation, so it starts its own
trace. `session.id` and `session.previous_id` arrive through `SessionSpanProcessor` when an app
uses [`Sessions`](../Sessions/README.md), as they do for any other span.

Every attribute is an upstream OpenTelemetry convention. The span is not: OpenTelemetry has no
convention for a hang, so `span.device_hang` is defined in this repository's
[federated registry](../SemanticConventions/README.md), in `model/swift/hang-spans.yaml`, and
the span name comes from the constant generated there. `device.hang` follows ADOT and pairs with
this repository's `device.crash`.

## Configuration

| Option | Default | Notes |
| --- | --- | --- |
| `hangThreshold` | 0.25 s | How long the main thread must be busy for the hang to be recorded |
| `stackTraceThreshold` | two thirds of `hangThreshold` | When the stack trace is captured, which must be before the hang is known to be one |
| `pollInterval` | 0.1 s | How often the watchdog thread looks for an ongoing hang |
| `capturesStackTrace` | `true` | Off leaves the hang's timing and drops `exception.stacktrace` |
| `maxFrames` | 128 | Frames recorded, and the size of the preallocated buffer |
| `includesSymbolNames` | `false` | On adds the demangled symbol each frame falls in |
| `recordsHangsWhileTraced` | `false` | On records hangs while a debugger is attached |

A value that would stop the instrumentation reporting anything, such as a threshold of zero, is
replaced with the default and reported through `OpenTelemetry.instance.feedbackHandler`. A
`stackTraceThreshold` above `hangThreshold` is lowered to it.

## Without the trait

`AppHangInstrumentation` is always available. Capturing a stack trace needs KSCrash, which comes
with the `CrashReporting` package trait:

```swift
.package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", from: "3.0.0", traits: ["CrashReporting"])
```

Without it, hangs are still detected and reported with their timing, `exception.message` is
`Hang detected at unknown location` and `exception.stacktrace` is `No stack trace captured`. The
instrumentation says so once, through `OpenTelemetry.instance.feedbackHandler`.

## Not recorded yet

- **Terminations.** An app the system kills for hanging reports nothing: the span ends when the
  main thread recovers, and it never does. KSCrash's watchdog monitor reports those on the next
  launch, through `Crash`.
- **Other threads.** A hang caused by waiting on another thread shows the wait, not what that
  thread was doing.
- **A hang metric.** Nothing counts hangs or sums the time lost to them. The spans carry enough
  for a backend to do both.
- **Hang duration as an attribute.** The span's duration is the duration.
