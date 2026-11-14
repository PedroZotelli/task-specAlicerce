#!/usr/bin/env bash
# Shared cleanup for the TaskMesh tests. Sourced, never run on its own.
#
# Stopping a daemon is asynchronous. On Windows a process that is still exiting
# keeps its log and database open, and `rm -rf` then fails with "Device or
# resource busy". Under `set -e` that failure inside an EXIT trap turned a test
# that had already printed its READY line into a failed run, some of the time.
# So: wait for the process to be gone, then remove the tree, retrying.

# process_gone PID — true once no process has that id.
process_gone() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # The id may be a Git Bash pid or a native Windows pid; check both tables.
      if builtin kill -0 "$1" 2>/dev/null; then return 1; fi
      if tasklist //FI "PID eq $1" //NH 2>/dev/null | grep -q "[[:space:]]$1[[:space:]]"; then return 1; fi
      return 0
      ;;
    *)
      if kill -0 "$1" 2>/dev/null; then return 1; fi
      return 0
      ;;
  esac
}

# wait_for_exit PID... — wait up to about ten seconds for each process to disappear.
wait_for_exit() {
  local pid tries
  for pid in "$@"; do
    [[ -n "$pid" ]] || continue
    tries=0
    until process_gone "$pid" || [[ "$tries" -ge 50 ]]; do
      sleep 0.2
      tries=$((tries + 1))
    done
  done
  return 0
}

# remove_tree PATH — `rm -rf` that retries while a dying process still holds files.
# After about ten seconds the last attempt runs unsilenced, so a real problem
# (a daemon that never stopped) still fails loudly instead of being hidden.
remove_tree() {
  local path="$1" tries=0
  until rm -rf "$path" 2>/dev/null; do
    tries=$((tries + 1))
    if [[ "$tries" -ge 50 ]]; then
      rm -rf "$path"
      return
    fi
    sleep 0.2
  done
  return 0
}
