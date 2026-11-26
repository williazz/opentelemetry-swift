#!/bin/bash
set -euo pipefail

# Integration test runner.
#
# 1. Downloads a pinned OpenTelemetry Collector release (the core `otelcol`
#    distribution, ~30 MB) into Tests/IntegrationTests/.collector, verifying
#    its sha256, and builds the small status server from Tests/IntegrationTests.
# 2. Builds Examples/HackerNewsDemo for the iOS simulator and installs it.
# 3. Launches the app once per session-config case with --integrationTestMode
#    (see IntegrationTestScenario.Launch). For each launch the collector is
#    started with Tests/IntegrationTests/collector.yaml, receiving OTLP/HTTP on
#    $PORT and writing length-prefixed OTLP protobuf to Tests/IntegrationTests/out/<launch>/.
#    The status server on $STATUS_PORT answers the app's GET /status/<code>
#    requests so the URLSession spans have predictable status codes.
# 4. Runs the assertions in Tests/IntegrationTests against the dumped files.
#
# Usage: Scripts/run-integration-tests.sh [--simulator <udid>] [--port <port>]
#                                         [--status-port <port>] [--timeout <seconds>]
#                                         [--build-only | --skip-build] [--crash-examples]
#                                         [--backend collector|remote-collector|grafana]
#                                         [--device simulator|revyl]
#                                         [--launches "<tag> ..."] [--tempo-url <url>]
#                                         [--otlp-endpoint <url>] [--run-id <id>]
#
# --build-only builds the demo app into $DERIVED_DATA and exits; --skip-build
# reuses that build. CI runs them as two steps so the DerivedData can be cached.
#
# --crash-examples replaces the launches above with one crash per demo
# CrashType, each reported on the next launch. Every example lands in
# Tests/IntegrationTests/out/crash-examples/<type>/ with KSCrash's raw JSON
# report and the exported device.crash log, and the CrashExamplesTests
# assertions print a summary table.
#
# --backend grafana replaces steps 1 and 4: the app exports to a hosted OTLP
# endpoint and the assertions read the spans back out of Grafana Tempo instead
# of from files. Each launch is tagged with the `integration.run.id` and
# `integration.launch` resource attributes so the query sees that launch and
# nothing else. Tempo holds traces only, so this backend runs the span
# assertions and leaves the log assertions to the collector; see
# Tests/IntegrationTests/README.md.
#
# --backend remote-collector runs this whole script on a Revyl cloud Mac, which
# has Xcode, the simulator runtimes and the tools it needs. The collector, the
# status server and the simulator all live there, so the assertions read real
# files and the telemetry is what the exporter sent. Every other argument is
# forwarded, so leave off the ones that name something local. See
# Scripts/run-integration-tests-remote.sh.
#
# --device revyl launches on a Revyl cloud simulator instead of a local one,
# which requires --backend grafana because a cloud device cannot reach a
# collector on this machine. Start the session yourself first with
# `revyl device start`, and stop it afterwards with `revyl device stop --all`.
#
# Credentials are read from the environment, never from a flag, so they stay out
# of the process table and the shell history:
#   OTEL_EXPORTER_OTLP_HEADERS  the push credential, e.g. Authorization=Basic%20<token>
#   OTEL_INTEGRATION_TEMPO_AUTH the read credential, <instance id>:<token>

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTEGRATION_DIR="$PROJECT_ROOT/Tests/IntegrationTests"
OUTPUT_DIR="$INTEGRATION_DIR/out"
DERIVED_DATA="${DERIVED_DATA:-$INTEGRATION_DIR/.derivedData}"
APP_PROJECT="$PROJECT_ROOT/Examples/HackerNewsDemo/HackerNewsDemo.xcodeproj"
APP_SCHEME="HackerNewsDemo"
APP_BUNDLE_ID="io.opentelemetry.HackerNewsDemo"
COMPLETION_MARKER="integration.test.complete"
# Followed by `-<activations>`; see IntegrationTestScenario.readySpanName.
READY_MARKER="integration.test.ready"
# The variables a launch the system starts in the background reads from the
# simulator's launchd environment, since it gets no launch arguments.
BACKGROUND_LAUNCH_ENVIRONMENT="OTEL_EXPORTER_OTLP_ENDPOINT INTEGRATION_STATUS_BASE_URL INTEGRATION_LAUNCH"

