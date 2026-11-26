# Integration tests

End-to-end check that the SDK, instrumentations and OTLP/HTTP exporters in this
repo work together inside a real iOS app. The flow is:

1. `Examples/HackerNewsDemo` is built and installed in the iOS simulator.
2. The app is launched several times with `--integrationTestMode` and an
   `--integrationLaunch <tag>`. For each launch the OpenTelemetry Collector
   dumps everything it receives to `Tests/IntegrationTests/out/<tag>/{traces,logs}.pb`,
   and the runner waits for the `integration.test.complete` marker span.
   `IntegrationTestScenario` in the app decides what each launch emits:
   - `main`: custom spans and a log record, three `URLSession` requests
     against the status server's `/status/{200,404,500}` endpoints, and a session
     expiry via a 2s session timeout, plus whatever the `Sessions` and
     `ResourceExtension` instrumentations add.
   - `main-stable`: the `main` scenario again with
     `--httpSemanticConvention stable`, so `NetworkSpanTests` can assert the
     stable HTTP attributes and `error.type` for 404/500 against the old-mode
     `main` launch.
   - `max-lifetime`: continuous spans with `maxLifetime: 3`, so the session
     must roll over without ever going idle.
   - `restore-first` / `restore-second`: `restorePersistedSession: true`, so
     the second launch must resume the first one's session.
   - `no-restore`: `restorePersistedSession: false`, so a new session starts
     with the persisted one as its previous session.
   - `crash` / `crash-report`: `crash` records its session in a probe span and
     then calls `fatalError`; KSCrash stores the report. `crash-report` runs in
     a new session and reports it as a `device.crash` log, which must keep the
     crashed session's id and the crash time, be an Apple-format report left
     unsymbolicated and within `maxStackTraceBytes` (the defaults), and have an
     `exception.message` that matches the report's crashed frame.
   - `symbolicated/crash` / `symbolicated/crash-report`: the same crash again,
     reported with `--reportStyle symbolicated`, so the crashed thread's frames
     must carry demangled on-device symbol names.
   - `log-limits`: opt-in session log filtering with zero and one attribute
     limits. Retained decisions control historical logs, unknown decisions are
     preserved, and stripped lifecycle records must not start another session.
   - `app-start-resume`: a warm launch. Once its first frame is displayed, the
     runner opens Settings and then launches the app again, which brings the
     running process back to the foreground for a `resume`.
   - `app-start-late-install`: installs `MincoreLaunchInstrumentation` after the
     app first became active, so the launch must not be recorded. The second
     activation blocks the main thread while the runner opens Settings, so the
     app is in the background before its first frame, and that activation must
     not produce a resume that completed: it's either dropped or recorded with
     `app.resume.outcome` of `abandoned`. The third must be a completed `hot`
     `resume`.
   - `app-start-background`: the runner sends a silent push, so the system
     launches the app in the background (as for a background fetch) and
     connects its scene there, then brings it to the foreground. The first
     activation must be a `resume` from `willEnterForeground`. A process the
     system starts gets no launch arguments, so the runner passes the
     collector endpoint and launch tag with `launchctl setenv` in the
     simulator.
   - `app-start-update`: the runner first reinstalls the app with its build
     number bumped, as an app update does, which is a cause the launch history
     calls `cold`.
   - `app-start-reinstall`: the runner installs that same build again, so only
     the install directory differs, which the launch history also calls `cold`.
     Neither launch is asserted to be `cold` outright: the simulator shares the
     Mac's page cache, so these launches are usually classified by page
     sampling instead, and the assertion checks the rule that actually applied
     — the type follows the ratio under `page_sampling`, and is `cold` under
     `launch_history`.
   - `app-start-mincore`: the simulator shares the Mac's page cache, so the
     launch type isn't predictable, but it must agree with the sampled pages on
     the span. The launch has a library inserted, as Xcode does, so the app
     isn't the first image in dyld's list.
   Every launch also records its process start (with the process's task role)
   and each scene connection, `willEnterForeground`, `didBecomeActive` and
   `didEnterBackground` as zero-length marker spans. The app records `app.start`,
   so `AppStartTests` checks the whole span tree of the `app-start-mincore`
   launch, the task roles, and the spans each launch above is for: the resume
   after `app-start-resume`, the absent launch and single completed resume of
   `app-start-late-install`, the `background_launched` resume of
   `app-start-background`, and the one launch `app-start-update` and
   `app-start-reinstall` each record.
   They compare each span's timestamps with the markers, following the span definition
   in `Sources/Instrumentation/SemanticConventions/model/swift/spans.yaml`.
   Attribute keys and values come from `FederatedSemanticConventions`, which is
   generated from that registry, so a span with a key that isn't in the
   registry fails.
   `main` is the first launch after installation, so it's `cold`,
   and the launches after it are `warm`. Prewarming isn't covered: setting
   `ActivePrewarm` makes the system hold the process before `main()` until a
   real launch resumes it. Focus loss isn't covered, because only UI automation
   can dismiss a system alert, and neither is a new scene connecting as the app
   resumes, because an iPhone app can't destroy its only scene.
   - `hang`: blocks the main thread for one second, which must be reported as a
     single `device.hang` span of that length, carrying the main thread's live
     stack trace and the session it happened in.
   Session config is passed as launch arguments because `SessionConfig` is
   only read when a `SessionManager` is created. The app stays installed
   between launches so persisted session state and stored crash reports carry
   over.
3. The assertions in `Assertions/` are run with `swift test` against the
   dumped files. `OTLPOutput.main` is the main launch and
   `OTLPOutput.launch(...)` selects the others.

This is a standalone SwiftPM package so the root `swift test` never runs it.

An assertion never names a backend. `OTLPOutput` asks a `TelemetrySource` for
one launch's spans and logs, and the runner picks the source: files from the
collector by default, or a query against Grafana Tempo with
`--backend grafana`. See [Backends](#backends).

## Running locally

```shell
make integ-tests-ios
# or, with options
Scripts/run-integration-tests.sh --simulator <udid> --port 4318 --status-port 4319
```

### Crash examples

```shell
Scripts/run-integration-tests.sh --crash-examples
```

Instead of the launches above, crashes the demo app once per `CrashType` in
`Examples/HackerNewsDemo/HackerNewsDemo/CrashType.swift` (Swift traps, an
uncaught NSException, a bad memory access, a stack overflow) and reports each
crash on the following launch. Each one is saved in
`out/crash-examples/<type>/`: KSCrash's raw JSON report in `kscrash/`, and the
exported telemetry, including the `device.crash` log, in `report/`. Only
`CrashExamplesTests` runs, which checks every crash was reported with its kind,
a description and the session it happened in, and prints a Markdown table of
`exception.type` and `exception.message` per crash. The examples in
`Sources/Instrumentation/Crash/README.md` come from this table. The normal run
also keeps the `crash` launch's raw report in `out/crash/kscrash/`.

`make integ-build-ios` builds the demo app on its own and
`make integ-tests-without-building-ios` runs the rest against that build, which
is how CI splits the job so the app's DerivedData can be cached.

Requirements: Xcode with an iOS simulator, and `jq` (used to resolve the
simulator and to poll Tempo). `xcbeautify` is optional. On an arm64 Mac, run
the script from an arm64 shell, or under `arch -arm64`: an x86_64 shell cannot
load the arm64 XCTest bundle, and `swift test` then runs nothing. The runner
fails rather than report success when no assertion ran. Run `Scripts/run-integration-tests.sh --help`
for the full list of flags. The collected files stay in `out/` after a run,
so the assertions can be re-run on their own:

```shell
swift test --package-path Tests/IntegrationTests
```

## Local endpoint

Telemetry goes to the real thing: the OpenTelemetry Collector, `otelcol`
core distribution, pinned by version and sha256 in
`Scripts/run-integration-tests.sh`. The runner downloads the ~30 MB macOS
binary once into `.collector/` (cached in CI) and starts it per launch with
`collector.yaml`: an `otlp` receiver on port 4318 and `file` exporters in
`proto` format, a stream of length-prefixed `Export<Signal>ServiceRequest`
messages. No Docker needed, so the same flow runs on GitHub's
macOS runners. Bump `COLLECTOR_VERSION` and both checksums together. The
collector's own metrics are off: that endpoint binds a fixed `127.0.0.1:8888`
which `--port` cannot move, so leaving it on stops a second worktree from
running the collector path at the same time.

`StatusServer/` is a tiny swift-nio server on port 4319 that only answers
`GET /status/<code>` and `GET /health`. The app's integration scenario sends
its `URLSession` requests there so the network spans have deterministic
status codes without the public internet. It carries no OTLP code.

The assertions decode those files with the generated `Opentelemetry_Proto_*`
structs from this repo's `OpenTelemetryProtocolExporterCommon`, the same
types the exporters serialize, so there is no hand-written wire model. JSON
was ruled out because OTLP/JSON hex-encodes ids, which SwiftProtobuf's JSON
decoder rejects.

## Backends

`--backend` chooses where a launch is collected and where the assertions read
it back from.

| | `collector` (the default) | `remote-collector` | `grafana` |
|---|---|---|---|
| Machine | this one | a Revyl cloud Mac | this one, or a Revyl cloud device |
| Where the app exports | `otelcol` on `localhost` | `otelcol` on the cloud Mac's `localhost` | a hosted OTLP endpoint |
| Where the assertions read | `out/<launch>/{traces,logs}.pb` | the same files, on the cloud Mac | Tempo's `/api/search` and `/api/traces/<id>` |
| Signals | traces and logs | traces and logs | traces |
| Assertions | every suite | every suite | the span suites |
| Fidelity | the bytes the exporter sent | the bytes the exporter sent | what Tempo chose to keep |
| Determinism | the file holds an export as soon as the collector writes it | the same | eventually consistent, so every read polls |
| Runs in CI | yes | no | no |

**`collector`** is the default and the only one CI runs: hermetic, offline,
complete, and unable to fail for a reason outside this repository.

**`remote-collector`** is the same path on a Revyl cloud Mac, which has Xcode,
the iOS simulator runtimes, git, curl and jq. The collector, the status server
and the simulator all live on that one machine, so the runner goes there
unchanged and the assertions read real files. That is what makes it the path to
reach for when a run has to happen somewhere other than this laptop: the
telemetry is byte-for-byte what the exporter sent, there is no ingestion lag to
poll for and no read scope to be granted, and one Mac per branch means several
branches can run at once.

**`grafana`** is the only path that shows whether the telemetry survives a real
backend round-trip, which neither collector path can. That is its whole value,
and the reason to keep it; it is not where the assertion load belongs. It is
also the path still waiting on a `traces:read` scope.

`TelemetrySource` in `Assertions/TelemetrySource.swift` is the seam.
`CollectorFileSource` decodes the collector's files; `TempoSource` queries
Tempo and decodes its protobuf. Both hand back `ExportedSpan` and
`ExportedLog`, so no assertion mentions a backend — `remote-collector` needs no
source of its own, because on the cloud Mac it *is* the collector backend. One
source is built per launch per test process, which is what keeps a remote
backend from being queried once per assertion.

### Running on a Revyl cloud Mac

```shell
Scripts/run-integration-tests.sh --backend remote-collector
# or, to keep the Mac and pass the driver's own flags
Scripts/run-integration-tests-remote.sh --computer <id> -- --skip-build
```

`--backend remote-collector` hands the run to
`Scripts/run-integration-tests-remote.sh`, forwarding every other argument.
Flags naming something local, such as `--simulator` or `--port`, mean nothing on
the Mac and should be left off. The driver creates a Mac and stops it on the way
out, because concurrency is limited; `--computer <id>`, or
`OTEL_INTEGRATION_COMPUTER`, reuses a running one and keeps it.

The worktree is normally uncommitted, so the tree moves as a shallow clone of
`origin` at `HEAD` plus one patch of everything uncommitted: `git diff HEAD` for
tracked changes, and a `new file` patch per untracked file, built with
`git diff --no-index` so the index is never touched. On the Mac the driver
compares the patch's byte count, runs `git apply --check`, then applies it, and
stops on the first failure — a half-applied patch would produce a green run that
proves nothing. It prints `git status --short` afterwards, which should match
the local one.

Two limits shape the transfer: `revyl computer files write` takes at most 65536
bytes, so the patch goes up in 48 KiB pieces and is joined on the Mac, and
`revyl computer files read` returns at most 1 MiB, so the collected telemetry
comes back as a gzipped tar into `out-remote/` only while it fits. The
assertions have already run on the Mac either way; that copy is for reading a
failure here, or for re-running the assertions locally against the same files.

### Telling one launch from another

A file backend separates launches by directory. A shared backend cannot, so the
runner marks each launch with two resource attributes,
`integration.run.id=<run>` and `integration.launch=<tag>`, passed as
`OTEL_RESOURCE_ATTRIBUTES`, and `TempoSource` selects on both:

```
{resource.integration.run.id="<run>" && resource.integration.launch="<tag>"}
```

Two runs, and two launches of one run, therefore never see each other's spans,
even against a stack other people are pushing to. A unique `service.name` per
launch would be simpler, and Tempo indexes it, but `service.name` is itself
under test: `ResourceAttributesTests` asserts the app reports
`HackerNewsDemo`. The run id is test metadata and belongs in an attribute of
its own.

The SDK's `EnvVarResource` reads `OTEL_RESOURCE_ATTRIBUTES` from the process
environment only. A harness driving a device it does not own cannot set that,
so `TelemetryConfig.environmentResource` in the demo app reads the variable
through `setting(_:)`, which falls back to `UserDefaults`, and parses it with
`EnvVarResource.get(environment:)`. The detected resource and the service name
still win over it.

### Running against Grafana Cloud

```shell
export OTEL_EXPORTER_OTLP_HEADERS='Authorization=Basic%20<base64 of instanceID:token>'
export OTEL_INTEGRATION_TEMPO_AUTH='<tempo instance id>:<token>'
Scripts/run-integration-tests.sh \
  --backend grafana \
  --otlp-endpoint https://otlp-gateway-<region>.grafana.net/otlp \
  --tempo-url https://tempo-<cluster>.grafana.net/tempo
```

Credentials are read from the environment, never from a flag, so they stay out
of the process table and the shell history. The push credential follows the W3C
Baggage format, where the space in `Basic <token>` is percent-encoded as `%20`;
`EnvVarHeaders` decodes it. The read credential is HTTP basic auth, where the
username is the Tempo instance id and the password the access policy token. The
token needs the `traces:read` scope; without it Tempo answers every read with
`HTTP 401 {"status":"error","error":"authentication error: invalid scope requested"}`.

Grafana Cloud serves Tempo's API under `/tempo`, so `--tempo-url` carries that
prefix. A Tempo of your own serves it at the root:

```shell
docker run -d -p 3200:3200 -p 4318:4318 grafana/otel-lgtm:0.36.0
Scripts/run-integration-tests.sh --backend grafana \
  --otlp-endpoint http://localhost:4318 --tempo-url http://localhost:3200
```

### Running on a Revyl cloud simulator

`--device revyl` launches on a Revyl cloud iOS simulator instead of a local
one, which requires `--backend grafana`: a cloud device cannot reach a
collector on this machine. Build and start the session first, and stop it
afterwards, because it bills by the minute.

```shell
revyl build --build-profile development --platform ios --remote
revyl device start --platform ios --no-open
revyl device install --app-id <revyl app id> --clean
Scripts/run-integration-tests.sh --backend grafana --device revyl \
  --otlp-endpoint "$OTEL_EXPORTER_OTLP_ENDPOINT" --tempo-url "$TEMPO_URL"
revyl device stop --all
```

The session brings its own app: installing needs a Revyl app or build id, which
belongs to the Revyl project and not to this script, so the runner launches
whatever the session has installed and `revyl device launch` names the fix when
nothing is. `--clean` is the counterpart of the simulator path's
uninstall-then-install, and the launches that read persisted session state need
it.

Revyl delivers `--launch-env` on iOS as `-NAME value` argv pairs, which iOS
registers in `UserDefaults`; `--launch-arg` appends plain argument tokens,
which `IntegrationTestScenario` reads out of `ProcessInfo.arguments` exactly as
it does under `simctl`. A cloud device cannot reach the status server, so this
device runs the `main` launch alone unless `--launches` says otherwise, and
`IntegrationTestScenario.statusBaseURL` falls back to the OTLP endpoint: the
three `/status/<code>` requests go to the push gateway and come back 404, which
costs the scenario nothing but makes `NetworkSpanTests` meaningless there.

### Which assertions each backend runs

Both collector backends run every suite; `remote-collector` is the collector
backend on another machine, so nothing about the assertions changes. The
grafana backend runs the span assertions that the launches it made allow, which
`grafana_assertions` in the runner maps:

| Launches | Assertions |
|---|---|
| `main` | `CustomTelemetryTests`: the root span's attributes, kind and times; the child span's parent and event; one completion marker. And `ResourceAttributesTests/testSpansCarryResourceAttributes`. |
| `max-lifetime` | `SessionConfigTests/testMaxLifetimeRollsTheSessionOverDespiteContinuousActivity` |
| `restore-first` and `restore-second` | `SessionConfigTests/testRestoredSessionKeepsItsIdAcrossLaunches` |
| all four above plus `no-restore` | `SessionConfigTests/testEveryLaunchTagsItsSpans` |

The filter follows the launches because an assertion that reads a launch the
run never made polls Tempo to its timeout and then fails. That is why
`--launches` and the filter cannot be chosen separately.

The rest stay on the collector backend, for reasons worth knowing before adding
to the list:

- Everything that reads logs: `SessionTests`, `CrashTests`,
  `CrashExamplesTests`, `SessionSamplingTests`, the session-event halves of
  `SessionConfigTests`, and `CustomTelemetryTests/testLogRecordIsExported`.
  Tempo holds traces. `TempoSource.logs()` prints that and returns nothing
  rather than pretend otherwise.
- `NetworkSpanTests`, which needs the status server. It passes on the grafana
  backend with a local simulator, and cannot pass on a cloud device, because
  nothing there can reach a status server on this machine. On a cloud Mac it
  passes, because the status server is on that Mac.

Loki and Prometheus attach at the same seam. A `LokiSource` implements
`TelemetrySource.logs()` with a `query_range` over
`{integration_run_id="…", integration_launch="…"}` — Loki labels replace dots
with underscores — and maps Loki's OTLP log entries onto `ExportedLog`; it
would let `OTLPOutput` compose a trace source and a log source instead of using
one source for both. Metrics have no assertions yet, so Prometheus has nothing
to serve.

### What a Tempo round trip changes

Tempo is a store, not an echo. Anything an assertion relies on that Tempo does
not preserve is a flaky test waiting to happen. Measured by replaying one
`main` launch's `traces.pb` into Tempo 3.1.0 over OTLP/HTTP and reading it back
with `TempoSource`: 7 spans sent, 7 returned, none missing, none unexpected, 6
traces either way.

Preserved exactly, over all 7 spans: span id, trace id, parent span id, trace
state, flags, name, kind, start and end times to the nanosecond, status code
and message, every attribute key and value including int, bool, double and
array values, every event with its name, time and attributes, link count, all
three dropped counts, and the instrumentation scope's name, version and
attributes. The resource comes back with the same keys and values.

Changed:

- **Attribute order.** Resource attributes came back in a different order on 7
  of 7 spans, sorted by key; span attributes on 3 of 7. Read attributes by
  key. `ProtoAttributes`' `string(_:)` and `int(_:)` subscripts already do,
  and nothing should index into the array.
- **Export batching.** The collector's file keeps one
  `ExportTraceServiceRequest` per export, so a trace split across two exports
  stays split and a span exported twice appears twice. Tempo returns a trace at
  a time, its spans grouped under the resource and scope they share: the three
  export requests of the `main` launch came back as two `(resource, scope)`
  groups, because the two that shared a scope merged. Count spans, never
  exports or groups.
- **Arrival, not emission.** A span exists in Tempo only after the batch
  processor flushed it, the gateway accepted it and the ingester made it
  searchable, which took a few seconds here. `TempoSource` therefore polls
  until the launch's completion marker has arrived and the span count has
  stopped growing, and the runner waits on the same marker before starting the
  next launch, so no launch reads a partial one. Nothing in either path waits a
  fixed time.

Not preserved by the read path:

- **Anything that is not a trace.** No logs, no metrics.
- **Spans with no root in the search window.** `/api/search` matches traces,
  not spans, so a trace that started before the window is invisible however
  recent its spans are. The runner's window opens a minute before the run. Two
  consequences for anyone writing a replay harness: a trace already in Tempo
  keeps its original start time when more spans arrive for it, so re-sending
  old spans leaves the trace outside a recent window; and spans more than
  `query_backend_after` (15 minutes by default) old are searched for in backend
  blocks, where they are not yet written. A real run sends spans seconds old
  and meets neither.

`.github/workflows/IntegrationTests.yml` runs the same `make` target on
pull requests that touch `Sources/`, the demo app, or these tests, on every
push to `main`, nightly at 00:00 UTC, and on manual dispatch. Pull request runs
are bound to the `integration-tests` environment: add required reviewers to
that environment in the repository settings and every PR run has to be
approved by a maintainer before it starts. Runs on `main`, the nightly and
manual runs use the unprotected `integration-tests-main` environment instead.
The collected telemetry is uploaded as a workflow artifact for debugging.
