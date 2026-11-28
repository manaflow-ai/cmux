#!/usr/bin/env python3
"""The App Store shelf jobs restore the cargo build app-store-shelf-cargo-seed.yml saves to R2, under one key.

Every shelf run that reached its inputs compiled cmux-tui's `it` test binary cold, 635 crates with no cargo cache:
5 to 12 min of a 5 to 13 min job, about 50 of the 257 shelf jobs an hour (2026-11-27). The seed builds the check's
exact command and saves the dependencies to R2; both shelf jobs key with the same script and restore them first.
This pins:
- each consumer keys with scripts/ci/app-store-shelf-cargo-key.sh and restores the target and registry from R2,
  bounded and continue-on-error, after the key and before the check, so a miss behaves as before;
- the seed builds the check's own cargo command (with --no-run) under the flags the key script hashes, and saves;
- the key script sets the profile flags exactly as the check does, so a flag changed in one cannot quietly miss;
- the seed runs again when the check or the key script changes.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
KEY_SCRIPT = "scripts/ci/app-store-shelf-cargo-key.sh"
CHECK_SCRIPT = "scripts/ci/app-store-shelf-check.sh"
SEED = "app-store-shelf-cargo-seed.yml"
CONSUMERS = [("cmux-next-guards.yml", "app-store-shelf-pr"), ("app-store-shelf.yml", "shelf")]
FLAG = re.compile(r'(CARGO_PROFILE_[A-Z_]+|CARGO_INCREMENTAL)="\$\{\1:-([^}]*)\}"')


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def triggers(document: dict) -> dict:
    # PyYAML reads the bare `on:` key as True.
    return document.get("on") or document.get(True) or {}


def check_consumer(document: dict, workflow: str, job: str) -> list[str]:
    failures: list[str] = []
    spec = document["jobs"].get(job)
    if spec is None:
        return [f"{workflow} has no {job} job; this guard is reading the wrong file"]
    steps = spec.get("steps", [])

    def index(predicate) -> int:
        return next((i for i, step in enumerate(steps) if predicate(step)), -1)

    key_at = index(lambda s: KEY_SCRIPT in str(s.get("run", "")))
    check_at = index(lambda s: CHECK_SCRIPT in str(s.get("run", "")))
    if key_at < 0:
        failures.append(f"{workflow} {job} does not key its cargo build with {KEY_SCRIPT}")
    if check_at < 0:
        failures.append(f"{workflow} {job} does not run {CHECK_SCRIPT}")
    restores = [(i, s) for i, s in enumerate(steps) if str(s.get("uses", "")) == "./.github/actions/cache-restore"]
    paths = {str(s.get("with", {}).get("path", "")) for _, s in restores}
    if "cmux-tui/target" not in paths:
        failures.append(f"{workflow} {job} does not restore cmux-tui/target from R2")
    if not any("registry" in p for p in paths):
        failures.append(f"{workflow} {job} does not restore the cargo registry from R2")
    for i, step in restores:
        label = f"{workflow} {job} '{step.get('name')}'"
        if step.get("with", {}).get("backend") != "r2":
            failures.append(f"{label} does not read R2, where the seed saves")
        if step.get("continue-on-error") is not True or not step.get("timeout-minutes"):
            failures.append(f"{label} must be bounded and continue-on-error: a cache never fails the check")
        if key_at >= 0 and i < key_at:
            failures.append(f"{label} runs before the key step")
        if check_at >= 0 and i > check_at:
            failures.append(f"{label} runs after the check")
    return failures


def main() -> int:
    failures: list[str] = []
    for workflow, job in CONSUMERS:
        failures.extend(check_consumer(load(workflow), workflow, job))

    seed = load(SEED)
    seed_steps = seed["jobs"]["seed"]["steps"]
    runs = "\n".join(str(s.get("run", "")) for s in seed_steps)
    if f"{KEY_SCRIPT} --seed" not in runs:
        failures.append(f"{SEED} does not key with {KEY_SCRIPT} --seed")
    check_text = (ROOT / CHECK_SCRIPT).read_text(encoding="utf-8")
    command = re.search(r"cargo test --locked -p cmux-tui --test it", check_text)
    if command is None:
        failures.append(f"{CHECK_SCRIPT} no longer runs `cargo test --locked -p cmux-tui --test it`; update the seed")
    elif "cargo test --locked -p cmux-tui --test it --no-run" not in runs:
        failures.append(f"{SEED} does not build the check's command with --no-run")
    if not any(str(s.get("uses", "")) == "./.github/actions/cache-save" for s in seed_steps):
        failures.append(f"{SEED} never saves to R2")

    check_flags = dict(FLAG.findall(check_text))
    key_flags = dict(FLAG.findall((ROOT / KEY_SCRIPT).read_text(encoding="utf-8")))
    if not check_flags:
        failures.append(f"{CHECK_SCRIPT} sets no CARGO_PROFILE_* defaults; this guard reads the wrong file")
    if check_flags != key_flags:
        failures.append(f"{KEY_SCRIPT} hashes {key_flags}, but {CHECK_SCRIPT} builds with {check_flags}")
    for name, value in check_flags.items():
        if f"{name}={value}" not in runs:
            failures.append(f"{SEED} does not build with {name}={value}, as {CHECK_SCRIPT} does")

    paths = triggers(seed).get("push", {}).get("paths", [])
    for needed in (CHECK_SCRIPT, KEY_SCRIPT, "cmux-tui/Cargo.lock", "cmux-tui/rust-toolchain.toml"):
        if needed not in paths:
            failures.append(f"{SEED} does not reseed when {needed} changes")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("ok: both App Store shelf jobs restore the seeded R2 cargo build under the check's own key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
