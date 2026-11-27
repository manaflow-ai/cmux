#!/usr/bin/env python3
"""The relay deploy's journey build restores the cargo build cloud-journey-pr.yml seeds, under the same key.

cloudflare-relay.yml's build-journey-cmux built cmux-tui cold on every feat-cmux-next push. It ran past its
40-minute bound (job 139602427664) or filled the runner's disk (run 45710386290), so journey-staging was
skipped and deploy-production never ran: production's relay fell hours behind staging.

It now restores the compiled dependencies cloud-journey-pr.yml's `seed` saves to R2. That only hits when
both jobs compute the same key, which hashes the CARGO_PROFILE_* and CARGO_INCREMENTAL variables the
workflow sets (scripts/cmux-next/cloud-journey-cargo-key.sh). This pins:
- build-journey-cmux keys with that script and restores the target and registry before it builds;
- its effective profile env equals the env `seed` builds with, so a change to one cannot quietly miss;
- the restores are best effort (bounded, continue-on-error), so a slow or missing cache never blocks the deploy.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
KEY_SCRIPT = "scripts/cmux-next/cloud-journey-cargo-key.sh"


def load(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


def profile_env(document: dict, job: str) -> dict[str, str]:
    """The key's inputs as the job sees them: workflow env, then job env."""
    merged = {**(document.get("env") or {}), **(document["jobs"][job].get("env") or {})}
    return {
        name: str(value)
        for name, value in merged.items()
        if name.startswith("CARGO_PROFILE_") or name == "CARGO_INCREMENTAL"
    }


def main() -> int:
    failures: list[str] = []
    relay = load("cloudflare-relay.yml")
    journey_pr = load("cloud-journey-pr.yml")

    build = relay["jobs"].get("build-journey-cmux")
    if build is None:
        print("cloudflare-relay.yml has no build-journey-cmux job; this guard is reading the wrong file")
        return 1
    steps = build.get("steps", [])
    names = [str(step.get("name", step.get("uses", ""))) for step in steps]

    def index(predicate) -> int:
        return next((i for i, step in enumerate(steps) if predicate(step)), -1)

    key_at = index(lambda s: KEY_SCRIPT in str(s.get("run", "")))
    build_at = index(lambda s: "cargo build -p cmux-tui" in str(s.get("run", "")))
    restores = [
        (i, step)
        for i, step in enumerate(steps)
        if str(step.get("uses", "")) == "./.github/actions/cache-restore"
    ]
    if key_at < 0:
        failures.append(f"build-journey-cmux does not key its cargo build with {KEY_SCRIPT}")
    if build_at < 0:
        failures.append("build-journey-cmux has no `cargo build -p cmux-tui` step")
    restored_paths = {str(step.get("with", {}).get("path", "")) for _, step in restores}
    if "cmux-tui/target" not in restored_paths:
        failures.append("build-journey-cmux does not restore cmux-tui/target from R2")
    if not any("registry" in path for path in restored_paths):
        failures.append("build-journey-cmux does not restore the cargo registry from R2")
    for i, step in restores:
        label = names[i]
        if step.get("with", {}).get("backend") != "r2":
            failures.append(f"build-journey-cmux '{label}' does not read R2, where cloud-journey-pr.yml's seed saves")
        if step.get("continue-on-error") is not True or not step.get("timeout-minutes"):
            failures.append(f"build-journey-cmux '{label}' must be bounded and continue-on-error: a cache never blocks the deploy")
        if build_at >= 0 and i > build_at:
            failures.append(f"build-journey-cmux '{label}' runs after the build")
        if key_at >= 0 and i < key_at:
            failures.append(f"build-journey-cmux '{label}' runs before the key step")

    relay_env = profile_env(relay, "build-journey-cmux")
    seed_env = profile_env(journey_pr, "seed")
    if not seed_env:
        failures.append("cloud-journey-pr.yml's seed sets no CARGO_PROFILE_* env; this guard is reading the wrong job")
    if relay_env != seed_env:
        failures.append(
            "build-journey-cmux's profile env differs from cloud-journey-pr.yml seed's, so its R2 key never hits "
            f"(cloud-journey-cargo-key.sh hashes them): relay {relay_env} vs seed {seed_env}"
        )

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("ok: build-journey-cmux restores the seeded R2 cargo build under the same key")
    return 0


if __name__ == "__main__":
    sys.exit(main())
