#!/usr/bin/env python3
"""The cmuxd-remote license review is written by the autofix, never by hand.

Leo, 2026-10-22: "why would you just fail \"without a review\" instead of fixing it". When
daemon/remote/go.mod or go.sum changes and every license is allowed,
scripts/remote_daemon_notices.py check --update-review records the review
(daemon/remote/third-party/review.json, and third-party/go for a new Go). The PR autofix
(cmux-next-pr-autofix.yml) commits it on the pull request's branch, and the base autofix
(cmux-next-base-autofix.yml) after a feat-cmux-next push, as the `licenses` repair area
(autofix-areas.sh, base-autofix.sh --license-review). Both jobs set up the go.mod toolchain for
it, and the base autofix makes it again on a moved tip (base-autofix-land.sh).

The step scripts run here with the autofix stubbed: no network, no Go.
"""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
PR = yaml.safe_load((ROOT / ".github/workflows/cmux-next-pr-autofix.yml").read_text())
BASE = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())
DAEMON = yaml.safe_load((ROOT / ".github/workflows/cmux-next-remote-daemon.yml").read_text())
REVIEW = "daemon/remote/third-party/review.json"
GO_TEXT = "daemon/remote/third-party/go/LICENSE"
STUB_AUTOFIX = '#!/bin/sh\n# --license-review)\nprintf "%s\\n" "$@" > "$ARGS_OUT"\n'


def step(doc: dict, job: str, name: str) -> dict:
    return next(s for s in doc["jobs"][job]["steps"] if s.get("name") == name)


def setup_go(doc: dict, job: str) -> dict:
    return next(s for s in doc["jobs"][job]["steps"] if str(s.get("uses", "")).startswith("actions/setup-go@"))


def shell_function(script: Path, name: str, indent: str = "") -> str:
    """The text of a shell function in `script`, to run alone."""
    lines = script.read_text().splitlines()
    start = lines.index(f"{indent}{name}() {{")
    end = lines.index(f"{indent}}}", start)
    return "\n".join(line[len(indent):] for line in lines[start:end + 1])


class WorkflowsSetUpGo(unittest.TestCase):
    def test_both_jobs_set_up_the_daemons_go_when_the_area_is_on(self):
        pinned = setup_go(DAEMON, "release-packaging")
        for doc, job in ((PR, "repair"), (BASE, "autofix")):
            with self.subTest(job=job):
                go = setup_go(doc, job)
                self.assertEqual(go["uses"], pinned["uses"], "the same pinned setup-go as the remote daemon job")
                self.assertEqual(go["with"]["go-version-file"], "daemon/remote/go.mod")
                self.assertIs(go["with"]["cache"], False)
                self.assertEqual(go["if"], "steps.areas.outputs.licenses == 'true'")
                steps = doc["jobs"][job]["steps"]
                self.assertLess(steps.index(go), steps.index(step(doc, job, "Repair")))

    def test_the_base_autofix_runs_on_a_go_dependency_change(self):
        paths = BASE.get("on", BASE.get(True))["push"]["paths"]  # PyYAML reads `on:` as True
        for path in ("daemon/remote/go.mod", "daemon/remote/go.sum", "daemon/remote/third-party/**",
                     "daemon/remote/**/*.go", "scripts/remote_daemon_notices.py",
                     "cmux-tui/build-support/notices/license_match.py",
                     "scripts/cmux-next/check_app_crate_licenses.py"):
            self.assertIn(path, paths)

    def test_every_input_of_the_licenses_area_starts_the_base_autofix(self):
        # Each path the licenses area reads (autofix-areas.sh) must be in the push paths, or a change
        # to it alone (the allowlist, say) never gets its review recorded after the merge.
        import fnmatch
        paths = BASE.get("on", BASE.get(True))["push"]["paths"]
        areas = ROOT / "scripts/cmux-next/autofix-areas.sh"
        for changed in ("daemon/remote/go.mod", "daemon/remote/go.sum", "daemon/remote/third-party/review.json",
                        "daemon/remote/third-party/spdx-templates/MIT.template.txt",
                        "daemon/remote/cmd/cmuxd-remote/main.go", "daemon/remote/internal/x/y.go",
                        "scripts/remote_daemon_notices.py", "cmux-tui/build-support/notices/license_match.py",
                        "scripts/cmux-next/check_app_crate_licenses.py"):
            with self.subTest(path=changed):
                on = subprocess.run(["bash", str(areas)], input=changed + "\n", capture_output=True, text=True)
                self.assertIn("licenses=true", on.stdout.split())
                self.assertTrue(any(fnmatch.fnmatchcase(changed, p.replace("**/", "*").replace("**", "*"))
                                    for p in paths), f"{changed} is a licenses input but starts no base autofix")

    def test_the_base_autofix_repairs_and_remakes_with_the_area(self):
        for name in ("Repair", "Push the repairs"):
            with self.subTest(step=name):
                self.assertEqual(step(BASE, "autofix", name)["env"]["LICENSES"], "${{ steps.areas.outputs.licenses }}")

    def test_the_remote_daemon_guard_says_the_autofix_records_it(self):
        text = (ROOT / ".github/workflows/cmux-next-remote-daemon.yml").read_text()
        self.assertNotIn("generate --update-review records it", text)
        comment = text.split("- name: cmuxd-remote licenses are allowed (fast guard)")[0].rsplit("cache: false", 1)[1]
        self.assertIn("PR autofix", comment)
        self.assertIn("base autofix", comment)