# Pinned collector release. Bump the version and both checksums together; the
# checksums are the published <asset>.sha256 files from
# https://github.com/open-telemetry/opentelemetry-collector-releases/releases
COLLECTOR_VERSION="0.160.0"
COLLECTOR_SHA256_ARM64="a56143a40a2c205cdd63da4af0249f2534691785c14cdd2a0c532becb4335521"
COLLECTOR_SHA256_AMD64="480fcb29a9fc3f54da661166f7eb40677d4230198123759220255acc5cf35130"
COLLECTOR_CACHE_DIR="${OTEL_INTEGRATION_COLLECTOR_DIR:-$INTEGRATION_DIR/.collector}"

SIMULATOR_UDID=""
PORT=4318
STATUS_PORT=4319
TIMEOUT=120
SKIP_BUILD=false
BUILD_ONLY=false
CRASH_EXAMPLES=false
BACKEND=collector
DEVICE=simulator
LAUNCHES=""
RUN_ID=""
TEMPO_URL="${OTEL_INTEGRATION_TEMPO_URL:-}"
OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
# Keep in sync with CrashType in Examples/HackerNewsDemo/HackerNewsDemo/CrashType.swift.
CRASH_EXAMPLE_TYPES="fatal-error force-unwrap index-out-of-bounds divide-by-zero stack-overflow ns-exception bad-access"

# Every argument but the --backend pair, forwarded as they are when
# --backend remote-collector hands the run to the cloud Mac.
PASSTHROUGH_ARGS=()
while [[ $# -gt 0 ]]; do
  if [[ "$1" != --backend ]]; then
    PASSTHROUGH_ARGS+=("$1")
    case $1 in
      --simulator|--port|--status-port|--timeout|--device|--launches|--run-id|--tempo-url|--otlp-endpoint)
        PASSTHROUGH_ARGS+=("${2:-}") ;;
    esac
  fi
  case $1 in
    --simulator) SIMULATOR_UDID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --status-port) STATUS_PORT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --build-only) BUILD_ONLY=true; shift ;;
    --crash-examples) CRASH_EXAMPLES=true; shift ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --launches) LAUNCHES="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --tempo-url) TEMPO_URL="$2"; shift 2 ;;
    --otlp-endpoint) OTLP_ENDPOINT="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,50p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
done

case "$BACKEND" in
  collector|grafana) ;;
  remote-collector)
    # The collector path, on a Revyl cloud Mac: the collector, the status
    # server and the simulator all live there, so this same script runs there
    # with --backend collector and the assertions read real files. The driver
    # moves the uncommitted worktree and brings the results back.
    exec "$PROJECT_ROOT/Scripts/run-integration-tests-remote.sh" \
      -- ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
    ;;
  *) echo "--backend must be collector, remote-collector or grafana, not $BACKEND" >&2; exit 1 ;;
esac
case "$DEVICE" in
  simulator|revyl) ;;
  *) echo "--device must be simulator or revyl, not $DEVICE" >&2; exit 1 ;;
esac
if [[ "$DEVICE" == revyl && "$BACKEND" != grafana ]]; then
  echo "--device revyl needs --backend grafana: a cloud device cannot reach a collector on this machine" >&2
  exit 1
fi
if [[ "$BACKEND" == grafana && "$CRASH_EXAMPLES" == true ]]; then
  echo "--crash-examples asserts on device.crash log records, which Tempo does not hold; use --backend collector" >&2
  exit 1
fi

if [[ "$BACKEND" == grafana ]]; then
  [[ -n "$OTLP_ENDPOINT" ]] || { echo "--backend grafana needs --otlp-endpoint or OTEL_EXPORTER_OTLP_ENDPOINT" >&2; exit 1; }
  [[ -n "$TEMPO_URL" ]] || { echo "--backend grafana needs --tempo-url or OTEL_INTEGRATION_TEMPO_URL" >&2; exit 1; }
  # Identifies this run in the `integration.run.id` resource attribute, so two
  # runs against the same backend never read each other's spans.
  RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  # Lower bound of every Tempo search. Tempo returns nothing without one, and a
  # minute of slack covers clock skew between this machine and the device.
  RUN_START=$(( $(date +%s) - 60 ))
fi

log() { echo "==> $*"; }

pipe_output() {
  if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi
}

