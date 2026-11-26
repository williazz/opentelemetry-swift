#!/bin/bash
set -euo pipefail

# Runs Scripts/run-integration-tests.sh on a Revyl cloud Mac, which is what
# `run-integration-tests.sh --backend remote-collector` dispatches to.
#
# The cloud Mac has Xcode, iOS simulator runtimes, git, curl and jq, so the
# whole local path runs there unchanged: the collector, the status server and
# the simulator all sit on one machine, the assertions read real
# length-prefixed OTLP protobuf, and nothing depends on a hosted backend's
# ingestion, ordering or read scope. One Mac per branch gives remote runs that
# can go in parallel.
#
# The worktree is never committed, so the tree moves as a clone of this
# repository's `origin` at HEAD plus a patch of everything uncommitted:
# `git diff HEAD` for tracked changes and a `new file` patch per untracked file.
# The patch is checked with `git apply --check` before it is applied, and this
# script stops on the first failure, because a half-applied patch would produce
# a green run that proves nothing.
#
# Usage: Scripts/run-integration-tests-remote.sh [--computer <id>] [--keep-computer]
#                                                [--remote-dir <name>] [--exec-timeout <duration>]
#                                                [--no-fetch-output]
#                                                [-- <run-integration-tests.sh arguments>]
#
# --computer, or OTEL_INTEGRATION_COMPUTER, reuses a running computer instead of
# creating one, and implies --keep-computer. Without it this script creates a Mac and stops it on the way
# out, because concurrency is limited. Arguments after `--` go to the runner on
# the Mac; it is already given --backend collector.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="otel-integration"
EXEC_TIMEOUT="60m"
# OTEL_INTEGRATION_COMPUTER reuses a computer when the run comes through
# `run-integration-tests.sh --backend remote-collector`, which forwards no flag
# of this script's own.
COMPUTER="${OTEL_INTEGRATION_COMPUTER:-}"
KEEP_COMPUTER=false
[[ -z "$COMPUTER" ]] || KEEP_COMPUTER=true
FETCH_OUTPUT=true
RUNNER_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --computer) COMPUTER="$2"; KEEP_COMPUTER=true; shift 2 ;;
    --keep-computer) KEEP_COMPUTER=true; shift ;;
    --remote-dir) WORKSPACE_DIR="$2"; shift 2 ;;
    --exec-timeout) EXEC_TIMEOUT="$2"; shift 2 ;;
    --no-fetch-output) FETCH_OUTPUT=false; shift ;;
    --) shift; RUNNER_ARGS=("$@"); break ;;
    -h|--help)
      sed -n '3,29p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option $1" >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }

command -v revyl >/dev/null || { echo "revyl is not on PATH; export PATH=\"\$HOME/.revyl/bin:\$PATH\"" >&2; exit 1; }
cd "$PROJECT_ROOT"
git rev-parse --git-dir >/dev/null

BASE_COMMIT="$(git rev-parse HEAD)"
ORIGIN_URL="$(git remote get-url origin)"
case "$ORIGIN_URL" in
  https://*) ;;
  *) echo "origin is $ORIGIN_URL; the cloud Mac has no credentials, so origin must be an https URL" >&2; exit 1 ;;
esac
log "Base commit $BASE_COMMIT from $ORIGIN_URL"

