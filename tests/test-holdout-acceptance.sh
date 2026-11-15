#!/usr/bin/env bash
# test-holdout-acceptance.sh — what acceptance checks about a holdout receipt.
#
# The policy of a v4 task pins the holdout by `descriptor_digest`,
# `authorization_ref`, or both. This suite fixes what acceptance does with them:
#   - a pinned descriptor_digest refuses a receipt for any other descriptor;
#   - a policy that pins nothing is refused (it used to accept any passing
#     receipt when acceptance ran without the PRE-gate);
#   - KNOWN GAP, reported and not failed: with `authorization_ref` alone a v2
#     receipt is not tied to a bundle, because EvaluationReceipt/v2 carries no
#     bundle reference. An executor's own always-passing bundle, run against the
#     real handoff, is accepted. Closing it needs a receipt-format change.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="$ROOT/bin/taskspec"
FIXTURE="$ROOT/tests/fixtures/T-20260603-stamp-then-verify.md"
WORK="$(mktemp -d -t taskspec-holdout-accept-XXXXXX)"
ART="$(mktemp -d -t taskspec-holdout-accept-artifacts-XXXXXX)"
trap 'rm -rf "$WORK" "$ART"' EXIT
FAILURES=0
KNOWN_GAPS=0
PINNED="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok   $*"; }
gap()  {
  KNOWN_GAPS=$((KNOWN_GAPS + 1))
  echo "  KNOWN GAP — $*"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=Known gap (test-holdout-acceptance)::$*"
  fi
}

repo() {
  mkdir -p "$1/tasks"
  git -C "$1" init -q
  git -C "$1" config user.email holdout@example.invalid
  git -C "$1" config user.name holdout
  printf '# readme\n' > "$1/README.md"
  git -C "$1" add README.md 2>/dev/null
  git -C "$1" commit -qm baseline
}

# spec <repo> <task id> <holdout policy lines, already indented>
spec() {
  python3 - "$FIXTURE" "$1/tasks/$2.md" "$2" "$3" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
text = text.replace("T-20260603-stamp-then-verify", sys.argv[3])
text = text.replace("format_version: 2", "format_version: 4\nprofile: lite")
text = text.replace('(none — see references/concepts/signed-off.md "The three tiers")', "(none)")
policy = (
    "evaluation_policy:\n  acceptance_scope: local\n  deterministic:\n    required: true\n"
    "  holdout:\n    required: true\n" + sys.argv[4].replace("\\n", "\n") +
    "environment_contract:\n  required: false\n"
)
text = text.replace("\n---\n", "\n" + policy + "---\n", 1)
pathlib.Path(sys.argv[2]).write_text(text, encoding="utf-8", newline="\n")
PY
}
gate()    { (cd "$1" && TASKSPEC_SIGNING_KEY=holdout-key TASKSPEC_BACKLOG_DIR=tasks bash "$TS" gate --stamp "tasks/$2.md" >/dev/null); }
handoff() { (cd "$1" && TASKSPEC_SIGNING_KEY=holdout-key TASKSPEC_BACKLOG_DIR=tasks bash "$TS" handoff "tasks/$2.md" --backend codex --attempt-id "$3" --out "$4" >/dev/null); }
accept()  { env TASKSPEC_SIGNING_KEY=holdout-key TASKSPEC_BACKLOG_DIR="$1/tasks" bash "$TS" accept --handoff "$3" --holdout-receipt "$4" "$1/tasks/$2.md"; }

# The executor's own bundle: one check that always passes, described without a key.
forge() { # forge <task id> <handoff> <receipt out>
  local dir="$ART/forge-$1"
  mkdir -p "$dir/ws"
  printf '{"contract":"HoldoutBundle/v1","task_id":"%s","checks":[{"id":"holdout_forged","argv":["bash","-c","exit 0"],"verifies":["B-1"]}]}\n' "$1" > "$dir/bundle.json"
  env -u TASKSPEC_HOLDOUT_KEY bash "$TS" holdout seal "$dir/bundle.json" --out "$dir/descriptor.json" >/dev/null
  env -u TASKSPEC_HOLDOUT_KEY bash "$TS" holdout run "$dir/descriptor.json" "$dir/bundle.json" \
    --workspace "$dir/ws" --handoff "$2" --receipt-out "$3" >/dev/null
}

# --- policy with a pinned descriptor ---------------------------------------------
ID="T-20260101-holdout-pinned"
R="$WORK/pinned"; repo "$R"
spec "$R" "$ID" "    descriptor_digest: $PINNED\n"
gate "$R" "$ID"
H="$ART/pinned-handoff.json"; handoff "$R" "$ID" 22222222-2222-4222-8222-222222222222 "$H"
forge "$ID" "$H" "$ART/pinned-forged.json"
set +e
out="$(accept "$R" "$ID" "$H" "$ART/pinned-forged.json" 2>&1)"; rc=$?
set -e
if [[ $rc -ne 0 && "$out" == *"RECEIPT_SUBJECT_MISMATCH"* ]]; then
  ok "a receipt for another descriptor is refused when the policy pins one"