clear_background_launch_environment() {
  local name
  for name in $BACKGROUND_LAUNCH_ENVIRONMENT; do
    xcrun simctl spawn "$SIMULATOR_UDID" launchctl unsetenv "$name" >/dev/null 2>&1 || true
  done
}

COLLECTOR_PID=""
STATUS_PID=""
ASSERTION_OUTPUT=""
cleanup() {
  log "Cleaning up"
  xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  clear_background_launch_environment
  [[ -z "$ASSERTION_OUTPUT" ]] || rm -f "$ASSERTION_OUTPUT"
  if [[ "$DEVICE" == simulator && -n "$SIMULATOR_UDID" ]]; then
    xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  fi
  for pid in "$COLLECTOR_PID" "$STATUS_PID"; do
    if [[ -n "$pid" ]]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

if [[ "$DEVICE" == simulator ]]; then
  if [[ -z "$SIMULATOR_UDID" ]]; then
    SIMULATOR_UDID="$("$PROJECT_ROOT/Scripts/ci/resolve-simulator.sh" iOS)"
  fi
  log "Using simulator $SIMULATOR_UDID"

  if [[ "$SKIP_BUILD" == false ]]; then
    log "Building $APP_SCHEME for the simulator"
    set -o pipefail
    xcodebuild \
      -project "$APP_PROJECT" \
      -scheme "$APP_SCHEME" \
      -configuration Debug \
      -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=NO \
      build | pipe_output
  fi
  APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/$APP_SCHEME.app"
  [[ -d "$APP_PATH" ]] || { echo "App not found at $APP_PATH" >&2; exit 1; }
  if [[ "$BUILD_ONLY" == true ]]; then
    log "Built $APP_PATH"
    exit 0
  fi
else
  # The Revyl session already runs a build of this branch, made in the cloud
  # with `revyl build`, so there is nothing to build or install here.
  [[ "$BUILD_ONLY" == false ]] || { echo "--build-only is for a local simulator; build for Revyl with 'revyl build'" >&2; exit 1; }
  command -v revyl >/dev/null || { echo "revyl is not on PATH; export PATH=\"\$HOME/.revyl/bin:\$PATH\"" >&2; exit 1; }
  revyl device info >/dev/null || { echo "no Revyl device session; start one with 'revyl device start --platform ios --no-open'" >&2; exit 1; }
  log "Using the active Revyl device session"
fi

# Fetches the pinned otelcol release for this machine's architecture into the
# cache dir (idempotent) and prints the binary path.
ensure_collector() {
  local arch sha
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64"; sha="$COLLECTOR_SHA256_ARM64" ;;
    x86_64) arch="amd64"; sha="$COLLECTOR_SHA256_AMD64" ;;
    *) echo "Unsupported architecture $(uname -m)" >&2; exit 1 ;;
  esac
  local dir="$COLLECTOR_CACHE_DIR/$COLLECTOR_VERSION-darwin-$arch"
  local bin="$dir/otelcol"
  if [[ ! -x "$bin" ]]; then
    local asset="otelcol_${COLLECTOR_VERSION}_darwin_${arch}.tar.gz"
    local url="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${COLLECTOR_VERSION}/${asset}"
    log "Downloading OpenTelemetry Collector $COLLECTOR_VERSION ($arch)" >&2
    mkdir -p "$dir"
    curl -fsSL --retry 3 -o "$dir/$asset" "$url"
    if ! echo "$sha  $dir/$asset" | shasum -a 256 -c - >/dev/null; then
      echo "Checksum mismatch for $asset" >&2
      rm -f "$dir/$asset"
      exit 1
    fi
    tar -xzf "$dir/$asset" -C "$dir" otelcol
    rm -f "$dir/$asset"
  fi
  echo "$bin"
}

wait_for_http() {
  local url="$1" expected="$2"
  for _ in $(seq 1 30); do
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" == "$expected" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for $url to return $expected" >&2
  exit 1
}

COLLECTOR_BIN=""
if [[ "$BACKEND" == collector ]]; then
  COLLECTOR_BIN="$(ensure_collector)"
  log "Using $("$COLLECTOR_BIN" --version)"
fi

