#!/usr/bin/env bash
# test-holdout-seal.sh — a holdout key makes the seal mandatory, and stays secret.
#
# The seal used to be checked only when the descriptor carried one. An executor
# who could edit the bundle and its descriptor replaced the hidden check with a
# passing one, recomputed the digest, dropped the seal, and the verifier holding
# the key still answered VERIFIED. The key was also handed to every hidden check
# through the environment, where code under evaluation could read it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TS="$ROOT/bin/taskspec"
WORK="$(mktemp -d -t taskspec-holdout-seal-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

fail() { echo "  FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { echo "  ok   $*"; }

mkdir -p "$WORK/ws"
KEY="holdout-test-key"

cat > "$WORK/bundle.json" <<'JSON'
{"contract":"HoldoutBundle/v1","task_id":"T-20260101-holdout-seal","checks":[{"id":"holdout_hidden","argv":["bash","-c","exit 1"],"verifies":["B-1"]}]}
JSON

# --- sealing -----------------------------------------------------------------
sealed_out="$(TASKSPEC_HOLDOUT_KEY="$KEY" bash "$TS" holdout seal "$WORK/bundle.json" --out "$WORK/sealed.json")"
if [[ "$sealed_out" == HOLDOUT=SEALED* ]] && grep -q '"seal": "hmac-sha256-v1:' "$WORK/sealed.json"; then
  ok "a key seals the descriptor and reports SEALED"
else
  fail "sealing with a key must report HOLDOUT=SEALED and write a seal (got: $sealed_out)"
fi

unsealed_out="$(env -u TASKSPEC_HOLDOUT_KEY bash "$TS" holdout seal "$WORK/bundle.json" --out "$WORK/unsealed.json")"
if [[ "$unsealed_out" == HOLDOUT=UNSEALED* ]] && grep -q '"seal": null' "$WORK/unsealed.json"; then
  ok "without a key the descriptor is reported UNSEALED, never SEALED"
else
  fail "sealing without a key must report HOLDOUT=UNSEALED (got: $unsealed_out)"
fi

# --- the honest paths still work -----------------------------------------------
if TASKSPEC_HOLDOUT_KEY="$KEY" bash "$TS" holdout verify "$WORK/sealed.json" "$WORK/bundle.json" >/dev/null 2>&1; then
  ok "a sealed descriptor verifies with its key"
else
  fail "a sealed descriptor must verify with its key"
fi
if env -u TASKSPEC_HOLDOUT_KEY bash "$TS" holdout verify "$WORK/unsealed.json" "$WORK/bundle.json" >/dev/null 2>&1; then
  ok "an unsealed descriptor still verifies when no key is in use"
else
  fail "an unsealed descriptor must verify when no key is supplied"
fi
if env -u TASKSPEC_HOLDOUT_KEY bash "$TS" holdout verify "$WORK/sealed.json" "$WORK/bundle.json" >/dev/null 2>&1; then
  fail "a sealed descriptor must not verify without the key"
else
  ok "a sealed descriptor is refused without the key"
fi

# --- the downgrade: swap the hidden check, recompute the digest, drop the seal --
python3 - "$WORK" <<'PY'
import hashlib, json, pathlib, sys
work = pathlib.Path(sys.argv[1])
bundle = json.loads((work / "bundle.json").read_text(encoding="utf-8"))
bundle["checks"][0]["argv"] = ["bash", "-c", "exit 0"]
(work / "tampered-bundle.json").write_text(json.dumps(bundle), encoding="utf-8", newline="\n")
descriptor = json.loads((work / "sealed.json").read_text(encoding="utf-8"))
descriptor["seal"] = None
digest = hashlib.sha256((work / "tampered-bundle.json").read_bytes()).hexdigest()
descriptor["bundle_digest"] = f"sha256:{digest}"
(work / "tampered-descriptor.json").write_text(json.dumps(descriptor), encoding="utf-8", newline="\n")
PY

set +e
verify_out="$(TASKSPEC_HOLDOUT_KEY="$KEY" bash "$TS" holdout verify "$WORK/tampered-descriptor.json" "$WORK/tampered-bundle.json" 2>&1)"
verify_rc=$?
run_out="$(TASKSPEC_HOLDOUT_KEY="$KEY" bash "$TS" holdout run "$WORK/tampered-descriptor.json" "$WORK/tampered-bundle.json" --workspace "$WORK/ws" --legacy-v1 2>&1)"
run_rc=$?
set -e
if [[ "$verify_rc" -ne 0 && "$verify_out" == *"not sealed"* ]]; then
  ok "verify refuses an unsealed descriptor when a key is supplied"
else
  fail "verify accepted a descriptor whose seal was removed (rc=$verify_rc: $verify_out)"
fi
if [[ "$run_rc" -ne 0 && "$run_out" != *'"result": "pass"'* ]]; then
  ok "run refuses an unsealed descriptor when a key is supplied"
else
  fail "run passed a swapped check behind a removed seal (rc=$run_rc)"
fi

# --- the key never reaches the code under evaluation ---------------------------
cat > "$WORK/probe-bundle.json" <<'JSON'
{"contract":"HoldoutBundle/v1","task_id":"T-20260101-holdout-seal","checks":[{"id":"holdout_probe","argv":["bash","-c","if [ -n \"${TASKSPEC_HOLDOUT_KEY:-}\" ]; then echo leaked > key-leak.txt; fi; test \"${TASKSPEC_HOLDOUT:-}\" = 1"],"verifies":["B-1"]}]}
JSON
TASKSPEC_HOLDOUT_KEY="$KEY" bash "$TS" holdout seal "$WORK/probe-bundle.json" --out "$WORK/probe.json" >/dev/null
if TASKSPEC_HOLDOUT_KEY="$KEY" bash "$TS" holdout run "$WORK/probe.json" "$WORK/probe-bundle.json" --workspace "$WORK/ws" --legacy-v1 >/dev/null 2>&1 \
  && [[ ! -e "$WORK/ws/key-leak.txt" ]]; then
  ok "hidden checks run without TASKSPEC_HOLDOUT_KEY in their environment"
else
  fail "a hidden check could read TASKSPEC_HOLDOUT_KEY (or the sealed run failed)"
fi

if [[ "$FAILURES" -ne 0 ]]; then
  echo "HOLDOUT_SEAL=FAIL ($FAILURES)"
  exit 1
fi
echo "HOLDOUT_SEAL=ENFORCED"
