#!/usr/bin/env python3
"""A job that can land on an owned Mac mini calls no sudo.

An owned mini's runner user has no passwordless sudo: `sudo` there asks for a password and fails (`sudo -n`
fails at once). relay-tls.yml's system-keychain job read the macos_15 pool, which a picker can point at an owned
label, and went red at `sudo xcode-select` before any test ran (jobs 139913440688 and 139893245346 on
glaeda-std-xcode-26.6). A job that needs root (a System keychain trust root, a new macOS user) needs a one-job
machine anyway, so it names a literal ephemeral label and marks its runs-on line `ephemeral-required`; a job that
only needs another Xcode sets DEVELOPER_DIR instead of `sudo xcode-select`.

A job can reach an owned Mac when its runs-on names an owned Mac label or a variable or pool that can hold one
(OWNED_MAC_ROUTE). For each such job this counts `sudo` in its steps' `run` text and in every repository file a
step runs by path (`python3 tests/x.py`, `./scripts/y.sh`). ALLOWED lists the jobs allowed to, each with the exact
count and why; the test fails on a job not listed, a count above its entry (a new call) and a count below it (lower
the entry, so the list only shrinks). A runs-on that only a picker job's output decides (`needs.X.outputs.Y`,
`matrix.runner`) is not read here.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
# Owned Mac labels and every variable or pool that can name one: the cmux-mac label, glaeda's labels, the overflow
# and per-image Mac variables, and the macOS RUNNER_POOLS pools, which a picker may point at an owned label.
OWNED_MAC_ROUTE = re.compile(r"'cmux-mac'|'glaeda-|vars\.CI_OVERFLOW_MAC\b|vars\.MACOS_RUNNER\w*|RUNNER_POOLS\)\.macos\w*")
SUDO = re.compile(r"(?<![\w./-])sudo(?![\w-])")
# A repository file a step runs by path: `python3 tests/x.py`, `bash scripts/y.sh`, `./scripts/z.sh`.
RUN_PATH = re.compile(r"(?<![\w./$-])(?:\./)?((?:scripts|tests|tools|Native|cmux-tui|webviews)/[\w./-]+\.(?:py|sh|ts|js|mjs|rb))\b")

ALLOWED: dict[tuple[str, str], tuple[int, str]] = {
    ("cmux-tui-artifacts.yml", "macos-cross-runtime-x86_64"): (
        1, "safe: `sudo -n` installs Rosetta only when x86_64 code cannot run, which an owned mini never hits"),
    ("macos-cross-parity.yml", "runtime-x86_64"): (
        1, "safe: `sudo -n` installs Rosetta only when x86_64 code cannot run, which an owned mini never hits"),
    ("ios-streamed-validate.yml", "validate"): (
        5, "safe: every sudo mkdir/ln falls back to the same call without sudo"),
}


def scripts_run_by(text: str) -> list[Path]:
    found = []
    for match in RUN_PATH.finditer(text):
        path = ROOT / match.group(1)
        if path.is_file() and path not in found:
            found.append(path)
    return found


def sudo_count(text: str) -> int:
    return sum(len(SUDO.findall(line)) for line in text.splitlines() if not line.lstrip().startswith("#"))


def reaches_owned_mac(job: dict) -> bool:
    runs_on = job.get("runs-on")
    return bool(OWNED_MAC_ROUTE.search(runs_on if isinstance(runs_on, str) else json.dumps(runs_on)))


def job_sudo_count(job: dict) -> int:
    total = 0
    for step in job.get("steps") or []:
        run = step.get("run") or ""
        total += sudo_count(run)
        for path in scripts_run_by(run):
            total += sudo_count(path.read_text(encoding="utf-8", errors="replace"))
    return total


def owned_mac_sudo() -> dict[tuple[str, str], int]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = workflow_jobs.document(path)
        for job_id, job in workflow_jobs.jobs(document).items():
            if not isinstance(job, dict) or not reaches_owned_mac(job):
                continue
            count = job_sudo_count(job)
            if count:
                found[(path.name, job_id)] = count
    return found


class OwnedMacJobsNoSudo(unittest.TestCase):
    def test_no_new_sudo_on_a_job_that_can_reach_an_owned_mac(self) -> None:
        errors = []
        found = owned_mac_sudo()
        for key, count in sorted(found.items()):
            allowed = ALLOWED.get(key)
            if allowed is None:
                errors.append(f"{key[0]} {key[1]}: {count} sudo call(s) on a job that can land on an owned Mac, where"
                              " sudo fails: name a literal one-job label with `# ephemeral-required: why`, or set"
                              " DEVELOPER_DIR instead of `sudo xcode-select`")
            elif count > allowed[0]:
                errors.append(f"{key[0]} {key[1]}: {count} sudo calls, ALLOWED says {allowed[0]}: a new call")
            elif count < allowed[0]:
                errors.append(f"{key[0]} {key[1]}: {count} sudo calls, ALLOWED says {allowed[0]}: lower the entry")
        for key in sorted(set(ALLOWED) - set(found)):
            errors.append(f"{key[0]} {key[1]}: ALLOWED entry matches nothing: remove it")
        for key, (_, reason) in ALLOWED.items():
            if not reason.strip():
                errors.append(f"{key[0]} {key[1]}: ALLOWED entry has no reason")
        self.assertEqual(errors, [], "\n".join(errors))

    def test_relay_tls_system_keychain_is_counted_when_it_reads_a_mac_pool(self) -> None:
        # The job that went red: its runs-on back on the pool must fail this test (the script it runs calls sudo too).
        document = workflow_jobs.document(WORKFLOWS / "relay-tls.yml")
        job = dict(workflow_jobs.jobs(document)["system-keychain"])
        self.assertFalse(reaches_owned_mac(job), "system-keychain must name a one-job Mac label")
        job["runs-on"] = "${{ fromJSON(vars.RUNNER_POOLS).macos_15 }}"
        self.assertTrue(reaches_owned_mac(job))
        self.assertGreater(job_sudo_count(job), 0, "the keychain script's `sudo -n security` calls must count")
        job["steps"] = [{"run": "sudo xcode-select -s /Applications/Xcode_16.2.app"}]
        self.assertEqual(job_sudo_count(job), 1)

    def test_route_patterns(self) -> None:
        for runs_on in ("${{ vars.CI_OVERFLOW_MAC || 'cmux-mac' }}", "${{ fromJSON(vars.RUNNER_POOLS).macos_26 }}",
                        "${{ vars.MACOS_RUNNER_15 }}", "glaeda-std-xcode-26.6".join("''")):
            self.assertTrue(reaches_owned_mac({"runs-on": runs_on}), runs_on)
        for runs_on in ("${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-15' }}",
                        "${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}"):
            self.assertFalse(reaches_owned_mac({"runs-on": runs_on}), runs_on)
        self.assertEqual(sudo_count("sudo -n a\n# sudo b\nsudoers\nvisudo\n/usr/bin/sudo c"), 1)


if __name__ == "__main__":
    unittest.main()