# The status server answers the app's /status/<code> requests. A Revyl cloud
# device cannot reach it, so the grafana backend on a cloud device runs without
# it and the network span assertions stay on the collector backend.
STATUS_BASE_URL=""
if [[ "$DEVICE" == simulator ]]; then
  log "Building IntegrationStatusServer"
  # Originally contributed by Cody Mitchell (@SproutSeeds)
  swift build --package-path "$INTEGRATION_DIR" --product IntegrationStatusServer 2>&1 | sed '/warning:/d'
  STATUS_BIN="$(swift build --package-path "$INTEGRATION_DIR" --product IntegrationStatusServer --show-bin-path)/IntegrationStatusServer"
  "$STATUS_BIN" --port "$STATUS_PORT" &
  STATUS_PID=$!
  wait_for_http "http://localhost:$STATUS_PORT/health" 200
  STATUS_BASE_URL="http://localhost:$STATUS_PORT"
fi

# Each app launch gets its own output directory, so the collector is restarted
# per launch pointing at that directory.
start_collector() {
  local dir="$1"
  mkdir -p "$dir"
  OTEL_INTEGRATION_OUTPUT_DIR="$dir" OTEL_INTEGRATION_PORT="$PORT" \
    "$COLLECTOR_BIN" --config "$INTEGRATION_DIR/collector.yaml" >"$dir/collector.log" 2>&1 &
  COLLECTOR_PID=$!
  # The OTLP receiver answers GET on its POST-only route with 405 once it is up.
  wait_for_http "http://localhost:$PORT/v1/traces" 405
}

stop_collector() {
  if [[ -n "$COLLECTOR_PID" ]]; then
    kill "$COLLECTOR_PID" >/dev/null 2>&1 || true
    wait "$COLLECTOR_PID" 2>/dev/null || true
    COLLECTOR_PID=""
  fi
}

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

if [[ "$DEVICE" == simulator ]]; then
  log "Booting simulator"
  xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$SIMULATOR_UDID" -b

log "Installing $APP_BUNDLE_ID"
# A previous run that was killed rather than exiting can have left these set, which would put
# every launch below into the wrong scenario, so the state the simulator starts in is cleared.
clear_background_launch_environment
xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
  log "Installing $APP_BUNDLE_ID"
  xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
else
  # Installing needs a Revyl app or build id, which belongs to the Revyl
  # project rather than to this script, so the session brings its own app:
  #   revyl device install --app-id <id> --clean
  # --clean is the counterpart of the simulator's uninstall-then-install, and
  # the launches that read persisted session state need it.
  log "Using the app the Revyl session has installed"
fi

# tempo_search <TraceQL> -> the search response body on stdout, or exits non-zero.
# The read credential is <instance id>:<token> in OTEL_INTEGRATION_TEMPO_AUTH,
# left empty for a Tempo that needs none. Keep the query in step with
# TempoSource.query in Tests/IntegrationTests/Assertions/TelemetrySource.swift:
# this one is only the gate that says the launch has landed, the assertions do
# the reading.
tempo_search() {
  local query="$1"
  local auth=()
  [[ -z "${OTEL_INTEGRATION_TEMPO_AUTH:-}" ]] || auth=(-u "$OTEL_INTEGRATION_TEMPO_AUTH")
  # bash 3.2, which macOS ships, treats "${auth[@]}" on an empty array as an
  # unbound variable under `set -u`.
  curl -fsS -G "$TEMPO_URL/api/search" ${auth[@]+"${auth[@]}"} \
    --data-urlencode "q=$query" \
    --data-urlencode "start=$RUN_START" \
    --data-urlencode "end=$(( $(date +%s) + 60 ))" \
    --data-urlencode "limit=1"
}

# The resource attributes that tell this launch's spans apart from every other
# launch's in a shared backend. Passed as OTEL_RESOURCE_ATTRIBUTES, which
# TelemetryConfig reads from the environment on a local simulator and from
# UserDefaults on a cloud one. The collector backend needs none: each launch
# already has a directory of its own, and adding them would change what the
# default path exports.
# launch_selected <slot>
# True when this run makes the launch. --launches names the slots to keep, and
# an empty value keeps every one. Selecting here rather than at the call sites
# keeps the launch list append-only for the branches that add to it.
launch_selected() {
  [[ -z "$LAUNCHES" ]] || [[ " $LAUNCHES " == *" $1 "* ]]
}

launch_resource_attributes() {
  [[ "$BACKEND" == grafana ]] || return 0
  echo "integration.run.id=$RUN_ID,integration.launch=$1"
}

