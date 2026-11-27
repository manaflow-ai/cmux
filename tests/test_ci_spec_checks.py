#!/usr/bin/env python3
"""scripts/ci/spec_checks.py: the cheap cmux-tui spec and bindings checks on every head that reaches them.

#56203 (dd19a6ecf137) added the control event `client-disconnected-by` and merged with the spec inventory red: the
only per-PR run of the check skipped feat-cmux-next pull requests without `full-ci`. cmux-next-guards.yml's
spec-checks job runs these checks on every pull request head and push whose diff reaches INPUTS; this holds the
table, the route, the base rerun (a red the base has too is not the change's) and the read audit (a check that reads
a file outside INPUTS would skip on a change to that file).
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import spec_checks  # noqa: E402


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                    *args], check=True, capture_output=True)


def repo_with(base: dict[str, str], change: dict[str, str | None]) -> Path:
    """A repository whose HEAD^1 holds BASE's files and HEAD changes CHANGE (None deletes)."""
    repo = Path(tempfile.mkdtemp())
    git(repo, "init", "-q")
    for name, text in base.items():
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "base", "--allow-empty")
    for name, text in change.items():
        if text is None:
            (repo / name).unlink()
        else:
            (repo / name).parent.mkdir(parents=True, exist_ok=True)
            (repo / name).write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "change", "--allow-empty")
    return repo


# A check that is red while `broken` exists, naming the problem it found.
CHECK = "import os, sys\nif os.path.exists('broken'):\n    print('problem: ' + open('broken').read().strip())\n    sys.exit(1)\n"


class TableTests(unittest.TestCase):
    def test_every_cheap_spec_and_bindings_check_is_in_the_table(self):
        argvs = [" ".join(check.argv) for check in spec_checks.CHECKS]
        for wanted in (
            "cmux-tui/scripts/check-spec-inventory.py",
            "cmux-tui/scripts/test_check_spec_inventory.py",
            "cmux-tui/scripts/check-sdk-schema.py",
            "cmux-tui/scripts/test_check_sdk_schema.py",
            "cmux-tui/scripts/check-resource-api-boundary.py",
            "cmux-tui/scripts/test_check_resource_api_boundary.py",
            "cmux-tui/bindings/codegen/generate.py --check",
            "-m unittest discover -s cmux-tui/bindings/codegen/tests",
            "scripts/cmux-next/gen-phone-lane-fields.py --check",
        ):
            self.assertIn(wanted, argvs)
        self.assertEqual(len({check.name for check in spec_checks.CHECKS}), len(spec_checks.CHECKS))
        for check in spec_checks.CHECKS:
            script = check.argv[0] if check.argv[0] != "-m" else None
            if script:
                self.assertTrue((ROOT / script).is_file(), script)

    def test_the_route_reaches_spec_bindings_server_and_the_checks_themselves(self):
        for path in ("cmux-tui/spec/events.md", "cmux-tui/bindings/go/raw/events.go",
                     "cmux-tui/crates/cmux-tui-core/src/server.rs",
                     "cmux-tui/crates/cmux-tui-core/src/server/client_kick.rs",
                     "cmux-tui/crates/cmux-tui/src/config.rs", "cmux-tui/scripts/check-sdk-schema.py",
                     "scripts/ci/spec_checks.py", "tests/test_ci_spec_checks.py",
                     ".github/workflows/cmux-next-guards.yml"):
            self.assertTrue(spec_checks.routed([path]), path)
        for path in ("cmux-tui/crates/acpmux/src/lib.rs", "webviews/src/App.tsx", "docs/x.md", "README.md",
                     "cmux-tui/crates/cmux-tui-core/Cargo.toml"):
            self.assertFalse(spec_checks.routed([path]), path)
        self.assertFalse(spec_checks.routed([]))

    def test_every_check_script_is_an_input(self):
        for check in spec_checks.CHECKS:
            if check.argv[0] != "-m":
                self.assertTrue(spec_checks.routed([check.argv[0]]), check.argv[0])


