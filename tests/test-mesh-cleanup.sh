#!/usr/bin/env bash
# test-mesh-cleanup.sh — test cleanup survives a process that is still exiting.
#
# The TaskMesh tests stop a daemon and delete its directory in an EXIT trap. On
# Windows the dying daemon still held its database, `rm -rf` failed with "Device
# or resource busy", and a test that had passed failed the run. This proves the
# shared helpers wait and retry instead.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/mesh-test-lib.sh
source "$ROOT/tests/mesh-test-lib.sh"

WORK="$(mktemp -d -t taskspec-mesh-cleanup-XXXXXX)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
FAILURES=0

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok   $*"; }

WINDOWS=false
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) WINDOWS=true ;; esac

# A native process that keeps a file open inside the tree for a few seconds,
# as a daemon does between receiving the stop request and exiting.
hold_file() {
  python3 -c 'import sys, time
handle = open(sys.argv[1], "w")
open(sys.argv[2], "w").close()
time.sleep(float(sys.argv[3]))' "$1" "$2" "$3" &
}
wait_for_file() {
  local tries=0
  until [[ -e "$1" ]] || [[ "$tries" -ge 100 ]]; do sleep 0.1; tries=$((tries + 1)); done
  [[ -e "$1" ]]
}

# --- remove_tree retries while the file is held -------------------------------
TREE="$WORK/tree"
mkdir -p "$TREE/state"
hold_file "$TREE/state/mesh.db" "$WORK/holder-ready" 3
HOLDER=$!
wait_for_file "$WORK/holder-ready" || fail "the holder process never started"

if [[ "$WINDOWS" == true ]]; then
  # The defect itself: one plain rm cannot remove a tree a live process holds.
  if rm -rf "$TREE" 2>/dev/null; then
    fail "the scenario was not reproduced: a plain rm removed a tree that is still held"
  else
    ok "a plain rm fails while the process holds the file (the original defect)"
  fi
fi

if remove_tree "$TREE" && [[ ! -e "$TREE" ]]; then
  ok "remove_tree removes the tree once the process lets go"
else
  fail "remove_tree left the tree behind"
fi
wait "$HOLDER" 2>/dev/null || true

# --- wait_for_exit returns only after the process is gone ----------------------
sleep 2 &
SLEEPER=$!
wait_for_exit "$SLEEPER"
if process_gone "$SLEEPER"; then
  ok "wait_for_exit returns after the process has exited"
else
  fail "wait_for_exit returned while the process was still running"
fi
if wait_for_exit "" 999999 && process_gone 999999; then
  ok "an empty or unknown process id is not an error"
else
  fail "wait_for_exit must tolerate an empty or unknown process id"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  echo "MESH_CLEANUP=FAIL ($FAILURES)"
  exit 1
fi
echo "MESH_CLEANUP=READY"
