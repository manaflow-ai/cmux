#!/usr/bin/env python3
"""A pull request that changes cmux-rd-host runs its macOS fmt, clippy and tests.

cmux-rd-host's pull request jobs (rust-workspaces.yml) run on Linux, so its code behind
#[cfg(target_os = "macos")] (src/mac/) was never linted by one: on 2026-11-15 `cmux-tui-rust-check.sh rd-host` on
macOS was red on feat-cmux-next with two dead_code errors in src/hybrid.rs (#43668) and no pull request job had seen
them. This test fails unless some workflow both starts on a feat-cmux-next pull request that changes a macOS-only
file of the crate and runs `cmux-tui-rust-check.sh` in mode `rd-host` with `--os macos` (fleet-rd-host-macos.yml).

The trigger is read as GitHub reads it (branches, branches-ignore, paths, paths-ignore), and a job or step whose
`if:` names another event, or a run line that asks for Linux, does not count.
"""
from __future__ import annotations

import re
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import workflow_paths_cover_inputs as detector  # noqa: E402

BASE = "feat-cmux-next"
# A macOS-only module, and the file whose dead code only the macOS clippy saw (#43668): a change to either alone
# must start the macOS check.
MAC_ONLY_FILES = (
    "cmux-tui/crates/cmux-rd-host/src/mac/cpu.rs",
    "cmux-tui/crates/cmux-rd-host/src/hybrid.rs",
)
SCRIPT = re.compile(r"(^|[\s/])cmux-tui-rust-check\.sh(\s|$)")
MAC = re.compile(r"(^|\s)--os(=|\s+)[\"']?macos[\"']?(\s|$)")
RD_HOST = re.compile(r"(^|\s)--arg(=|\s+)[\"']?rd-host[\"']?(\s|$)")


def admits_pull_request(document, path: str, base: str = BASE) -> bool:
    """Whether a pull request into `base` that changes only `path` starts this workflow."""
    events = detector.triggers(document)
    if "pull_request" not in events:
        return False
    config = events.get("pull_request") or {}
    if not isinstance(config, dict):
        return True
    if "branches" in config and not detector.admits("paths", [str(b) for b in config["branches"] or []], base):
        return False
    if "branches-ignore" in config and not detector.admits(
            "paths-ignore", [str(b) for b in config["branches-ignore"] or []], base):
        return False
    for kind in detector.FILTERS:
        if kind in config:
            return detector.admits(kind, [str(p) for p in config[kind] or []], path)
    return True


def runs_rd_host_on_macos(run: str) -> bool:
    """Whether one command of a step's script runs cmux-tui-rust-check.sh rd-host on macOS."""
    for command in run.replace("\\\n", " ").splitlines():
        if SCRIPT.search(command) and MAC.search(command) and RD_HOST.search(command):
            return True
    return False


def routes(root: Path, path: str) -> list[str]:
    """The workflows (repo paths) whose pull request run for a change to `path` runs the macOS rd-host check."""
    repo = detector.Repo(root)  # steps_for reads only its root (to follow local reusable workflows)
    found = []
    for workflow in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        document = detector.load_quietly(workflow, None)
        if not isinstance(document, dict) or not admits_pull_request(document, path):
            continue
        if any(runs_rd_host_on_macos(run) for run, _, _ in detector.steps_for(repo, document, "pull_request")):
            found.append(workflow.relative_to(root).as_posix())
    return found


class RdHostMacosRoute(unittest.TestCase):
    def test_a_mac_only_change_runs_the_macos_rd_host_check(self):
        for path in MAC_ONLY_FILES:
            with self.subTest(path=path):
                self.assertNotEqual(
                    routes(ROOT, path), [],
                    f"no pull_request workflow starts for {path} and runs `cmux-tui-rust-check.sh rd-host` with "
                    "`--os macos`: its macOS-only code merges unlinted (#43668)")


class Matcher(unittest.TestCase):
    STEP = "cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref X \\\n  {os} --arg {arg}"

    def write(self, root: Path, text: str) -> None:
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "w.yml").write_text(textwrap.dedent(text))

    def workflow(self, paths: str, run: str, condition: str = "true") -> str:
        return f"""
            on:
              pull_request:
                branches: [feat-cmux-next]
                paths: {paths}
            jobs:
              check:
                if: ${{{{ {condition} }}}}
                runs-on: x
                steps:
                  - run: |
                      {run.replace(chr(10), chr(10) + ' ' * 22)}
            """

    def routed(self, text: str, path: str = MAC_ONLY_FILES[0]) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            self.write(Path(tmp), text)
            return routes(Path(tmp), path)

    def test_a_macos_rd_host_step_behind_a_matching_filter_counts(self):
        step = self.STEP.format(os="--os macos", arg="rd-host")
        self.assertEqual(self.routed(self.workflow('["cmux-tui/crates/cmux-rd-host/**"]', step)),
                         [".github/workflows/w.yml"])

    def test_a_linux_run_or_another_mode_does_not_count(self):
        for os_flag, arg in (("--os linux", "rd-host"), ("", "rd-host"), ("--os macos", "rd-bench")):
            with self.subTest(os=os_flag, arg=arg):
                step = self.STEP.format(os=os_flag, arg=arg)
                self.assertEqual(self.routed(self.workflow('["cmux-tui/crates/cmux-rd-host/**"]', step)), [])

    def test_a_filter_that_misses_the_crate_does_not_count(self):
        step = self.STEP.format(os="--os macos", arg="rd-host")
        self.assertEqual(self.routed(self.workflow('["cmux-tui/crates/cmux-rd-host/src/linux/**"]', step)), [])

    def test_a_job_for_another_event_does_not_count(self):
        step = self.STEP.format(os="--os macos", arg="rd-host")
        text = self.workflow('["cmux-tui/**"]', step, condition="github.event_name == 'push'")
        self.assertEqual(self.routed(text), [])

    def test_branch_filters(self):
        document = {"on": {"pull_request": {"branches": ["main"]}}}
        self.assertFalse(admits_pull_request(document, MAC_ONLY_FILES[0]))
        document = {"on": {"pull_request": {"branches-ignore": ["feat-*"]}}}
        self.assertFalse(admits_pull_request(document, MAC_ONLY_FILES[0]))
        self.assertTrue(admits_pull_request({"on": "pull_request"}, MAC_ONLY_FILES[0]))
        self.assertFalse(admits_pull_request({"on": {"push": {}}}, MAC_ONLY_FILES[0]))


if __name__ == "__main__":
    unittest.main()
