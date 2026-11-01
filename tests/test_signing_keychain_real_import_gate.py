#!/usr/bin/env python3
"""The macOS real-import job runs only when the keychain tool's inputs change.

signing-keychain-macos.yml triggers on every scripts/ci shell change because
its Linux bash32-syntax job must parse them all. The real-import job needs a
Blacksmith macOS runner, the last resort in the routing order, so a Linux plan
job starts it only when a file it exercises changed. These contracts keep the
plan on Linux, keep real-import behind it, and keep the plan's input list
covering every file the real-import test runs: a new dependency that the list
misses would let a change to it merge untested on macOS.
"""

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "signing-keychain-macos.yml"
TEST = "tests/test_signing_keychain_real_import.sh"

# Every file the real-import job runs, directly or through what it sources.
EXERCISED = [
    "scripts/ci/signing-keychain.sh",
    "scripts/ci/lib/signing-runtime-guard.sh",
    "scripts/import-apple-developer-id-intermediates.sh",
    "scripts/apple-developer-id-certs/DeveloperIDG2CA.cer",
    "scripts/select-ci-xcode.sh",
    "tests/test_signing_keychain_real_import.sh",
    "tests/test_derive_sparkle_public_key.sh",
    "scripts/derive_sparkle_public_key.swift",
    ".github/workflows/signing-keychain-macos.yml",
]

# Files the real import does not exercise: a change to one alone skips the Mac.
NOT_EXERCISED = [
    "scripts/ci/notarize-nightly-dmg.sh",
    "scripts/cmux-next/fast-tier-cache-key.sh",
    "scripts/reload.sh",
    ".github/workflows/nightly.yml",
]


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def plan_patterns() -> list[re.Pattern[str]]:
    step = next(step for step in workflow()["jobs"]["real-import-plan"]["steps"] if step.get("id") == "plan")
    return [re.compile(line) for line in step["env"]["INPUTS"].splitlines() if line.strip()]


def triggers() -> dict:
    # PyYAML reads the bare `on:` key as True.
    data = workflow()
    return data.get("on", data.get(True))


class RealImportGateTests(unittest.TestCase):
    def test_plan_runs_on_linux(self) -> None:
        runs_on = workflow()["jobs"]["real-import-plan"]["runs-on"]
        self.assertIn("ubuntu", runs_on)
        self.assertNotIn("macos", runs_on)

    def test_real_import_waits_for_the_plan(self) -> None:
        job = workflow()["jobs"]["real-import"]
        self.assertEqual(job["needs"], "real-import-plan")
        self.assertEqual(job["if"], "${{ needs.real-import-plan.outputs.run == 'true' }}")

    def test_inputs_cover_what_the_test_runs(self) -> None:
        patterns = plan_patterns()
        for path in EXERCISED:
            self.assertTrue(any(p.search(path) for p in patterns), f"{path} changes would skip the real import")
        text = (ROOT / TEST).read_text(encoding="utf-8")
        for ref in sorted(set(re.findall(r"(?:scripts|tests)/[A-Za-z0-9_./-]+\.(?:sh|swift|cer)", text))):
            self.assertIn(ref, EXERCISED, f"{TEST} runs {ref}; add it to the plan's INPUTS and EXERCISED")

    def test_other_scripts_skip_the_mac(self) -> None:
        patterns = plan_patterns()
        for path in NOT_EXERCISED:
            self.assertFalse(any(p.search(path) for p in patterns), f"{path} alone should not start the Mac job")

    def test_every_input_also_triggers_the_workflow(self) -> None:
        on = triggers()
        for event in ("push", "pull_request"):
            globs = on[event]["paths"]
            for path in EXERCISED:
                self.assertTrue(
                    any(Path(path).match(glob) or path.startswith(glob.rstrip("*")) for glob in globs),
                    f"{path} is a real-import input but not a {event} trigger",
                )

    def test_unreadable_diff_runs_the_real_import(self) -> None:
        step = next(step for step in workflow()["jobs"]["real-import-plan"]["steps"] if step.get("id") == "plan")
        run = step["run"]
        self.assertIn("run=true", run.splitlines()[1])
        self.assertIn("workflow_dispatch", run)
        self.assertIn(">= 300", run)


if __name__ == "__main__":
    unittest.main()