class RepairPassesTheFlag(unittest.TestCase):
    def pr_repair_args(self, licenses: str, base_knows_flag: bool = True) -> list[str]:
        work = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(work)])
        temp = work / "runner-temp"
        stub = temp / "autofix/scripts/cmux-next/base-autofix.sh"
        stub.parent.mkdir(parents=True)
        stub.write_text(STUB_AUTOFIX if base_knows_flag else STUB_AUTOFIX.replace("--license-review)", "older"))
        stub.chmod(0o755)
        env = {**os.environ, "RUNNER_TEMP": str(temp), "GITHUB_WORKSPACE": str(work),
               "GITHUB_STEP_SUMMARY": str(work / "summary"), "GITHUB_SHA": "0" * 40,
               "AUTOFIX": str(stub.parent), "ARGS_OUT": str(work / "args"),
               "GRAPH": "false", "STRINGS": "false", "SDK": "false", "SHORTCUTS": "false", "APPHOST": "false",
               "ACTIONS": "false", "EXPORTS_VERIFIED": "true", "SETTINGS": "false", "SETTINGS_VERIFIED": "true",
               "RATCHETS": "false", "CLOUD": "false", "GHOSTTY": "false", "FMT": "false", "LICENSES": licenses}
        self.assertEqual(step(PR, "repair", "Repair")["env"]["LICENSES"], "${{ steps.areas.outputs.licenses }}")
        done = subprocess.run(["bash", "-e", "-c", step(PR, "repair", "Repair")["run"]], cwd=work, env=env,
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return (work / "args").read_text().split()

    def test_the_pr_repair_records_the_review(self):
        self.assertIn("--license-review", self.pr_repair_args("true"))
        self.assertNotIn("--license-review", self.pr_repair_args("false"))

    def test_the_pr_repair_skips_the_flag_while_the_bases_script_lacks_it(self):
        self.assertNotIn("--license-review", self.pr_repair_args("true", base_knows_flag=False))

    def test_the_base_repair_script_maps_the_area_to_the_flag(self):
        work = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(work)])
        stub = work / "autofix.sh"
        stub.write_text(STUB_AUTOFIX)
        stub.chmod(0o755)
        for licenses, again, expected in (("true", "", True), ("false", "", False), ("true", "1", True)):
            with self.subTest(licenses=licenses, again=again):
                env = {**os.environ, "CMUX_BASE_AUTOFIX_SCRIPT": str(stub), "ARGS_OUT": str(work / "args"),
                       "LICENSES": licenses, "CMUX_BASE_AUTOFIX_AGAIN": again, "GRAPH": "false"}
                done = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/base-autofix-repair.sh"), str(work)],
                                      env=env, capture_output=True, text=True)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual("--license-review" in (work / "args").read_text().split(), expected)


class TheBasePushLandsIt(unittest.TestCase):
    def run_function(self, script: str, name: str, call: str, indent: str = "", prelude: str = "") -> subprocess.CompletedProcess:
        body = shell_function(ROOT / "scripts/cmux-next" / script, name, indent)
        return subprocess.run(["bash", "-c", f"set -euo pipefail\n{prelude}\n{body}\n{call}"],
                              capture_output=True, text=True)

    def test_the_review_belongs_to_the_licenses_area(self):
        for path in (REVIEW, GO_TEXT):
            with self.subTest(path=path):
                done = self.run_function("base-autofix-push.sh", "output_areas", f"echo {path} | output_areas",
                                         prelude="snapshot=schemas/defaults/cmux-next.json")
                self.assertEqual(done.stdout.split(), ["licenses"], done.stderr)

    def test_a_held_review_is_made_again_on_the_tip(self):
        for path in (REVIEW, GO_TEXT):
            with self.subTest(path=path):
                done = self.run_function("base-autofix-land.sh", "remade", f"remade {path}", indent="  ",
                                         prelude="actions_current=0 settings_current=0")
                self.assertEqual(done.returncode, 0, done.stderr)


if __name__ == "__main__":
    unittest.main()
