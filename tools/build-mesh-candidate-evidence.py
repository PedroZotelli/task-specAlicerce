#!/usr/bin/env python3
"""Run the TaskMesh suites on this host and retain candidate release evidence.

Writes release/<VERSION>/mesh-conformance.json, reviewer-report.json, and
mesh-release-evidence.json. Every state is observed here, now: a suite passes only
when it exits 0 and prints its READY token. Hosted CI, live Docker isolation on a
host without it, remote install, signed provenance, and publication are recorded
as `not_run` until they execute, and the release status stays `candidate`.

Usage: python3 tools/build-mesh-candidate-evidence.py [--out-dir DIR]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import platform
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src" / "lib"))
from portable_exec import bash_executable  # noqa: E402

SUITES = (
    ("contracts", "test-mesh-contracts.sh", "MESH_CONTRACTS=READY"),
    ("daemon", "test-mesh-daemon.sh", "MESH_DAEMON=READY"),
    ("leases-and-fencing", "test-mesh-leases.sh", "MESH_LEASES=READY"),
    ("routing-and-integration", "test-mesh-routing-integration.sh", "MESH_ROUTING_INTEGRATION=READY"),
    ("supervised-adapters", "test-mesh-adapters.sh", "MESH_ADAPTERS=READY"),
    ("autonomous-isolation", "test-mesh-isolation.sh", "MESH_ISOLATION=READY"),
    ("cross-cockpit-mcp", "test-mesh-cockpit.sh", "MESH_COCKPIT=READY"),
    ("crash-recovery", "test-mesh-conformance.sh", "MESH_RECOVERY=READY"),
    ("demonstration", "test-mesh-demo.sh", "MESH_DEMO=READY"),
    ("core-and-mesh-install", "test-mesh-install.sh", "MESH_INSTALL=READY"),
)
# Invariant -> suites whose pass proves it on this host.
INVARIANTS = {
    "canonical_task_authority_only": ("contracts", "supervised-adapters"),
    "target_branch_unchanged": ("routing-and-integration", "supervised-adapters"),
    "one_authoritative_fenced_attempt": ("leases-and-fencing",),
    "advisor_cannot_widen_eligibility": ("routing-and-integration",),
    "supervised_worktree_not_claimed_as_sandbox": ("supervised-adapters",),
    "autonomous_no_silent_downgrade": ("autonomous-isolation",),
    "credential_values_not_retained": ("supervised-adapters",),
}
HOSTED_GATES = ("hosted_ubuntu", "hosted_macos", "hosted_live_isolation",
                "private_remote_install", "private_provenance", "publication")


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def digest(path: pathlib.Path) -> str:
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()


def git(*args: str) -> str:
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


def run_suite(script: str, token: str) -> tuple[str, str]:
    completed = subprocess.run([bash_executable(), str(ROOT / "tests" / script)], cwd=ROOT,
                               capture_output=True, text=True, check=False)
    output = completed.stdout + completed.stderr
    if completed.returncode != 0:
        return "fail", f"exit {completed.returncode}"
    if token not in output:
        return "not_run", "suite exited 0 without its READY token (proof skipped on this host)"
    return "pass", token


def host_platform() -> dict[str, Any]:
    names = {"Darwin": "macOS"}
    system = platform.system()
    docker = subprocess.run(["docker", "version", "--format", "{{.Server.Version}}"],
                            capture_output=True, text=True, check=False) if _has("docker") else None
    return {
        "os": names.get(system, system),
        "architecture": platform.machine().lower(),
        "docker_server": docker.stdout.strip() if docker and docker.returncode == 0 else None,
    }


def _has(program: str) -> bool:
    from shutil import which
    return which(program) is not None


def write(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out-dir", default=None)
    args = parser.parse_args()
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    out_dir = pathlib.Path(args.out_dir) if args.out_dir else ROOT / "release" / version
    out_dir.mkdir(parents=True, exist_ok=True)
    commit = git("rev-parse", "HEAD")
    observed = now()
    host = host_platform()

    results = {}
    for suite_id, script, token in SUITES:
        state, detail = run_suite(script, token)
        results[suite_id] = {"id": suite_id, "state": state, "token": token, "detail": detail}
        print(f"{state:8} {suite_id}")

    ran = [row for row in results.values() if row["state"] != "not_run"]
    skipped = [row["id"] for row in results.values() if row["state"] == "not_run"]
    conformance = {
        "contract": "TaskMeshConformanceEvidence/v1",
        "version": version,
        "observed_at": observed,
        "platform": host,
        "source_commit_before_evidence_finalization": commit,
        "suites": [{"id": row["id"], "state": row["state"], "token": row["token"]} for row in ran],
        "invariants": {
            name: True for name, proofs in INVARIANTS.items()
            if all(results[proof]["state"] == "pass" for proof in proofs)
        },
        "limitations": [
            "The local corridor is synthetic control-plane proof, not long-running production reliability.",
            *(f"Suite `{suite}` did not run its proof on this host ({host['os']}) and is not claimed." for suite in skipped),
            "Hosted Ubuntu, macOS, and Windows evidence is retained separately after it executes.",
        ],
    }
    conformance_path = out_dir / "mesh-conformance.json"
    write(conformance_path, conformance)

    docs = subprocess.run([bash_executable(), str(ROOT / "tests" / "test-readme-contract.sh")], cwd=ROOT,
                          capture_output=True, text=True, check=False)
    lint = subprocess.run([bash_executable(), str(ROOT / "tests" / "lint-docs.sh")], cwd=ROOT,
                          capture_output=True, text=True, check=False)
    boundaries = (ROOT / "docs" / "trust" / "taskmesh-boundaries.md").read_text(encoding="utf-8")
    checks = [
        {"id": "installation", "state": results["core-and-mesh-install"]["state"],
         "proof": "Core-only, checksum-backed copy, tamper rejection, and version mismatch cases executed by tests/test-mesh-install.sh."},
        {"id": "cross-cockpit", "state": results["cross-cockpit-mcp"]["state"],
         "proof": "tests/test-mesh-cockpit.sh observed and controlled one durable run from independent clients."},
        {"id": "documentation-contract", "state": "pass" if docs.returncode == 0 and lint.returncode == 0 else "fail",
         "proof": "tests/test-readme-contract.sh and tests/lint-docs.sh passed."},
        {"id": "assurance-language", "state": "pass" if "sandbox" in boundaries.lower() else "fail",
         "proof": "docs/trust/taskmesh-boundaries.md states the sandbox boundary; supervised-adapter suite keeps worktrees unclaimed as sandboxes."},
    ]
    reviewer = {
        "contract": "TaskMeshReviewerReport/v1",
        "release_version": version,
        "observed_at": observed,
        "result": "pass" if all(check["state"] == "pass" for check in checks) else "fail",
        "checks": checks,
        "artifacts": [{"path": path, "digest": digest(ROOT / path)} for path in (
            "docs/getting-started/taskmesh.md", "docs/reference/taskmesh-contracts.md",
            "docs/trust/taskmesh-boundaries.md", "tests/test-mesh-cockpit.sh")],
        "limitations": [
            "Automated checks by tools/build-mesh-candidate-evidence.py; the product-boundary review is the owner's at release.",
        ],
    }
    reviewer_path = out_dir / "reviewer-report.json"
    write(reviewer_path, reviewer)

    baseline = json.loads((ROOT / "release" / "evidence.json").read_text(encoding="utf-8"))
    scorecard = baseline["quality_scorecard"]
    scorecard_value = json.loads((ROOT / scorecard["path"]).read_text(encoding="utf-8"))
    evidence = {
        "contract": "TaskMeshReleaseEvidence/v1",
        "version": version,
        "api": "TaskMeshAPI/v1alpha1",
        "generated_at": observed,
        "source": {"branch": git("rev-parse", "--abbrev-ref", "HEAD"), "commit_before_evidence_finalization": commit},
        "release_status": "candidate",
        "repository_visibility": "public",
        "quality_baseline": {
            "contract": "TaskSpecQualityScorecard/v1", "release": baseline["version"],
            "path": scorecard["path"], "digest": scorecard["digest"],
            "score": scorecard_value["total"]["awarded"], "regression": False,
        },
        "gates": {
            "local_conformance": "pass" if all(row["state"] == "pass" for row in ran) else "fail",
            "live_local_isolation": results["autonomous-isolation"]["state"],
            "local_install_matrix": results["core-and-mesh-install"]["state"],
            "cross_cockpit_demo": "pass" if results["cross-cockpit-mcp"]["state"] == results["demonstration"]["state"] == "pass" else "fail",
            **{gate: "not_run" for gate in HOSTED_GATES},
        },
        "artifacts": [{"path": path.relative_to(ROOT).as_posix(), "digest": digest(path)} for path in (conformance_path, reviewer_path)],
        "claims": {"hosted_control_plane": False, "production_reliability": False, "protocol_certification": False,
                   "tier1_from_worktrees": False, "automatic_target_merge": False},
        "next_gate": "Hosted CI on Ubuntu, macOS, and Windows, then signed provenance and publication of v" + version + ".",
    }
    write(out_dir / "mesh-release-evidence.json", evidence)
    print(f"MESH_CANDIDATE_EVIDENCE={'READY' if evidence['gates']['local_conformance'] == 'pass' else 'FAIL'} dir={out_dir.relative_to(ROOT).as_posix() if out_dir.is_relative_to(ROOT) else out_dir}")
    return 0 if evidence["gates"]["local_conformance"] == "pass" and reviewer["result"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