else
  fail "a receipt for a different descriptor was accepted (rc=$rc)"
fi

python3 - "$ART/pinned-forged.json" "$ART/pinned-missing.json" <<'PY'
import json, sys
receipt = json.load(open(sys.argv[1], encoding="utf-8"))
receipt.pop("descriptor_digest")
json.dump(receipt, open(sys.argv[2], "w", encoding="utf-8"))
PY
set +e
out="$(accept "$R" "$ID" "$H" "$ART/pinned-missing.json" 2>&1)"; rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  ok "a receipt that names no descriptor is refused when the policy pins one"
else
  fail "a receipt without descriptor_digest was accepted against a pinned policy"
fi

bash "$TS" receipt evaluation --handoff "$H" --check-type holdout --evaluator holdout-test \
  --result pass --descriptor-digest "$PINNED" --out "$ART/pinned-good.json" >/dev/null
if accept "$R" "$ID" "$H" "$ART/pinned-good.json" 2>/dev/null | grep -q '^ACCEPTED=1$'; then
  ok "the receipt for the pinned descriptor is accepted"
else
  fail "the honest path broke: a receipt matching the pinned descriptor was refused"
fi

# --- a policy that pins nothing is refused at acceptance --------------------------
# The PRE-gate refuses to authorize such a task, so acceptance is called directly.
pins_nothing() { # pins_nothing <receipt contract>
  python3 - "$ROOT" "$1" <<'PY'
import json, pathlib, sys, tempfile
root = pathlib.Path(sys.argv[1])
for name in ("lib", "evidence", "security"):
    sys.path.insert(0, str(root / "src" / name))
from post_policy import evaluate

subject = {
    "task_id": "T-1", "task_revision_digest": "sha256:" + "1" * 64,
    "authorization_ref": "hmac-sha256-v3:" + "2" * 64, "attempt_id": "33333333-3333-4333-8333-333333333333",
    "base_commit": "0" * 40,
}
handoff = {
    "contract": "TaskHandoff/v3", "task_id": subject["task_id"],
    "task_revision_digest": subject["task_revision_digest"],
    "authorization": {"ref": subject["authorization_ref"]},
    "attempt": {"id": subject["attempt_id"], "issued_at": "2026-01-01T00:00:00Z"},
    "source": {"base_commit": subject["base_commit"]},
}
if sys.argv[2] == "EvaluationReceipt/v1":
    receipt = {
        "contract": "EvaluationReceipt/v1", "task_id": "T-1", "check_type": "holdout",
        "authorization_ref": "auth:anything", "evaluator": "legacy",
        "evaluated_at": "2030-01-01T00:00:00Z", "result": "pass", "evidence": [],
    }
else:
    receipt = {
        "contract": "EvaluationReceipt/v2", "subject": subject, "observed_at": "2030-01-01T00:00:00Z",
        "check_type": "holdout", "evaluator": "anyone", "result": "pass", "evidence": [],
    }
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory) / "receipt.json"
    path.write_text(json.dumps(receipt), encoding="utf-8")
    result = evaluate(
        {"format_version": 4, "signed_off_at": "2026-01-01T00:00:00Z",
         "evaluation_policy": {"acceptance_scope": "local", "holdout": {"required": True}}},
        handoff=handoff, holdout=str(path), graded=None, human=None, environment=None,
        identity=None, identity_public_key=None, identity_revocations=None, trust_registry=None,
    )
refused = not result["ok"] and any("pins neither" in error for error in result["errors"])
raise SystemExit(0 if refused else 1)
PY
}
for contract in EvaluationReceipt/v2 EvaluationReceipt/v1; do
  if pins_nothing "$contract"; then
    ok "a policy that pins nothing refuses a passing $contract"
  else
    fail "a passing $contract was accepted by a holdout policy that pins nothing"
  fi
done

# --- KNOWN GAP: authorization_ref alone does not tie a v2 receipt to a bundle -----
ID="T-20260101-holdout-unpinned"
R="$WORK/unpinned"; repo "$R"
spec "$R" "$ID" "    authorization_ref: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
gate "$R" "$ID"
H="$ART/unpinned-handoff.json"; handoff "$R" "$ID" 11111111-1111-4111-8111-111111111111 "$H"
forge "$ID" "$H" "$ART/unpinned-receipt.json"
set +e
accept "$R" "$ID" "$H" "$ART/unpinned-receipt.json" >/dev/null 2>&1; rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  ok "a receipt from another bundle is refused when the policy pins only authorization_ref"
else
  gap "a policy with authorization_ref alone accepted a v2 receipt produced from a different bundle; pin descriptor_digest (docs/concepts/evaluation-policy.md)"
fi

echo "  Known gaps: $KNOWN_GAPS (reported, not failed)"
if [[ "$FAILURES" -ne 0 ]]; then
  echo "HOLDOUT_ACCEPTANCE=FAIL ($FAILURES)"
  exit 1
fi
echo "HOLDOUT_ACCEPTANCE=READY"