class JudgeTests(unittest.TestCase):
    def judge(self, repo: Path, base: str | None) -> tuple[int, str]:
        checks = (spec_checks.Check("planted", ("check.py",)),)
        out = Path(tempfile.mkdtemp()) / "out.txt"
        with open(out, "w") as stream:
            rc = spec_checks.judge(repo, checks, base, stream=stream, audit=False)
        return rc, out.read_text()

    def test_a_red_the_change_adds_fails(self):
        repo = repo_with({"check.py": CHECK}, {"broken": "the new event is undeclared\n"})
        rc, out = self.judge(repo, "HEAD^1")
        self.assertEqual(rc, 1, out)
        self.assertIn("this change's own", out)
        self.assertTrue((repo / "broken").exists(), "the merge tree is put back after the base rerun")

    def test_a_red_the_base_has_too_passes_with_a_warning(self):
        repo = repo_with({"check.py": CHECK, "broken": "old red\n"}, {"other.txt": "x\n"})
        rc, out = self.judge(repo, "HEAD^1")
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning", out)
        self.assertIn("red on the base", out)

    def test_a_new_problem_in_a_check_the_base_already_fails_is_the_changes_own(self):
        repo = repo_with({"check.py": CHECK, "broken": "old red\n"}, {"broken": "a different red\n"})
        rc, out = self.judge(repo, "HEAD^1")
        self.assertEqual(rc, 1, out)
        self.assertIn("problem: a different red", out)

    def test_a_check_the_base_lacks_is_judged_on_the_change_alone(self):
        repo = repo_with({}, {"check.py": CHECK, "broken": "red\n"})
        rc, out = self.judge(repo, "HEAD^1")
        self.assertEqual(rc, 1, out)

    def test_a_push_has_no_base_and_a_red_fails(self):
        repo = repo_with({"check.py": CHECK, "broken": "old red\n"}, {})
        rc, out = self.judge(repo, None)
        self.assertEqual(rc, 1, out)

    def test_green_passes(self):
        repo = repo_with({"check.py": CHECK}, {"x.txt": "x\n"})
        self.assertEqual(self.judge(repo, "HEAD^1")[0], 0)


class AuditTests(unittest.TestCase):
    def test_a_read_outside_the_inputs_is_named(self):
        repo = repo_with({
            "cmux-tui/spec/inventory.json": "{}\n",
            "README.md": "x\n",
            "reader.py": "open('cmux-tui/spec/inventory.json').read()\nopen('README.md').read()\n",
        }, {})
        checks = (spec_checks.Check("reader", ("reader.py",)),)

        def judge(changed):
            out = Path(tempfile.mkdtemp()) / "out.txt"
            with open(out, "w") as stream:
                rc = spec_checks.judge(repo, checks, None, stream=stream, audit=True, changed=changed)
            return rc, out.read_text()

        # A change that edits a check's code (where a new read comes from) fails on it.
        rc, text = judge(["reader.py"])
        self.assertEqual(rc, 1, text)
        self.assertIn("::error title=spec checks read audit", text)
        self.assertIn("  README.md", text)
        self.assertIn("  reader.py", text)  # the check's own script is outside INPUTS here too
        self.assertNotIn("  cmux-tui/spec/inventory.json", text)
        # Any other change (or a push, with no diff) only warns: the read is not its doing.
        for changed in (None, ["cmux-tui/spec/inventory.json"]):
            rc, text = judge(changed)
            self.assertEqual(rc, 0, text)
            self.assertIn("::warning title=spec checks read audit", text)

    def test_a_check_runs_as_python3_script_would(self):
        # The script's folder leads sys.path (sibling imports), PYTHONPATH-style folders come from `path`.
        repo = repo_with({
            "tool/helper.py": "VALUE = 7\n",
            "lib/extra.py": "OTHER = 5\n",
            "tool/run.py": "import helper, extra, sys\nsys.exit(0 if helper.VALUE + extra.OTHER == 12 else 1)\n",
        }, {})
        checks = (spec_checks.Check("imports", ("tool/run.py",), path=("lib",)),)
        out = Path(tempfile.mkdtemp()) / "out.txt"
        with open(out, "w") as stream:
            rc = spec_checks.judge(repo, checks, None, stream=stream, audit=False)
        self.assertEqual(rc, 0, out.read_text())


if __name__ == "__main__":
    os.environ.pop("GITHUB_ACTIONS", None)
    unittest.main()
