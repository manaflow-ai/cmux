#!/usr/bin/env python3
"""Swatinem/rust-cache never deletes a persistent runner's own ~/.cargo/bin.

At restore, rust-cache records every file already in ~/.cargo/bin. When its
post step saves a changed cache with `cache-bin` at its default (true), its
cleanup removes each of those files, rustup and cargo among them. On an
ephemeral runner that is harmless. On a self-hosted runner (our macOS minis, a
self-hosted Linux host behind vars.LINUX_RUNNER) it deletes the machine's own
toolchain, and every later Rust job on that host fails until someone puts
rustup back.

So every rust-cache step must set `cache-bin: false`, unless every runner its
job can resolve to is a literal ephemeral Linux or Windows label (GitHub-hosted
ubuntu/windows, Blacksmith ubuntu/windows). A `runs-on` built from an
expression or a repository variable can resolve to a self-hosted host, so it
needs the setting. Composite actions anywhere under .github/actions can be
called from any job, so they always need it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUST_CACHE = "swatinem/rust-cache@"
# Exact shapes of GitHub-hosted and Blacksmith ephemeral Linux/Windows labels.
# Anything else (a suffix such as -glaeda, a custom ubuntu-self-hosted) may be a
# persistent host.
EPHEMERAL_LABEL = re.compile(
    r"^(ubuntu-(\d{2}\.\d{2}|latest)(-arm)?|windows-(\d{4}|latest)"
    r"|blacksmith-\d+vcpu-(ubuntu-\d{4}(-arm)?|windows-\d{4}))$"
)
MATRIX_REF = re.compile(r"^\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}$")


def is_rust_cache(step: object) -> bool:
    return isinstance(step, dict) and str(step.get("uses", "")).lower().startswith(RUST_CACHE)


def keeps_bin(step: dict) -> bool:
    value = (step.get("with") or {}).get("cache-bin")
    return value is False or str(value).strip().lower() == "false"


def runner_labels(job: dict) -> list[object] | None:
    """Every label the job's runs-on can be, or None when that is not static."""
    runs_on = job.get("runs-on")
    if isinstance(runs_on, dict):
        return None
    labels = runs_on if isinstance(runs_on, list) else [runs_on]
    resolved: list[object] = []
    for label in labels:
        match = MATRIX_REF.match(str(label).strip())
        if not match:
            resolved.append(label)
            continue
        matrix = (job.get("strategy") or {}).get("matrix")
        if not isinstance(matrix, dict):
            return None
        key = match.group(1)
        values = matrix.get(key, [])
        if not isinstance(values, list):
            return None
        include = matrix.get("include", [])
        if not isinstance(include, list):
            return None
        values = list(values) + [entry[key] for entry in include if isinstance(entry, dict) and key in entry]
        if not values:
            return None
        resolved.extend(values)
    return resolved


def ephemeral_only(job: dict) -> bool:
    labels = runner_labels(job)
    if not labels:
        return False
    return all(isinstance(label, str) and "${{" not in label and EPHEMERAL_LABEL.match(label.strip()) for label in labels)


def workflow_failures(path: Path) -> tuple[int, list[str]]:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    found, failures = 0, []
    for job_name, job in (document.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not is_rust_cache(step):
                continue
            found += 1
            if not keeps_bin(step) and not ephemeral_only(job):
                failures.append(
                    f"{path.relative_to(ROOT)} {job_name}: '{step.get('name', step['uses'])}' can run on a "
                    "self-hosted or macOS runner and needs `cache-bin: false` (rust-cache deletes ~/.cargo/bin)"
                )
    return found, failures


def action_failures(path: Path) -> tuple[int, list[str]]:
    document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    found, failures = 0, []
    for step in (document.get("runs") or {}).get("steps") or []:
        if not is_rust_cache(step):
            continue
        found += 1
        if not keeps_bin(step):
            failures.append(
                f"{path.relative_to(ROOT)}: '{step.get('name', step['uses'])}' is in a composite action any "
                "runner can call and needs `cache-bin: false` (rust-cache deletes ~/.cargo/bin)"
            )
    return found, failures


def self_test() -> list[str]:
    errors = []
    cases = [
        ({"runs-on": "ubuntu-24.04"}, True),
        ({"runs-on": "blacksmith-32vcpu-ubuntu-2404"}, True),
        ({"runs-on": "blacksmith-6vcpu-macos-15"}, False),
        ({"runs-on": "macos-26"}, False),
        ({"runs-on": "blacksmith-4vcpu-ubuntu-2404-arm"}, True),
        ({"runs-on": "blacksmith-4vcpu-windows-2025"}, True),
        ({"runs-on": "blacksmith-4vcpu-ubuntu-2404-glaeda"}, False),
        ({"runs-on": "ubuntu-self-hosted"}, False),
        ({"runs-on": "ubuntu-24.04-mini"}, False),
        ({"runs-on": ["self-hosted", "macOS"]}, False),
        ({"runs-on": "${{ vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}"}, False),
        ({"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": {"include": [{"runner": "ubuntu-24.04"}]}}}, True),
        ({"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": {"include": [{"runner": "ubuntu-24.04"}, {"runner": "blacksmith-6vcpu-macos-latest"}]}}}, False),
        ({"runs-on": "${{ matrix.runner }}", "strategy": {"matrix": "${{ fromJSON(needs.plan.outputs.jobs) }}"}}, False),
    ]
    for job, expected in cases:
        if ephemeral_only(job) is not expected:
            errors.append(f"self-test: ephemeral_only({job['runs-on']!r}) should be {expected}")
    if keeps_bin({"with": {}}) or not keeps_bin({"with": {"cache-bin": False}}) or not keeps_bin({"with": {"cache-bin": "false"}}):
        errors.append("self-test: keeps_bin misreads cache-bin")
    return errors


def main() -> int:
    failures = self_test()
    total = 0
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        found, errors = workflow_failures(path)
        total += found
        failures += errors
    for path in sorted((ROOT / ".github/actions").rglob("action.y*ml")):
        found, errors = action_failures(path)
        total += found
        failures += errors
    if total == 0:
        failures.append("no Swatinem/rust-cache step found; this guard is reading the wrong files")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"ok: {total} rust-cache steps keep the runner's ~/.cargo/bin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
