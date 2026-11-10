#!/usr/bin/env python3
"""Every repository variable a runs-on reads declares its fallback in .github/single-host-fallbacks.json.

Leo's rule (2026-10-24): no job waits on one reserved machine; each single-host label, and each
repository variable a runs-on reads, says what takes the job instead and after how many minutes.
The declaration used to live only in the build-fleet repository, whose runner label policy test
reads this repository's workflows live. So a pull request here that added a runs-on variable
merged green and turned that repository red afterwards: cmux#40221 added vars.CI_NIGHTLY_MINI_SIGNER
and vars.CI_NIGHTLY_MINI_PUBLISHER to nightly.yml, and only the policy test there caught it, after
the merge. The declaration now lives here and the build-fleet test reads this file. The pre-push hook
refuses a push that adds an undeclared name; CI only warns (no new CI gate, Lawrence 2026-10-23).
This test is not in CI (tests/test-execution.d/ci.toml: manual); run it yourself.

The scan is scripts/cmux-next/check-single-host-fallbacks.py (strict by default; CI passes --advisory, which
only warns; the pre-push gate runs it strictly). What is read, for every workflow under .github/workflows:
- each `runs-on:` line, as the build-fleet test reads it (every `vars.NAME` on the line, and every
  single-host label: a controller label or one starting with a `single_host_prefixes` entry, which
  `labels` must declare);
- each job's parsed runs-on (a block list, a `group`/`labels` mapping), `vars.NAME`, `vars['NAME']`
  and `fromJSON(vars.NAME)` forms alike;
- the matrix values a runs-on reads through `matrix.KEY` (axes and `include` entries; a matrix that is
  itself an expression is read whole);
- the `with:` values a caller passes to a local reusable workflow's input that reaches a runs-on there.

The declaration itself must promise a bounded fallback: the same schema checks as the build-fleet
test (fallback_policy in its tests/test_runner_label_policy.py), so a declaration it would refuse
fails here first. Its nightly scan (nightly_terminal_labels, nightly_job_outputs) stays there.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "check-single-host-fallbacks.py"
_spec = importlib.util.spec_from_file_location("check_single_host_fallbacks", SCRIPT)
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)

WORKFLOWS = ROOT / ".github" / "workflows"
DECLARATION = ROOT / ".github" / "single-host-fallbacks.json"
declaration_faults = checker.declaration_faults
undeclared = checker.undeclared


def references(workflow_dirs):
    reads = checker.references(workflow_dirs)
    return reads.variables, reads.lines, reads.unreadable


def load_declaration() -> dict:
    return json.loads(DECLARATION.read_text(encoding="utf-8"))


class SingleHostFallbacks(unittest.TestCase):
    def scan(self, files: dict[str, str], policy: dict | None = None) -> list[str]:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / ".github" / "workflows"
            directory.mkdir(parents=True)
            for name, text in files.items():
                (directory / name).write_text(text, encoding="utf-8")
            return undeclared([directory], policy or load_declaration())

    def assert_names(self, findings: list[str], name: str) -> None:
        self.assertTrue([f for f in findings if f.startswith(f"vars.{name} ")],
                        f"vars.{name} was not reported: {findings}")

    def test_the_declaration_promises_a_bounded_fallback(self) -> None:
        self.assertEqual(declaration_faults(load_declaration()), [])

    def test_every_runs_on_variable_and_single_host_label_is_declared(self) -> None:
        bad = undeclared([WORKFLOWS], load_declaration())
        self.assertEqual(bad, [], "runs-on with no declared single-host fallback:\n" + "\n".join(bad))

    def test_the_real_scan_is_not_vacuous(self) -> None:
        found, lines, bad = references([WORKFLOWS])
        self.assertEqual(bad, [])
        self.assertGreater(len(lines), 100, "the scan read almost no runs-on lines")
        self.assertTrue({"RUNNER_POOLS", "LINUX_RUNNER", "CI_NIGHTLY_MINI"} <= set(found), sorted(found))

    def test_a_new_runs_on_variable_fails_naming_it(self) -> None:
        findings = self.scan({"x.yml": "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n"})
        self.assert_names(findings, "NEW_X")
        self.assertIn("x.yml:3", findings[0])
        located = checker.findings([Path("/nonexistent")], load_declaration())
        self.assertTrue(located and "missing" in located[0]["message"])

    def test_a_declared_variable_passes(self) -> None:
        policy = load_declaration()
        policy["variables"]["NEW_X"] = {"fallback": "Blacksmith macOS after the owned-pool grace", "after_minutes": 5}
        self.assertEqual(self.scan({"x.yml": "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n"}, policy), [])

    def test_a_comparison_or_fromjson_read_counts_as_a_read(self) -> None:
        for runs_on in ("${{ vars.NEW_X == 'macos-26' && 'macos-26' || fromJSON(vars.RUNNER_POOLS).macos_26 }}",
                        "${{ fromJSON(vars.NEW_X || '{}').macos || 'blacksmith-6vcpu-macos-26' }}",
                        "${{ vars['NEW_X'] || 'blacksmith-6vcpu-macos-26' }}",
                        "${{ vars.new_x || 'blacksmith-6vcpu-macos-26' }}"):
            with self.subTest(runs_on=runs_on):
                self.assert_names(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {runs_on}\n"}), "NEW_X")

    def test_a_block_or_group_runs_on_is_read(self) -> None:
        for runs_on in ("\n      - self-hosted\n      - ${{ vars.NEW_X }}",
                        "\n      group: ${{ vars.NEW_X }}\n      labels: [x]",
                        " [\"${{ vars.NEW_X }}\"]"):
            with self.subTest(runs_on=runs_on):
                self.assert_names(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on:{runs_on}\n"}), "NEW_X")

    def test_a_matrix_expanded_runner_is_read(self) -> None:
        axis = ("jobs:\n  a:\n    strategy:\n      matrix:\n        runner: ['${{ vars.NEW_X }}', "
                "blacksmith-4vcpu-ubuntu-2404]\n    runs-on: ${{ matrix.runner }}\n")
        include = ("jobs:\n  a:\n    strategy:\n      matrix:\n        include:\n"
                   "          - os: mac\n            runner: ${{ vars.NEW_X }}\n"
                   "            label: ${{ vars.NOT_A_RUNNER }}\n    runs-on: ${{ matrix.runner }}\n")
        dynamic = ("jobs:\n  a:\n    strategy:\n      matrix: ${{ fromJSON(vars.NEW_X) }}\n"
                   "    runs-on: ${{ matrix.runner }}\n")
        for text in (axis, include, dynamic):
            with self.subTest(text=text):
                self.assert_names(self.scan({"x.yml": text}), "NEW_X")
        # A matrix key the runs-on never reads is not a runner.
        self.assertFalse([f for f in self.scan({"x.yml": include}) if "NOT_A_RUNNER" in f])

    def test_a_reusable_workflow_input_that_reaches_runs_on_is_read(self) -> None:
        callee = ("on:\n  workflow_call:\n    inputs:\n      runner: {type: string}\n      note: {type: string}\n"
                  "jobs:\n  a:\n    runs-on: ${{ inputs.runner || 'blacksmith-4vcpu-ubuntu-2404' }}\n")
        middle = ("on:\n  workflow_call:\n    inputs:\n      box: {type: string}\n"
                  "jobs:\n  b:\n    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ inputs.box }}\n")
        caller = ("jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                  "      runner: ${{ vars.NEW_X }}\n      note: ${{ vars.NOT_A_RUNNER }}\n"
                  "  d:\n    uses: ./.github/workflows/middle.yml\n    with:\n      box: ${{ vars.NEW_Y }}\n")
        findings = self.scan({"callee.yml": callee, "middle.yml": middle, "caller.yml": caller})
        self.assert_names(findings, "NEW_X")
        self.assert_names(findings, "NEW_Y")
        self.assertFalse([f for f in findings if "NOT_A_RUNNER" in f], findings)

    def test_a_variable_outside_runs_on_is_not_this_policys_business(self) -> None:
        text = "jobs:\n  a:\n    runs-on: blacksmith-4vcpu-ubuntu-2404\n    env:\n      X: ${{ vars.NEW_X }}\n"
        self.assertEqual(self.scan({"x.yml": text}), [])

    def test_an_undeclared_single_host_label_fails(self) -> None:
        policy = load_declaration()
        prefix = policy["single_host_prefixes"][0]
        findings = self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {prefix}made-up\n"}, policy)
        self.assertTrue([f for f in findings if f"{prefix}made-up" in f], findings)
        policy["labels"][f"{prefix}made-up"] = {"fallback": "Blacksmith macOS", "after_minutes": 5}
        self.assertEqual(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {prefix}made-up\n"}, policy), [])

    def test_a_declaration_that_promises_nothing_is_refused(self) -> None:
        for entry in ({"fallback": "", "after_minutes": 5}, {"fallback": "x"}, {"fallback": "x", "after_minutes": 0},
                      {"fallback": "x", "after_minutes": True}, {"fallback": "x", "after_minutes": "5"}, "x"):
            with self.subTest(entry=entry):
                policy = load_declaration()
                policy["variables"]["NEW_X"] = entry
                self.assertTrue([f for f in declaration_faults(policy) if f.startswith("vars.NEW_X:")])
        policy = load_declaration()
        terminal = next(iter(policy["nightly_terminal_labels"]))
        policy["nightly_terminal_labels"][terminal]["after_minutes"] = 31
        self.assertTrue([f for f in declaration_faults(policy) if f.startswith(f"{terminal}:")])

    def repo_with(self, tmp: str, workflow: str) -> Path:
        """A copy of this repository's .github with one more workflow in it."""
        root = Path(tmp)
        shutil.copytree(ROOT / ".github" / "workflows", root / ".github" / "workflows")
        shutil.copy(DECLARATION, root / ".github" / "single-host-fallbacks.json")
        (root / ".github" / "workflows" / "zz-new-x.yml").write_text(workflow, encoding="utf-8")
        return root

    def run_cli(self, *argv: str, env: dict[str, str] | None = None) -> tuple[int, str]:
        out = io.StringIO()
        with unittest.mock.patch.dict(os.environ, env or {}), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(io.StringIO()):
            code = checker.main(list(argv))
        return code, out.getvalue()

    def test_strict_mode_exits_non_zero_naming_the_variable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo_with(tmp, "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n")
            code, out = self.run_cli("--root", str(root))
        self.assertEqual(code, 1)
        self.assertIn("vars.NEW_X is read by a runs-on", out)

    def test_advisory_mode_warns_and_exits_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo_with(tmp, "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n")
            summary = Path(tmp) / "summary.md"
            # GITHUB_ACTIONS does not choose the mode; only the flag does.
            code, out = self.run_cli("--root", str(root), "--advisory",
                                     env={"GITHUB_STEP_SUMMARY": str(summary), "GITHUB_ACTIONS": "false"})
            self.assertEqual(code, 0)
            self.assertIn("::warning file=.github/workflows/zz-new-x.yml,line=3,title=Single-host fallback::"
                          "vars.NEW_X is read by a runs-on", out)
            self.assertIn("`vars.NEW_X`", summary.read_text(encoding="utf-8"))
            strict, _ = self.run_cli("--root", str(root), env={"GITHUB_ACTIONS": "true"})
            self.assertEqual(strict, 1, "GITHUB_ACTIONS alone must not make the scan advisory")

    def test_advisory_mode_exits_zero_when_the_scan_cannot_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github").mkdir()
            (root / ".github" / "single-host-fallbacks.json").write_text("{not json", encoding="utf-8")
            code, out = self.run_cli("--root", str(root), "--advisory")
        self.assertEqual(code, 0)
        self.assertIn("could not run", out)

    def test_json_mode_keys_each_finding(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo_with(tmp, "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n")
            code, out = self.run_cli("--root", str(root), "--json")
        self.assertEqual(code, 0)
        self.assertEqual([f["key"] for f in json.loads(out)], ["vars.NEW_X"])

    def test_this_checkout_passes_in_strict_mode(self) -> None:
        code, out = self.run_cli()
        self.assertEqual(code, 0, out)

    def test_a_missing_workflow_directory_is_reported(self) -> None:
        self.assertTrue(undeclared([ROOT / "no-such-dir" / "workflows"], load_declaration()))


if __name__ == "__main__":
    sys.exit(unittest.main())
