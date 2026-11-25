#!/usr/bin/env python3
"""GhosttyKit release check verifies by digest unless the PR changes GhosttyKit provenance.

On 2026-11-23 18:10Z, 4 of 4 attempt-1 reds of the check were the 123 MB download stalling at
about 100 KB/s for 15 min on PRs to feat-cmux-next. The digest gate read the final `macos`
output, which NEXT routing turns off after the check was already routed on, so those PRs never
took the digest path. This test runs the provenance step and evaluates the gate.
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml"


def load() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def provenance_step(doc: dict) -> dict:
    steps = doc["jobs"]["changes"]["steps"]
    return next(s for s in steps if s.get("id") == "ghosttykit_provenance")


def run_step(changed: list[str] | None) -> dict[str, str]:
    script = provenance_step(load())["run"]
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp, "out")
        out.write_text("")
        if changed is not None:
            Path(temp, "cmux-ci-changed-files.txt").write_text("".join(f"{p}\n" for p in changed))
        env = dict(os.environ, RUNNER_TEMP=temp, GITHUB_OUTPUT=str(out))
        subprocess.run(["bash", "-c", script], check=True, env=env)
        return dict(line.split("=", 1) for line in out.read_text().splitlines() if line)


def gate(macos: str, provenance_changed: str) -> str:
    """The GHOSTTYKIT_VERIFY_BY_DIGEST expression, evaluated for these outputs."""
    return "1" if (macos == "true" or provenance_changed == "false") else "0"


class GhosttyKitDigestRouting(unittest.TestCase):
    def test_wiring(self) -> None:
        doc = load()
        changes = doc["jobs"]["changes"]
        self.assertEqual(
            changes["outputs"]["ghosttykit_provenance_changed"],
            "${{ steps.ghosttykit_provenance.outputs.changed }}",
        )
        ids = [s.get("id") for s in changes["steps"]]
        self.assertLess(ids.index("detect"), ids.index("ghosttykit_provenance"))
        check = doc["jobs"]["ghosttykit-release-check"]
        env = next(s["env"] for s in check["steps"] if "--verify-only" in s.get("run", ""))
        self.assertEqual(
            env["GHOSTTYKIT_VERIFY_BY_DIGEST"],
            "${{ (needs.changes.outputs.macos == 'true' || "
            "needs.changes.outputs.ghosttykit_provenance_changed == 'false') && '1' || '0' }}",
        )

    def test_unrelated_pr_without_mac_jobs_uses_digest(self) -> None:
        out = run_step(["webviews/src/App.tsx", "cmux-tui/src/lib.rs"])
        self.assertEqual(out, {"changed": "false"})
        self.assertEqual(gate("false", out["changed"]), "1")

    def test_pin_change_without_mac_jobs_downloads(self) -> None:
        for path in ("ghostty", "scripts/ghosttykit-checksums.txt", "scripts/download-prebuilt-ghosttykit.sh",
                     "scripts/validate-xcframework-archive.py", "tests/test_ci_ghosttykit_release_check.sh"):
            out = run_step(["README.md", path])
            self.assertEqual(out, {"changed": "true"}, path)
            self.assertEqual(gate("false", out["changed"]), "0", path)

    def test_lookalike_paths_are_not_provenance(self) -> None:
        self.assertEqual(run_step(["ghostty-notes.md", "xscripts/ghosttykit-checksums.txt"]), {"changed": "false"})

    def test_no_changed_file_list_downloads(self) -> None:
        out = run_step(None)
        self.assertEqual(out, {})
        self.assertEqual(gate("false", out.get("changed", "")), "0")

    def test_mac_jobs_use_digest(self) -> None:
        self.assertEqual(gate("true", "true"), "1")

    def test_next_pr_without_provenance_change_skips_the_check(self) -> None:
        """A feat-cmux-next PR that leaves the pin alone does not route the release check."""
        route = load()["jobs"]["changes"]["outputs"]["ghosttykit_release"]
        self.assertIn("steps.unchanged_inputs.outputs.compile_admitted == 'true'", route)
        self.assertIn(
            "(github.event_name == 'pull_request' && startsWith(github.event.pull_request.base.ref, 'feat-cmux-next') "
            "&& !contains(github.event.pull_request.labels.*.name, 'full-ci') "
            "&& steps.ghosttykit_provenance.outputs.changed == 'false')",
            route,
        )
        self.assertTrue(route.endswith("&& 'false' || steps.linux_guards.outputs.ghosttykit_release }}"))
        # The pin is still downloaded and checked on every feat-cmux-next push and nightly.
        workflows = WORKFLOW.parent
        for name in ("cmux-next.yml", "nightly.yml"):
            self.assertIn("download-prebuilt-ghosttykit", (workflows / name).read_text(encoding="utf-8"), name)


if __name__ == "__main__":
    unittest.main()