# run_launch <tag> [extra launch arguments...]
# Launches the app once with --integrationLaunch <tag>, into the slot named
# after the tag. The app stays installed between launches so persisted session
# state carries over, which the restore launches depend on.
run_launch() {
  run_launch_into "$1" "$@"
}

# run_launch_into <slot> <tag> [extra launch arguments...]
# Like run_launch, but names the slot the launch is read back from: a
# subdirectory of $OUTPUT_DIR for the collector backend, the
# `integration.launch` resource attribute for the grafana backend. The
# assertions select it with OTLPOutput.launch or OTLPOutput.subdirectory.
run_launch_into() {
  local slot="$1"; shift
  local tag="$1"; shift
  start_collector "$dir"
  log "Launch '$tag' ($*)"
  case "$tag" in
    app-start-resume)
      launch_app "$tag" "$@"
      wait_for_marker "$dir" "$READY_MARKER-1"
      move_to_background_and_back 3 "$tag" "$@"
      ;;
    app-start-late-install)
      launch_app "$tag" "$@"
      wait_for_marker "$dir" "$READY_MARKER-1"
      move_to_background_and_back 3 "$tag" "$@"
      # The second activation blocks the main thread, so the app is moved to the
      # background before its first frame. Wait for the block to end before
      # bringing it back.
      wait_for_marker "$dir" "$READY_MARKER-2"
      move_to_background_and_back 6 "$tag" "$@"
      ;;
    app-start-background)
      launch_app_in_background "$tag"
      wait_for_marker "$dir" "$READY_MARKER-0"
      clear_background_launch_environment
      sleep 2
      log "Bringing '$tag' to the foreground"
      launch_app "$tag" "$@"
      ;;
    *)
      launch_app "$tag" "$@"
      ;;
  esac

  wait_for_marker "$dir" "$COMPLETION_MARKER"
  # Logs are batched on a fixed 5s schedule; give the last batch time to land.
  sleep 6
  xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  stop_collector
}

# launch_app <tag> [extra launch arguments...]
launch_app() {
  local tag="$1"; shift
  SIMCTL_CHILD_OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:$PORT" \
  SIMCTL_CHILD_INTEGRATION_STATUS_BASE_URL="http://localhost:$STATUS_PORT" \
    xcrun simctl launch "$SIMULATOR_UDID" "$APP_BUNDLE_ID" --integrationTestMode --integrationLaunch "$tag" "$@"
}

# launch_app_in_background <tag>
# Has the system launch the app in the background, as for a background fetch,
# by sending it a silent push.
launch_app_in_background() {
  local tag="$1"
  local payload="$OUTPUT_DIR/silent-push.json"
  # These are set in the simulator's own launchd environment, so every app launched there reads
  # them, and `trap cleanup EXIT` doesn't run if this script is killed. Clearing them first makes a
  # run after one that was killed self-healing rather than leaving the simulator in test mode.
  clear_background_launch_environment
  xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv OTEL_EXPORTER_OTLP_ENDPOINT "http://localhost:$PORT"
  xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv INTEGRATION_STATUS_BASE_URL "http://localhost:$STATUS_PORT"
  xcrun simctl spawn "$SIMULATOR_UDID" launchctl setenv INTEGRATION_LAUNCH "$tag"
  echo '{"aps":{"content-available":1}}' >"$payload"
  xcrun simctl push "$SIMULATOR_UDID" "$APP_BUNDLE_ID" "$payload" >/dev/null
  rm -f "$payload"
}

# move_to_background_and_back <seconds in the background> <tag> [extra launch arguments...]
# Opens Settings, then brings the app back. `simctl launch` of a running app
# brings it to the foreground without starting a new process.
move_to_background_and_back() {
  local seconds="$1"; shift
  log "Moving '$1' to the background and back"
  xcrun simctl launch "$SIMULATOR_UDID" com.apple.Preferences >/dev/null
  sleep "$seconds"
  launch_app "$@"
}

