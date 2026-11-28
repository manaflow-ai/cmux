#!/usr/bin/env python3
"""A reusable workflow that declares GLAEDA_ROUTE_APP_KEY gets it from every caller.

A called workflow sees a secret only when its caller passes it (or uses `secrets: inherit`). Without the routing App
key the called plan's runner picker reads the queue with the shared job token; run 46151995589's review gate
(ios-internal-nightly.yml, 2026-11-28 15:48Z) found that token's hour spent, got HTTP 403 and kept
blacksmith-6vcpu-macos-26 instead of an owned Mac.

The rule: for every job `uses: ./.github/workflows/X.yml` whose X.yml references `secrets.GLAEDA_ROUTE_APP_KEY` and
declares it under `on.workflow_call.secrets`, the caller passes GLAEDA_ROUTE_APP_KEY or inherits.
"""
from __future__ import annotations

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
KEY = "GLAEDA_ROUTE_APP_KEY"

# caller file:job -> why it does not pass the key.
ALLOWED = {
    # 118e52e14907 (gate dispatch credentials by environment): ci-macos reads dispatch credentials only from its
    # protected environment, so ci.yml deliberately passes none of them.
    "ci.yml:macos": "dispatch credentials are environment-gated (118e52e14907)",
}


def load(path: Path) -> dict:
    # BaseLoader keeps the `on` key a string (the default loader reads it as True).
    doc = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
    return doc if isinstance(doc, dict) else {}


def declared_route_key(path: Path) -> bool:
    text = path.read_text()
    if f"secrets.{KEY}" not in text:
        return False
    on = load(path).get("on")
    if not isinstance(on, dict):
        return False
    call = on.get("workflow_call")
    secrets = call.get("secrets") if isinstance(call, dict) else None
    return isinstance(secrets, dict) and KEY in secrets


def misses() -> list[str]:
    callees = {p.name for p in WORKFLOWS.glob("*.y*ml") if declared_route_key(p)}
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        jobs = load(path).get("jobs")
        if not isinstance(jobs, dict):
            continue
        for name, job in jobs.items():
            if not isinstance(job, dict):
                continue
            uses = job.get("uses", "")
            if not isinstance(uses, str) or not uses.startswith("./.github/workflows/"):
                continue
            if Path(uses).name not in callees:
                continue
            secrets = job.get("secrets")
            if secrets == "inherit" or (isinstance(secrets, dict) and KEY in secrets):
                continue
            ref = f"{path.name}:{name}"
            if ref not in ALLOWED:
                found.append(f"{ref} calls {Path(uses).name} without {KEY}")
    return found


class ReusableRouteKeyPassed(unittest.TestCase):
    def test_every_caller_passes_the_declared_routing_key(self) -> None:
        self.assertEqual(misses(), [], f"pass `{KEY}: ${{{{ secrets.{KEY} }}}}` in the caller's `secrets:` "
                                       "(or add an ALLOWED entry with the reason)")

    def test_the_internal_builder_review_gate_is_covered(self) -> None:
        self.assertTrue(declared_route_key(WORKFLOWS / "ios-review-gate.yml"))

    def test_allowlist_entries_still_exist(self) -> None:
        for ref in ALLOWED:
            file, job = ref.split(":")
            self.assertIn(job, load(WORKFLOWS / file).get("jobs", {}), ref)


if __name__ == "__main__":
    unittest.main()
