#!/usr/bin/env bash
# test-state-relative-paths.sh — _state.yaml never embeds an absolute path.
#
# A committed index that records `path: /home/<user>/...` leaks the developer's
# home directory and breaks on every other checkout. Git reports the physical
# repository root, so a backlog reached through a symlink (macOS /tmp, a linked
# checkout) or a Windows junction used to fall back to the absolute path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/T-20260603-stamp-then-verify.md"
WORK="$(mktemp -d -t taskspec-state-paths-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok   $*"; }

# A directory link any user can create: a junction on Windows, a symlink elsewhere.
make_dir_link() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cmd //c mklink //J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null ;;
    *) ln -s "$1" "$2" ;;
  esac
}

REAL="$WORK/real"
mkdir -p "$REAL/cvg/tasks"
git -C "$REAL" init -q
git -C "$REAL" config user.email state@example.invalid
git -C "$REAL" config user.name state
printf '# readme\n' > "$REAL/README.md"
git -C "$REAL" add README.md
git -C "$REAL" commit -qm baseline
cp "$FIXTURE" "$REAL/cvg/tasks/"
make_dir_link "$REAL" "$WORK/linked"

expected="path: cvg/tasks/T-20260603-stamp-then-verify.md"
for entry in "$REAL" "$WORK/linked"; do
  for backlog in "$entry/cvg/tasks" "cvg/tasks"; do
    (cd "$entry" && TASKSPEC_BACKLOG_DIR="$backlog" bash "$ROOT/src/backlog/rebuild-state.sh" >/dev/null)
    recorded="$(grep -m1 'path:' "$REAL/cvg/tasks/_state.yaml" | sed 's/^ *//')"
    label="${entry#"$WORK"/} with backlog ${backlog#"$WORK"/}"
    if [[ "$recorded" == "$expected" ]]; then
      ok "$label records a repository-relative path"
    else
      fail "$label recorded '$recorded'"
    fi
  done
done

if [[ "$FAILURES" -ne 0 ]]; then
  echo "STATE_PATHS=FAIL ($FAILURES)"
  exit 1
fi
echo "STATE_PATHS=RELATIVE"