# wait_for_marker <output directory> <span name>
wait_for_marker() {
  local dir="$1" marker="$2"
  local deadline=$((SECONDS + TIMEOUT))
  until grep -aqs "$marker" "$dir/traces.pb"; do
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for '$marker' in $dir/traces.pb" >&2
      ls -la "$dir" >&2 || true
      cat "$dir/collector.log" >&2 || true
  if ! launch_selected "$slot"; then
    log "Skipping launch '$slot'"
    return 0
  fi
  local dir="$OUTPUT_DIR/$slot"
  local endpoint="$OTLP_ENDPOINT"

  if [[ "$BACKEND" == collector ]]; then
    start_collector "$dir"
    endpoint="http://localhost:$PORT"
  fi

  log "Launch '$tag' ($*)"
  launch_app "$slot" "$tag" "$endpoint" "$@"
  wait_for_launch "$slot" "$dir"
  # Logs are batched on a fixed 5s schedule; give the last batch time to land.
  sleep 6
  terminate_app

  if [[ "$BACKEND" == collector ]]; then
    stop_collector
  fi
}

# launch_app <slot> <tag> <endpoint> [extra launch arguments...]
launch_app() {
  local slot="$1" tag="$2" endpoint="$3"; shift 3
  local attributes
  attributes="$(launch_resource_attributes "$slot")"

  if [[ "$DEVICE" == simulator ]]; then
    SIMCTL_CHILD_OTEL_EXPORTER_OTLP_ENDPOINT="$endpoint" \
    SIMCTL_CHILD_OTEL_EXPORTER_OTLP_HEADERS="${OTEL_EXPORTER_OTLP_HEADERS:-}" \
    SIMCTL_CHILD_OTEL_RESOURCE_ATTRIBUTES="$attributes" \
    SIMCTL_CHILD_INTEGRATION_STATUS_BASE_URL="$STATUS_BASE_URL" \
      xcrun simctl launch "$SIMULATOR_UDID" "$APP_BUNDLE_ID" --integrationTestMode --integrationLaunch "$tag" "$@"
    return
  fi

  # Revyl delivers --launch-env on iOS as `-NAME value` argv pairs, which iOS
  # registers in UserDefaults; TelemetryConfig.setting reads them from there.
  # --launch-arg appends plain argument tokens, which the scenario reads out of
  # ProcessInfo.arguments as it does on a local simulator.
  local args=(--launch-arg=--integrationTestMode --launch-arg=--integrationLaunch "--launch-arg=$tag")
  local extra
  for extra in "$@"; do
    args+=("--launch-arg=$extra")
  done
  revyl device launch \
    --launch-env "OTEL_EXPORTER_OTLP_ENDPOINT=$endpoint" \
    --launch-env "OTEL_EXPORTER_OTLP_HEADERS=${OTEL_EXPORTER_OTLP_HEADERS:-}" \
    --launch-env "OTEL_RESOURCE_ATTRIBUTES=$attributes" \
    "${args[@]}"
}

terminate_app() {
  if [[ "$DEVICE" == simulator ]]; then
    xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
  else
    revyl device kill-app >/dev/null 2>&1 || true
  fi
}

# wait_for_launch <slot> <output directory>
# Blocks until the launch's completion marker has reached the backend, so the
# next launch cannot overlap this one and the assertions never read a partial
# launch. A remote backend is eventually consistent, so this polls the backend
# itself rather than waiting a fixed time.
wait_for_launch() {
  local slot="$1" dir="$2"
  local deadline=$((SECONDS + TIMEOUT))
  local query
  query="{resource.integration.run.id=\"$RUN_ID\" && resource.integration.launch=\"$slot\" && name=\"$COMPLETION_MARKER\"}"

  while true; do
    if [[ "$BACKEND" == collector ]]; then
      if grep -aqs "$COMPLETION_MARKER" "$dir/traces.pb"; then return 0; fi
    else
      if [[ "$(tempo_search "$query" 2>/dev/null | jq -r '.traces | length' 2>/dev/null || echo 0)" != "0" ]]; then return 0; fi
    fi
    if (( SECONDS >= deadline )); then
      if [[ "$BACKEND" == collector ]]; then
        echo "Timed out waiting for '$COMPLETION_MARKER' in $dir/traces.pb" >&2
        ls -la "$dir" >&2 || true
        cat "$dir/collector.log" >&2 || true
      else
        echo "Timed out after ${TIMEOUT}s waiting for '$COMPLETION_MARKER' in Tempo" >&2
        echo "  query: $query" >&2
        echo "  last response: $(tempo_search "$query" 2>&1 | head -c 400)" >&2
      fi
      exit 1
    fi
    sleep 1
  done
}