PATCH_FILE="$(mktemp -t integration-worktree)"
OUTPUT_ARCHIVE="$(mktemp -t integration-out)"
CHUNK_DIR="$(mktemp -d -t integration-patch)"
cleanup() {
  rm -rf "$PATCH_FILE" "$OUTPUT_ARCHIVE" "$CHUNK_DIR"
  if [[ -n "$COMPUTER" && "$KEEP_COMPUTER" == false ]]; then
    log "Stopping computer $COMPUTER"
    revyl computer stop "$COMPUTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Everything uncommitted, as one patch: tracked changes, then each untracked
# file as a `new file` hunk. --no-index keeps the index untouched, so the
# worktree this runs in is not modified in any way.
{
  git diff HEAD
  while read -r file; do
    [[ -n "$file" ]] || continue
    git diff --no-index --binary /dev/null "$file" || true
  done <<< "$(git ls-files --others --exclude-standard)"
} > "$PATCH_FILE"
log "Uncommitted changes: $(wc -c < "$PATCH_FILE" | tr -d ' ') bytes of patch"

if [[ -z "$COMPUTER" ]]; then
  log "Creating a macOS computer"
  COMPUTER="$(revyl computer create --os macos --session-profile none --timeout 2h \
    --wait --wait-timeout 8m 2>&1 | sed -n 's/^computer_session_id=\([0-9a-f-]*\).*/\1/p' | head -1)"
  [[ -n "$COMPUTER" ]] || { echo "could not create a computer" >&2; exit 1; }
fi
log "Using computer $COMPUTER"

# on_computer <shell script>
# Runs one shell script on the Mac. `revyl computer exec` passes the remote
# exit code through, so `set -e` here stops on the first remote failure.
on_computer() {
  revyl computer exec "$COMPUTER" --timeout "$EXEC_TIMEOUT" -- /bin/bash -lc "$1"
}

log "Cloning $BASE_COMMIT"
on_computer "
  set -euo pipefail
  rm -rf '$WORKSPACE_DIR'
  git clone --filter=blob:none --no-checkout '$ORIGIN_URL' '$WORKSPACE_DIR'
  cd '$WORKSPACE_DIR'
  git checkout --detach '$BASE_COMMIT'
  git rev-parse HEAD
"

# A file write takes at most 65536 bytes, and this patch outgrew that, so it
# goes up in pieces and is joined on the Mac. `split`'s default suffixes sort
# in the order it wrote them, which is the order `cat` needs.
log "Uploading the worktree patch"
split -b 49152 "$PATCH_FILE" "$CHUNK_DIR/part-"
for part in "$CHUNK_DIR"/part-*; do
  revyl computer files write "$COMPUTER" "worktree.patch.$(basename "$part")" --from "$part" >/dev/null
done
log "Joining $(ls -1 "$CHUNK_DIR" | wc -l | tr -d ' ') pieces"
on_computer "
  set -euo pipefail
  cat worktree.patch.part-* > worktree.patch
  rm -f worktree.patch.part-*
"

log "Applying the worktree patch"
on_computer "
  set -euo pipefail
  cd '$WORKSPACE_DIR'
  # Compare byte counts first: a truncated upload would otherwise apply as far
  # as it parsed and leave the tree silently short of the local one.
  test \"\$(wc -c < ../worktree.patch | tr -d ' ')\" = '$(wc -c < "$PATCH_FILE" | tr -d ' ')'
  git apply --check ../worktree.patch
  git apply ../worktree.patch
  git status --short
"

log "Running the integration tests on $COMPUTER"
REMOTE_STATUS=0
on_computer "
  set -uo pipefail
  cd '$WORKSPACE_DIR'
  Scripts/run-integration-tests.sh --backend collector ${RUNNER_ARGS[*]+${RUNNER_ARGS[*]}}
" || REMOTE_STATUS=$?

if [[ "$FETCH_OUTPUT" == true ]]; then
  # The assertions already ran on the Mac; this copy is for reading a failure
  # here, or for re-running the assertions locally against the same files.
  log "Fetching the collected telemetry"
  # The archive has to sit under the workspace, because a file read takes a
  # guest-relative path and refuses anything outside it.
  if on_computer "
    set -euo pipefail
    cd '$WORKSPACE_DIR/Tests/IntegrationTests'
    tar -czf ../../integration-out.tgz out
    size=\$(wc -c < ../../integration-out.tgz | tr -d ' ')
    echo \"archive \$size bytes\"
    test \"\$size\" -le 1048576
  "; then
    revyl computer files read "$COMPUTER" "$WORKSPACE_DIR/integration-out.tgz" > "$OUTPUT_ARCHIVE"
    DESTINATION="$PROJECT_ROOT/Tests/IntegrationTests/out-remote"
    rm -rf "$DESTINATION"
    mkdir -p "$DESTINATION"
    tar -xzf "$OUTPUT_ARCHIVE" -C "$DESTINATION" --strip-components 1
    log "Collected telemetry in $DESTINATION"
  else
    log "Skipped: the archive is larger than the 1 MiB a file read returns"
  fi
fi

if (( REMOTE_STATUS != 0 )); then
  echo "The run failed on $COMPUTER with exit code $REMOTE_STATUS; its output is above" >&2
  exit "$REMOTE_STATUS"
fi

log "Remote integration tests passed on $COMPUTER"
