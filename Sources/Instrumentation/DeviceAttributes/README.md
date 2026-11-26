# Device Attributes Instrumentation

Adds three readings to every span and log record: the battery's charge, the process's CPU utilization, and its resident memory.

| Attribute | Type | Meaning |
| --- | --- | --- |
| `hw.battery.charge` | double | Battery charge, 0 to 1. Absent when unknown. |
| `process.cpu.utilization` | double | Share of the device's CPU capacity the process uses, 0 to 1. |
| `process.memory.usage` | int | Resident memory of the process, in bytes. |

## Setup

```swift
import DeviceAttributesInstrumentation

// Call from the main thread at launch, before the first span.
DeviceAttributesInstrumentation.install()

let tracerProvider = TracerProviderBuilder()
  .add(spanProcessor: DeviceAttributesSpanProcessor())
  .add(spanProcessor: BatchSpanProcessor(spanExporter: spanExporter))
  .build()

let loggerProvider = LoggerProviderBuilder()
  .with(processors: [
    DeviceAttributesLogRecordProcessor(nextProcessor: BatchLogRecordProcessor(logRecordExporter: logExporter))
  ])
  .build()
```

`install()` is idempotent. It starts battery monitoring and creates the one `DeviceSampler` both processors share. Pass a `DeviceAttributesConfiguration` to change the sampling interval.

## Why attributes

These values change while the app runs, so they are not resource attributes: a resource describes the process once, at startup. A metric would report each value at the collection interval, detached from what the user was doing. A client-side SDK that exports a sample every 60 seconds can't say how much memory the app held when a particular screen load took four seconds. An attribute on the span or log record answers that.

The names `hw.battery.charge`, `process.cpu.utilization` and `process.memory.usage` are upstream **metric** names. Upstream defines no attribute for any of them, so the attributes live in this repository's [federated registry](../SemanticConventions/model/swift/device.yaml) and keep the metrics' meaning and units.

## Sampling

A reading costs little but isn't free, and a busy app starts hundreds of spans a second. The sampler reads the device at most once per interval, one second by default, and every span and log record in that second shares the reading.

- The sampler has no timer. An app that records nothing spends nothing.
- A reading is at most one interval old when a signal records it.
- A read of CPU and memory takes about 32 microseconds, so one read per second costs about 0.003% of a core. Method: `ProcessStatsTests.testRepeatedReadsLeakNoMachPorts` earlier ran 20,000 CPU reads in 0.633 s on an Apple silicon Mac, in a debug build, in a test process with a few dozen threads. Memory reads cost less. A release build on a phone with fewer threads is not measured.
- One second matches the kernel: the per-thread CPU figure it reports decays over about a second, so reading faster adds cost and no information.

## Battery

`UIDevice` is main-thread only, and spans start on any thread. The battery monitor turns on `isBatteryMonitoringEnabled`, reads the level once on the main thread, and updates a lock-protected value from `batteryLevelDidChangeNotification`. The sampler reads that value under a lock and never touches UIKit. Call `install()` from the main thread so the first span has a value.

**Unverified on a device.** A simulator never reports a level, so the unit tests check the battery logic with injected levels, and the integration run saw the attribute absent. No real-device run has confirmed that the attribute appears and tracks the charge.

UIKit reports -1 when the level is unknown, as it does on a simulator, and on a device while monitoring is still starting. The attribute is absent in that case. A value outside 0 to 1 is also dropped.

Battery monitoring is a setting that UIKit shares across the app. `install()` turns it on and never turns it off.

Only iOS reports a battery level. Other platforms omit the attribute. CPU and memory use the Mach kernel and work on every Apple platform. On other platforms the attributes are absent.

## Differences from the ADOT implementation

This ports [aws-otel-swift #73](https://github.com/aws-observability/aws-otel-swift/pull/73). It differs in these ways.

- **`process.memory.usage` is in bytes**, an integer, as the upstream metric defines it. ADOT reports megabytes as a double.
- **`process.cpu.utilization` is divided by the processor count**, so it runs from 0 to 1 as the upstream metric does. ADOT reports 0 to the number of cores, so an existing ADOT dashboard reads this attribute as a smaller number on the same load. Multiply by `ProcessInfo.activeProcessorCount` to recover ADOT's figure. To restore ADOT's range in the code, drop the division in `ProcessStats.cpuUtilization`.
- **One sampler reads all three values together** under one lock, where ADOT keeps three timestamps and three queue hops per signal.
- **The battery is read from a cache on the main thread's schedule.** ADOT sets `isBatteryMonitoringEnabled` and reads `UIDevice` on whichever thread starts the span.
- **The CPU read returns the thread list's Mach ports.** `task_threads` hands back a send right for each thread. ADOT frees the list but not the ports, which leaks one port name per thread on every read, and it skips the free altogether when the process has 1000 or more threads. `ProcessStatsTests.testRepeatedReadsLeakNoMachPorts` guards this.
- **The clock is monotonic**, so a wall-clock change can't freeze or flood the reads.

## Not recorded

- `process.cpu.utilization` is a snapshot, not the average over the interval between two exports that Android's `process.cpu.avg_utilization` reports.
- `hw.battery.state` (charging, discharging) is an upstream attribute and isn't recorded. Add it from `SemanticConventions.Hw.batteryState` if a consumer needs it.