# install_new_build
# Reinstalls the app with its build number bumped, as an app update does. The
# app's data container is kept, so its previous launch is still recorded.
install_new_build() {
  local copy
  copy="$(mktemp -d)/$APP_SCHEME.app"
  cp -R "$APP_PATH" "$copy"
  local build
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$copy/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" "$copy/Info.plist"
  log "Installing $APP_BUNDLE_ID build $((build + 1))"
  xcrun simctl install "$SIMULATOR_UDID" "$copy"
  rm -rf "$(dirname "$copy")"
}

# save_crash_reports <output subdirectory>
# Copies the raw JSON reports KSCrash stored in the app's container into
# $OUTPUT_DIR/<output subdirectory>/kscrash/, before the next launch reports
# and deletes them.
save_crash_reports() {
  launch_selected "$1" || return 0
  [[ "$DEVICE" == simulator ]] || return 0
  local dir="$OUTPUT_DIR/$1/kscrash"
  local container
  container="$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_BUNDLE_ID" data)"
  mkdir -p "$dir"
  find "$container/Library/Caches/KSCrash" -path '*/Reports/*.json' -exec cp {} "$dir/" \; 2>/dev/null || true
}

# grafana_assertions <launch tag> ...
# Prints the span assertions the given launches make possible, one per line.
# Tempo holds traces, so the grafana backend runs no log assertion: those, and
# with them the crash and session-event suites, stay on the collector backend
# until a Loki source exists; see Tests/IntegrationTests/README.md. The filter
# follows the launches because an assertion that reads a launch the run skipped
# polls Tempo to its timeout and then fails.
grafana_assertions() {
  local launches=" $* "
  local assertions=()
  if [[ "$launches" == *" main "* ]]; then
    assertions+=(
      CustomTelemetryTests/testRootSpanIsExportedWithAttributes
      CustomTelemetryTests/testChildSpanIsLinkedToRoot
      CustomTelemetryTests/testCompletionMarkerIsExportedOnce
      ResourceAttributesTests/testSpansCarryResourceAttributes
    )
  fi
  if [[ "$launches" == *" max-lifetime "* ]]; then
    assertions+=(SessionConfigTests/testMaxLifetimeRollsTheSessionOverDespiteContinuousActivity)
  fi
  if [[ "$launches" == *" restore-first "* && "$launches" == *" restore-second "* ]]; then
    assertions+=(SessionConfigTests/testRestoredSessionKeepsItsIdAcrossLaunches)
  fi
  # Checks one completion marker per launch, over every launch but main.
  if [[ "$launches" == *" max-lifetime "* && "$launches" == *" restore-first "* \
     && "$launches" == *" restore-second "* && "$launches" == *" no-restore "* ]]; then
    assertions+=(SessionConfigTests/testEveryLaunchTagsItsSpans)
  fi
  printf '%s\n' ${assertions[@]+"${assertions[@]}"}
}

# The launches the grafana backend makes by default: the ones whose assertions
# read spans only. A cloud device also cannot reach the status server, so it
# takes the one launch that needs nothing local.
if [[ "$BACKEND" == grafana && -z "$LAUNCHES" ]]; then
  if [[ "$DEVICE" == revyl ]]; then
    LAUNCHES="main"
  else
    LAUNCHES="main max-lifetime restore-first restore-second no-restore"
  fi
fi
[[ "$BACKEND" == collector ]] || log "Run id $RUN_ID, launches: ${LAUNCHES:-all}"

ASSERTION_FILTER=()
if [[ "$CRASH_EXAMPLES" == true ]]; then
  # One crash per type, each reported by the following launch in a new session.
  for type in $CRASH_EXAMPLE_TYPES; do
    run_launch_into "crash-examples/$type" crash --crashType "$type" --sessionTimeout 3600 --restorePersistedSession false
    save_crash_reports "crash-examples/$type"
    run_launch_into "crash-examples/$type/report" crash-report --sessionTimeout 3600 --restorePersistedSession false
  done
  ASSERTION_FILTER=(--filter CrashExamplesTests)
