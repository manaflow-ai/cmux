#!/usr/bin/env python3
"""A feat-cmux-next push that changes cmux-rd-host runs its macOS fmt, clippy and tests on the tip.

cmux-rd-host's pull request jobs (rust-workspaces.yml) run on Linux, so its code behind
#[cfg(target_os = "macos")] (src/mac/) was never linted by one: on 2026-11-15 `cmux-tui-rust-check.sh rd-host` on
macOS was red on feat-cmux-next with two dead_code errors in src/hybrid.rs (#43668) and no job had seen them. The
macOS check ran on pull requests until 2026-11-22, when it moved to the tip (once per window, base-coalesce.yml): it
had been red 0 times in 70 pull request runs in 24 h. This test fails unless some workflow both starts on a
feat-cmux-next push that changes a macOS-only file of the crate and runs `cmux-tui-rust-check.sh` in mode `rd-host`
with `--os macos` (fleet-rd-host-macos.yml).

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


EVENT = "push"


def admits_push(document, path: str, base: str = BASE) -> bool:
    """Whether a push to `base` that changes only `path` starts this workflow."""
    events = detector.triggers(document)
    if EVENT not in events:
        return False
    config = events.get(EVENT) or {}
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
    """The workflows (repo paths) whose feat-cmux-next push run for a change to `path` runs the macOS rd-host check."""
    repo = detector.Repo(root)  # steps_for reads only its root (to follow local reusable workflows)
    found = []
    for workflow in sorted((root / ".github" / "workflows").glob("*.y*ml")):
        document = detector.load_quietly(workflow, None)
        if not isinstance(document, dict) or not admits_push(document, path):
            continue
        if any(runs_rd_host_on_macos(run) for run, _, _ in detector.steps_for(repo, document, EVENT)):
            found.append(workflow.relative_to(root).as_posix())
    return found


class RdHostMacosRoute(unittest.TestCase):
    def test_a_mac_only_change_runs_the_macos_rd_host_check(self):
        for path in MAC_ONLY_FILES:
            with self.subTest(path=path):
                self.assertNotEqual(
                    routes(ROOT, path), [],
                    f"no workflow starts on a feat-cmux-next push of {path} and runs `cmux-tui-rust-check.sh rd-host` "
                    "with `--os macos`: its macOS-only code lands and stays unlinted (#43668)")


class Matcher(unittest.TestCase):
    STEP = "cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref X \\\n  {os} --arg {arg}"

    def write(self, root: Path, text: str) -> None:
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "w.yml").write_text(textwrap.dedent(text))

    def workflow(self, paths: str, run: str, condition: str = "true") -> str:
        return f"""
            on:
              push:
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
        text = self.workflow('["cmux-tui/**"]', step, condition="github.event_name == 'pull_request'")
        self.assertEqual(self.routed(text), [])

    def test_branch_filters(self):
        document = {"on": {"push": {"branches": ["main"]}}}
        self.assertFalse(admits_push(document, MAC_ONLY_FILES[0]))
        document = {"on": {"push": {"branches-ignore": ["feat-*"]}}}
        self.assertFalse(admits_push(document, MAC_ONLY_FILES[0]))
        self.assertTrue(admits_push({"on": "push"}, MAC_ONLY_FILES[0]))
        self.assertFalse(admits_push({"on": {"pull_request": {}}}, MAC_ONLY_FILES[0]))


if __name__ == "__main__":
    unittest.main()
