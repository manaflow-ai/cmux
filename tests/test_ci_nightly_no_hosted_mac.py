#!/usr/bin/env python3
"""No nightly, promote or DEV publisher path can resolve to a GitHub-hosted Mac.

Leo, 2026-10-27: "HOW MANY TIMES DO I HAVE TO SAY / THE GITHUB HOSTED MACS /
ARE THE SLOWEST THINGS / THEY PREVIOUSLY WREN'T EVEN UNDER CONSIDERATINO".
The routing order is Linux, then owned fleet minis, then Blacksmith macOS last.

This reads every nightly, notarization and DEV daily workflow (by name, not a
job list) and refuses a hosted macOS label (macos-26, macos-15, macos-latest,
macos-15-xlarge, ...) anywhere in their code: runs-on, matrix values, runner
inputs, defaults and inline picks. Blacksmith (blacksmith-*-macos-*) and other
provider labels are not hosted. The one exemption is the fork branch,
`github.repository_owner != 'manaflow-ai' && 'macos-NN'`, which only evaluates
in a fork, where no fleet or Blacksmith exists. The scripts whose output a
runs-on reads (runner pickers) are held to the same rule.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

HOSTED_MAC = re.compile(r"(?<![\w.-])macos-(?:latest|\d+)(?:-[a-z0-9]+)*(?![\w.-])")
FORK_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && 'macos-(?:latest|\d+)'")
# A comparison against a label (matrix.pool == 'macos-15') reads a route, it does not pick one.
COMPARISON = re.compile(r"== 'macos-(?:latest|\d+)'")
NEEDS_OUTPUT = re.compile(r"needs\.([\w-]+)\.outputs\.\w+")
SCRIPT = re.compile(r"scripts/[\w/.-]+\.(?:py|sh)")


def scoped_workflows() -> list[Path]:
    paths = set(WORKFLOWS.glob("*nightly*.yml")) | set(WORKFLOWS.glob("*notarization*.yml"))
    paths |= set(WORKFLOWS.glob("cmux-next-dev-daily*.yml"))
    return sorted(paths)


def hosted_mentions(path: Path, *, comment: str) -> list[str]:
    hits = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.lstrip().startswith(comment):
            continue
        code = COMPARISON.sub("", FORK_BRANCH.sub("", line.split(f" {comment} ", 1)[0]))
        if HOSTED_MAC.search(code):
            hits.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
    return hits


def picker_scripts() -> set[Path]:
    """Scripts run by a job whose outputs some runs-on in a scoped workflow reads."""
    scripts = set()
    for path in scoped_workflows():
        jobs = (yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}).get("jobs") or {}
        for job in jobs.values():
            for picker in NEEDS_OUTPUT.findall(str(job.get("runs-on", ""))):
                for script in SCRIPT.findall(str(jobs.get(picker, {}).get("steps", ""))):
                    if (ROOT / script).is_file():
                        scripts.add(ROOT / script)
    return scripts


class NoHostedMacInNightlies(unittest.TestCase):
    def test_the_scoped_workflows_are_discovered(self) -> None:
        names = {path.name for path in scoped_workflows()}
        for required in ("nightly.yml", "auto-resume-nightly-notarization.yml", "cmux-next-dev-daily.yml"):
            self.assertIn(required, names)

    def test_no_workflow_names_a_hosted_mac_past_the_fork_branch(self) -> None:
        hits = [hit for path in scoped_workflows() for hit in hosted_mentions(path, comment="#")]
        self.assertEqual(hits, [], "use the fleet, then vars.MACOS_RUNNER_* || 'blacksmith-6vcpu-macos-NN'")

    def test_no_runner_picker_returns_a_hosted_mac(self) -> None:
        scripts = picker_scripts()
        self.assertIn(ROOT / "scripts/ci/nightly_sign_runner.py", scripts)
        hits = []
        for script in sorted(scripts):
            hits += hosted_mentions(script, comment="#")
            text = script.read_text(encoding="utf-8")
            if re.search(r"\bHOSTED\b", text):
                hits.append(f"{script.relative_to(ROOT)}: reads a HOSTED label")
        self.assertEqual(hits, [])

    def test_every_runner_variable_the_path_reads_refuses_a_hosted_mac(self) -> None:
        # A variable holding macos-26 would route around the literal check above, so the
        # repository-variable report (runner_label_policy) flags it as drift.
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import runner_label_policy as policy

        read = set()
        for path in scoped_workflows():
            for line in path.read_text(encoding="utf-8").splitlines():
                if re.search(r"runs-on:|_runner:|^\s+- \$\{\{", line):
                    read |= set(re.findall(r"vars\.([A-Z0-9_]*RUNNER[A-Z0-9_]*)", line))
        self.assertIn("NIGHTLY_NEXT_TRAIN_RUNNER", read)
        self.assertEqual(read - policy.NO_HOSTED_MAC_VARIABLES, set(), "add to NO_HOSTED_MAC_VARIABLES")
        for name in sorted(read):
            for label in ("macos-26", "macos-15", "macos-latest", "macos-15-xlarge"):
                with self.subTest(variable=name, label=label):
                    self.assertTrue(policy.drifted_runner_variables({name: label}))
            self.assertEqual(policy.drifted_runner_variables({name: ""}), [])

    def test_the_sign_picker_answers_blacksmith_even_when_every_label_is_stalled(self) -> None:
        path = ROOT / "scripts/ci/nightly_sign_runner.py"
        sys.path.insert(0, str(path.parent))
        spec = importlib.util.spec_from_file_location("nightly_sign_runner_no_hosted", path)
        picker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(picker)
        now = dt.datetime(2026, 10, 27, 3, 0, tzinfo=dt.timezone.utc)
        stalled = {
            "generated_at": now.isoformat().replace("+00:00", "Z"),
            "pools": {label: {"oldest_queued_minutes": 240, "queued": 50}
                      for label in ("blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26")},
        }
        for variable in ("", "blacksmith-12vcpu-macos-26", "macos-26"):
            for snapshot in (None, stalled):
                with self.subTest(variable=variable, snapshot=bool(snapshot)):
                    label = picker.pick(variable, snapshot, now)[0]
                    self.assertIsNone(HOSTED_MAC.fullmatch(label), label)
                    self.assertTrue(label.startswith("blacksmith-"), label)


if __name__ == "__main__":
    unittest.main()