else
  # Keep the tags and session configs in sync with IntegrationTestScenario.Launch
  # and Tests/IntegrationTests/Assertions/SessionConfigTests.swift.
  run_launch main
  run_launch max-lifetime --sessionTimeout 60 --maxLifetime 3
  run_launch restore-first --sessionTimeout 3600 --restorePersistedSession true
  run_launch restore-second --sessionTimeout 3600 --restorePersistedSession true
  run_launch no-restore --sessionTimeout 3600 --restorePersistedSession false
  # Each in a fresh session, so the crash report is emitted in a different session
  # from the one that crashed.
  run_launch crash --sessionTimeout 3600 --restorePersistedSession false
  save_crash_reports crash
  run_launch crash-report --sessionTimeout 3600 --restorePersistedSession false
  # A second crash, reported with on-device symbol names instead of the default style.
  run_launch_into symbolicated/crash crash --sessionTimeout 3600 --restorePersistedSession false
  run_launch_into symbolicated/crash-report crash-report --sessionTimeout 3600 --restorePersistedSession false --reportStyle symbolicated
  run_launch log-limits --sessionTimeout 3600 --restorePersistedSession false
  # Same 200/404/500 requests as `main`, with stable HTTP semantic conventions.
  # Last so the persisted-session and crash launches keep their order, and
  # before the AppStart launches below, which reinstall the app.
  run_launch main-stable --sessionTimeout 2 --restorePersistedSession false --httpSemanticConvention stable
  # AppStart: a warm launch followed by a resume, a late installation with an
  # interrupted activation, a background launch, and the cold first launch after
  # an update. `main` above is the cold first launch after installation.
  # Prewarming isn't covered: setting ActivePrewarm makes the system hold the
  # process before main() until a real launch resumes it, which never comes.
  run_launch app-start-resume
  run_launch app-start-late-install
  run_launch app-start-background
  # Xcode inserts libraries ahead of the app in dyld's image list, so this launch has one too.
  SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(xcrun simctl getenv "$SIMULATOR_UDID" IPHONE_SIMULATOR_ROOT)/usr/lib/libLogRedirect.dylib" \
    run_launch app-start-mincore
  install_new_build
  run_launch app-start-update
  # Copies the same original build, so this reinstalls the build just launched.
  install_new_build
  run_launch app-start-reinstall
  # The app keeps the user ID in UserDefaults, so these run last and in order.
  run_launch user-id-set --sessionTimeout 3600 --userId integration-user-1
  run_launch user-id-restored --sessionTimeout 3600
  run_launch user-id-cleared --sessionTimeout 3600 --clearUserId
  run_launch hang --sessionTimeout 3600 --restorePersistedSession false
fi

if [[ "$BACKEND" == grafana ]]; then
  while read -r assertion; do
    if [[ -n "$assertion" ]]; then
      ASSERTION_FILTER+=(--filter "$assertion")
    fi
    # shellcheck disable=SC2086
  done <<< "$(grafana_assertions ${LAUNCHES:-})"
  [[ ${#ASSERTION_FILTER[@]} -gt 0 ]] || { echo "No span assertion covers launches '$LAUNCHES'" >&2; exit 1; }
  log "Assertions: $(( ${#ASSERTION_FILTER[@]} / 2 ))"
fi

if [[ "$BACKEND" == collector ]]; then
  log "Collected files"
  find "$OUTPUT_DIR" -type f | sort
fi

log "Running assertions"
# Kept so the run can prove the assertions ran. A `swift test` whose XCTest
# bundle fails to load, which is what an x86_64 shell on an arm64 Mac does,
# prints the reason, runs nothing and exits 0; without this check the run
# reports success having asserted nothing.
ASSERTION_OUTPUT="$(mktemp -t integration-assertions)"
# Originally contributed by Cody Mitchell (@SproutSeeds)
OTEL_INTEGRATION_OUTPUT_DIR="$OUTPUT_DIR" \
OTEL_INTEGRATION_BACKEND="$BACKEND" \
OTEL_INTEGRATION_TEMPO_URL="$TEMPO_URL" \
OTEL_INTEGRATION_TEMPO_AUTH="${OTEL_INTEGRATION_TEMPO_AUTH:-}" \
OTEL_INTEGRATION_RUN_ID="$RUN_ID" \
OTEL_INTEGRATION_RUN_START="${RUN_START:-}" \
  swift test --package-path "$INTEGRATION_DIR" ${ASSERTION_FILTER[@]+"${ASSERTION_FILTER[@]}"} 2>&1 \
  | sed '/warning:/d' | tee "$ASSERTION_OUTPUT"

if ! grep -qE 'Executed [1-9][0-9]* test' "$ASSERTION_OUTPUT"; then
  echo "No assertion ran; see the output above. On an arm64 Mac, run this script under 'arch -arm64'." >&2
  exit 1
fi

log "Integration tests passed"
