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
import subprocess
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

    CALLEE = ("on:\n  workflow_call:\n    inputs:\n      runner: {type: string}\n"
              "jobs:\n  a:\n    runs-on: ${{ %s }}\n")

    def test_codex_repro_a_caller_matrix_reaches_runs_on_through_an_input(self) -> None:
        """Codex on #40799: a caller's matrix value, passed as with.runner, reached the callee's runs-on through
        inputs.runner; the scan read `${{ matrix.runner }}` in the caller and never expanded the caller's matrix."""
        caller = ("jobs:\n  c:\n    strategy:\n      matrix:\n        runner: ['${{ vars.NEW_X }}', ubuntu-24.04]\n"
                  "    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ matrix.runner }}\n")
        self.assert_names(self.scan({"callee.yml": self.CALLEE % "inputs.runner", "caller.yml": caller}), "NEW_X")

    def test_codex_repro_b_bracket_forms_are_read(self) -> None:
        """Codex on #40799: `matrix['runner']` and `inputs['runner']` are the same reads as the dot forms; the scan
        matched only `matrix.KEY` and `inputs.KEY`."""
        matrix = ("jobs:\n  a:\n    strategy:\n      matrix:\n        runner: ['${{ vars.NEW_X }}']\n"
                  "    runs-on: ${{ matrix['runner'] }}\n")
        self.assert_names(self.scan({"x.yml": matrix}), "NEW_X")
        caller = "jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ vars.NEW_Y }}\n"
        self.assert_names(self.scan({"callee.yml": self.CALLEE % "inputs['runner']", "caller.yml": caller}), "NEW_Y")

    def test_codex_repro_a_caller_fromjson_matrix_reaches_runs_on_through_an_input(self) -> None:
        """Codex on #40894: a caller whose matrix is `${{ fromJSON(vars.NEW_X) }}` passes matrix.runner to a callee's
        inputs.runner, which its runs-on reads. The scan read the matrix only when the callee's own runs-on held an
        unexpanded matrix, never the caller's, so the variable the runner comes from gave no finding."""
        caller = ("jobs:\n  c:\n    strategy:\n      matrix: ${{ fromJSON(vars.NEW_X) }}\n"
                  "    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ matrix.runner }}\n")
        self.assert_names(self.scan({"callee.yml": self.CALLEE % "inputs.runner", "caller.yml": caller}), "NEW_X")
        bracket = caller.replace("matrix.runner", "matrix['runner']").replace("vars.NEW_X", 'vars["NEW_X"]')
        self.assert_names(self.scan({"callee.yml": self.CALLEE % "inputs['runner']", "caller.yml": bracket}), "NEW_X")

    def test_a_variable_in_a_condition_inside_a_matrix_value_is_read(self) -> None:
        """Codex on #40894: a matrix value `${{ vars.NEW_X == 'big' && 'a' || 'b' }}` resolves to its literal branches,
        so the variable its condition reads was dropped with the condition, in the job's own matrix and in a caller's."""
        value = "${{ vars.NEW_X == 'big' && 'blacksmith-8vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}"
        own = (f"jobs:\n  a:\n    strategy:\n      matrix:\n        include:\n          - runner: \"{value}\"\n"
               "    runs-on: ${{ matrix.runner }}\n")
        self.assert_names(self.scan({"x.yml": own}), "NEW_X")
        caller = (f"jobs:\n  c:\n    strategy:\n      matrix:\n        runner: [\"{value}\"]\n"
                  "    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ matrix.runner }}\n")
        self.assert_names(self.scan({"callee.yml": self.CALLEE % "inputs.runner", "caller.yml": caller}), "NEW_X")
        # A caller's input the callee reads only in a condition still reaches its runs-on.
        callee = ("on:\n  workflow_call:\n    inputs:\n      big: {type: string}\n"
                  "jobs:\n  a:\n    runs-on: ${{ inputs.big == 'yes' && 'blacksmith-8vcpu-ubuntu-2404' || "
                  "'blacksmith-4vcpu-ubuntu-2404' }}\n")
        caller = "jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n      big: ${{ vars.NEW_Y }}\n"
        self.assert_names(self.scan({"callee.yml": callee, "caller.yml": caller}), "NEW_Y")

    DEFAULTED = ("on:\n  workflow_call:\n    inputs:\n%s"
                 "jobs:\n  a:\n    runs-on: ${{ inputs.runner }}\n")

    def test_codex_repro_an_input_default_is_traced_to_the_callers(self) -> None:
        """Codex on #40979: `runner` defaults to `${{ inputs.fallback_runner }}` and a caller passes only
        `fallback_runner: ${{ vars.NEW_X }}`. The default was scanned as text, never traced, so no finding."""
        callee = self.DEFAULTED % ("      runner: {type: string, default: '${{ inputs.fallback_runner }}'}\n"
                                   "      fallback_runner: {type: string}\n")
        caller = ("jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                  "      fallback_runner: ${{ vars.NEW_X }}\n")
        self.assert_names(self.scan({"callee.yml": callee, "caller.yml": caller}), "NEW_X")

    def test_a_two_hop_default_chain_is_traced(self) -> None:
        callee = self.DEFAULTED % ("      runner: {type: string, default: '${{ inputs.middle }}'}\n"
                                   "      middle: {type: string, default: \"${{ inputs['base'] }}\"}\n"
                                   "      base: {type: string}\n")
        caller = "jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n      base: ${{ vars.NEW_Y }}\n"
        self.assert_names(self.scan({"callee.yml": callee, "caller.yml": caller}), "NEW_Y")

    def test_a_default_that_refers_to_itself_refuses(self) -> None:
        """A default that loops (directly or through callers) has no end to trace to: the scan cannot verify what the
        runs-on reads, so it is a finding, never a silent pass."""
        callee = self.DEFAULTED % "      runner: {type: string, default: '${{ inputs.runner }}'}\n"
        caller = "jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n"
        findings = self.scan({"callee.yml": callee, "caller.yml": caller})
        self.assertTrue([f for f in findings if "cannot be verified" in f], findings)

    # Codex on #41015: `runner` and `fallback` default to each other. Caller A passes runner (and a fallback it never
    # uses), caller B passes fallback. Each chain is finite; read through one scope for every caller, B's runner
    # reached A's unused fallback and A's missing fallback looped back to runner.
    PAIR = DEFAULTED % ("      runner: {type: string, default: '${{ inputs.fallback }}'}\n"
                        "      fallback: {type: string, default: '${{ inputs.runner }}'}\n")
    PAIR_CALLERS = ("jobs:\n  a:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                    "      runner: ${{ vars.A_RUNNER }}\n      fallback: ${{ vars.A_FALLBACK }}\n"
                    "  b:\n    uses: ./.github/workflows/callee.yml\n    with:\n      fallback: ${{ vars.B_FALLBACK }}\n")

    def resolve_callee(self, files: dict[str, str]):
        wj = checker.load_workflow_jobs()
        workflows = wj.Workflows({name: wj.document(text) for name, text in files.items()})
        return wj, workflows, wj.resolve(workflows.documents["callee.yml"]["jobs"]["a"], "a", "callee.yml", workflows)

    def test_codex_repro_two_callers_whose_defaults_name_each_other_resolve_per_caller(self) -> None:
        for callers in (self.PAIR_CALLERS, self.PAIR_CALLERS.replace("      fallback: ${{ vars.A_FALLBACK }}\n", "")):
            with self.subTest(a_passes_fallback="A_FALLBACK" in callers):
                _, _, resolved = self.resolve_callee({"callee.yml": self.PAIR, "caller.yml": callers})
                self.assertEqual(resolved.unverifiable, frozenset())
                self.assertEqual({r.name for r in resolved.vars_read if r.field == "runs-on"},
                                 {"A_RUNNER", "B_FALLBACK"})
                self.assertEqual((resolved.runs_on, resolved.runs_on_unresolved),
                                 (set(), {"vars.A_RUNNER", "vars.B_FALLBACK"}))

    def test_one_callers_chain_that_loops_is_still_unverifiable(self) -> None:
        """Caller C passes neither input: its runner is its fallback is its runner. Only C's chain loops."""
        callers = self.PAIR_CALLERS + "  c:\n    uses: ./.github/workflows/callee.yml\n"
        _, _, resolved = self.resolve_callee({"callee.yml": self.PAIR, "caller.yml": callers})
        self.assertTrue(resolved.unverifiable)
        self.assertEqual({u.reason for u in resolved.unverifiable}, {"a loop for the call in caller.yml job c"})
        self.assertEqual({r.name for r in resolved.vars_read if r.field == "runs-on"}, {"A_RUNNER", "B_FALLBACK"})
        findings = self.scan({"callee.yml": self.PAIR, "caller.yml": callers})
        self.assertTrue([f for f in findings if "cannot be verified" in f], findings)

    def count_work(self, wj, run):
        """Calls of Workflows.input_values and of the resolve step for one run (the harness the PR body reports)."""
        counts = {"input_values": 0, "_resolve": 0}

        def counted(name, real):
            def wrapper(*args, **kwargs):
                counts[name] += 1
                return real(*args, **kwargs)
            return wrapper
        with unittest.mock.patch.object(wj.Workflows, "input_values", counted("input_values", wj.Workflows.input_values)), \
                unittest.mock.patch.object(wj, "_resolve", counted("_resolve", wj._resolve)):
            run()
        return counts

    def test_codex_repro_a_default_chain_costs_callers_times_inputs(self) -> None:
        """Codex on #41015: 16 inputs, each defaulting to the next, two callers passing nothing, cost 131,070
        input_values calls (2^17 - 2). Read per caller and memoised it is O(callers x inputs)."""
        inputs = 16
        declared = "".join(f"      i{n}: {{type: string, default: '${{{{ inputs.i{n + 1} }}}}'}}\n" for n in range(inputs - 1))
        declared += f"      i{inputs - 1}: {{type: string, default: '${{{{ vars.LAST }}}}'}}\n"
        callee = ("on:\n  workflow_call:\n    inputs:\n" + declared + "jobs:\n  a:\n    runs-on: ${{ inputs.i0 }}\n")
        callers = "jobs:\n" + "".join(f"  c{n}:\n    uses: ./.github/workflows/callee.yml\n" for n in range(2))
        wj = checker.load_workflow_jobs()
        workflows = wj.Workflows({"callee.yml": wj.document(callee), "caller.yml": wj.document(callers)})
        job = workflows.documents["callee.yml"]["jobs"]["a"]
        found = {}
        counts = self.count_work(wj, lambda: found.setdefault("r", wj.resolve(job, "a", "callee.yml", workflows)))
        print(f"\ndefault chain, 2 callers x {inputs} inputs: {counts}", file=sys.stderr)
        self.assertEqual({r.name for r in found["r"].vars_read if r.field == "runs-on"}, {"LAST"})
        self.assertEqual(found["r"].unverifiable, frozenset())
        # resolve() traces runs-on twice (runs_on_cells, runs_on_values): k = 2 traces x 2 for slack.
        self.assertLessEqual(counts["input_values"] + counts["_resolve"], 2 * inputs * 4, counts)

    def test_a_chain_of_workflows_each_called_twice_costs_linear(self) -> None:
        """The same class across workflows: w0's runner is what two jobs of w1 pass, each `inputs.runner` of w1,
        which two jobs of w2 call, and so on. Read without memo it was 2^depth; each input is now read once."""
        depth = 14
        declared = "on:\n  workflow_call:\n    inputs:\n      runner: {type: string}\n"

        def calls(target: str, value: str) -> str:
            return "".join(f"  c{k}:\n    uses: ./.github/workflows/{target}\n    with:\n      runner: {json.dumps(value)}\n"
                           for k in range(2))
        files = {"w0.yml": declared + "jobs:\n  a:\n    runs-on: ${{ inputs.runner }}\n"}
        for n in range(1, depth):
            files[f"w{n}.yml"] = declared + "jobs:\n" + calls(f"w{n - 1}.yml", "${{ inputs.runner }}")
        files[f"w{depth}.yml"] = "jobs:\n" + calls(f"w{depth - 1}.yml", "${{ vars.TOP }}")
        wj = checker.load_workflow_jobs()
        workflows = wj.Workflows({name: wj.document(text) for name, text in files.items()})
        job = workflows.documents["w0.yml"]["jobs"]["a"]
        found = {}
        counts = self.count_work(wj, lambda: found.setdefault("r", wj.resolve(job, "a", "w0.yml", workflows)))
        print(f"\nworkflow chain, {depth} workflows x 2 callers: {counts}", file=sys.stderr)
        self.assertEqual({r.name for r in found["r"].vars_read if r.field == "runs-on"}, {"TOP"})
        self.assertLessEqual(counts["input_values"] + counts["_resolve"], 2 * depth * 8, counts)

    def test_the_resolver_records_each_variable_it_consumes_with_where_it_sits(self) -> None:
        """The checker reads its findings from workflow_jobs.resolve, which records every `vars` operand it consumed
        resolving a field: the file, the job and the key path it sits at, and the field that consumed it."""
        wj = checker.load_workflow_jobs()
        caller = ("jobs:\n  c:\n    strategy:\n      matrix: ${{ fromJSON(vars.NEW_X) }}\n"
                  "    uses: ./.github/workflows/callee.yml\n    with:\n      runner: ${{ matrix.runner }}\n")
        documents = {"callee.yml": wj.document(self.CALLEE % "inputs.runner"), "caller.yml": wj.document(caller)}
        resolved = wj.resolve(documents["callee.yml"]["jobs"]["a"], "a", "callee.yml", wj.Workflows(documents))
        found = {(r.name, r.file, r.job, r.path, r.field) for r in resolved.vars_read}
        self.assertIn(("NEW_X", "caller.yml", "c", "strategy.matrix", "runs-on"), found)
        own = wj.document("jobs:\n  a:\n    environment: ${{ vars.ENV_X }}\n    runs-on: ${{ vars['RUN_X'] }}\n")
        found = {(r.name, r.path, r.field) for r in wj.resolve(own["jobs"]["a"], "a", "x.yml").vars_read}
        self.assertEqual(found, {("ENV_X", "environment", "environment"), ("RUN_X", "runs-on", "runs-on")})

    def test_a_variable_inside_fromjson_or_a_needs_dependent_expression_is_read(self) -> None:
        for runs_on, name in (("fromJSON(vars.NEW_X).mac", "NEW_X"),
                              ("fromJSON(needs.setup.outputs.map)[vars.NEW_X]", "NEW_X"),
                              ("needs.setup.outputs.ok == 'true' && vars.NEW_Y || needs.setup.outputs.runner", "NEW_Y"),
                              ("format('{0}', needs.setup.outputs.ok && vars.NEW_Y)", "NEW_Y")):
            with self.subTest(runs_on=runs_on):
                self.assert_names(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: ${{{{ {runs_on} }}}}\n"}), name)

    def test_a_part_that_reads_no_variable_is_not_this_policys_business(self) -> None:
        for runs_on in ("${{ needs.setup.outputs.runner }}", "${{ fromJSON(needs.setup.outputs.runners).mac }}",
                        "${{ inputs.runner }}"):
            with self.subTest(runs_on=runs_on):
                self.assertEqual(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {runs_on}\n"}), [])

    def test_a_variable_whose_name_is_an_expression_fails(self) -> None:
        text = ("jobs:\n  a:\n    strategy:\n      matrix:\n        os: [mac]\n"
                "    runs-on: ${{ vars[format('RUNNER_{0}', matrix.os)] }}\n")
        findings = self.scan({"x.yml": text})
        self.assertTrue([f for f in findings if "whose name is an expression" in f], findings)

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
        with unittest.mock.patch.object(checker, "check", side_effect=RuntimeError("boom")):
            code, out = self.run_cli("--advisory")
        self.assertEqual(code, 0)
        self.assertIn("could not run: RuntimeError: boom", out)
        # An unreadable declaration is a finding now, not a crash: a warning in CI, a refusal in strict mode.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github").mkdir()
            (root / ".github" / "single-host-fallbacks.json").write_text("{not json", encoding="utf-8")
            code, out = self.run_cli("--root", str(root), "--advisory")
            self.assertEqual(code, 0)
            self.assertIn("is not readable JSON", out)
            self.assertEqual(self.run_cli("--root", str(root))[0], 1)

    def test_json_mode_keys_each_finding(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = self.repo_with(tmp, "jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n")
            code, out = self.run_cli("--root", str(root), "--json")
        self.assertEqual(code, 0)
        self.assertEqual([f["key"] for f in json.loads(out)], ["vars.NEW_X"])

    def test_this_checkout_passes_in_strict_mode(self) -> None:
        code, out = self.run_cli()
        self.assertEqual(code, 0, out)

    def declaration_root(self, tmp: str, declaration_text: str) -> Path:
        root = Path(tmp) / "repo"
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "x.yml").write_text(
            "jobs:\n  a:\n    runs-on: ${{ vars.RUNNER_POOLS }}\n", encoding="utf-8")
        (root / ".github" / "single-host-fallbacks.json").write_text(declaration_text, encoding="utf-8")
        return root

    def test_a_null_or_wrong_type_section_gives_schema_findings_not_a_traceback(self) -> None:
        """Codex on #40799: `"variables": null` recorded a schema fault, then crashed findings(), so --json printed
        nothing and the pre-push layer passed. Every shape now gives findings and a verdict."""
        broken: list[object] = [None, [], "x"]
        for section, value in (("variables", None), ("variables", []), ("labels", None), ("labels", []),
                               ("controller_labels", None), ("controller_labels", [["x"]]),
                               ("single_host_prefixes", None), ("single_host_prefixes", [1]),
                               ("nightly_terminal_labels", None), ("nightly_job_outputs", []),
                               ("nightly_job_outputs", {"a.yml:b.c": {"labels": [None, ["x"]]}})):
            policy = load_declaration()
            policy[section] = value
            broken.append(policy)
        for declaration in broken:
            text = json.dumps(declaration)
            with self.subTest(declaration=text[:80]), tempfile.TemporaryDirectory() as tmp:
                root = self.declaration_root(tmp, text)
                code, out = self.run_cli("--root", str(root), "--json")
                self.assertEqual(code, 0)
                found = json.loads(out)
                self.assertTrue(found and all(f["key"].startswith("declaration:") for f in found), found)
                self.assertEqual(self.run_cli("--root", str(root))[0], 1)
        with tempfile.TemporaryDirectory() as tmp:
            code, out = self.run_cli("--root", str(self.declaration_root(tmp, "{not json")), "--json")
            self.assertEqual([f["key"] for f in json.loads(out)], ["declaration:unreadable"])

    def test_a_missing_workflow_directory_is_reported(self) -> None:
        self.assertTrue(undeclared([ROOT / "no-such-dir" / "workflows"], load_declaration()))


class VarsReadOracle(unittest.TestCase):
    """Differential oracle: random small workflow graphs (callers, inputs, defaults, matrices, vars), each evaluated
    by a reference evaluator that walks the generator's own model, never the YAML. Resolved.vars_read (field
    runs-on) must equal the reference set, and the resolver must say unverifiable exactly when the reference
    meets a loop."""

    CASES = 1200
    LITERALS = ("blacksmith-4vcpu-ubuntu-2404", "ubuntu-24.04", "macos-26")

    def term(self, rng, inputs, matrix, depth=0):
        """A value: (kind, ...). Kinds: lit, var, cond (vars.V == ... && lit || lit), input, cond_input, matrix."""
        kinds = ["lit", "var", "cond"] + (["input", "cond_input"] if inputs else []) + (["matrix"] if matrix else [])
        kind = rng.choice(kinds)
        if kind == "lit":
            return ("lit", rng.choice(self.LITERALS))
        if kind in ("var", "cond"):
            return (kind, rng.choice("ABCD"), rng.random() < 0.5)  # the flag: bracket form
        if kind in ("input", "cond_input"):
            return (kind, rng.choice(inputs))
        return ("matrix",)

    def text(self, term):
        kind = term[0]
        if kind == "lit":
            return term[1]
        if kind in ("var", "cond"):
            ref = f"vars['V_{term[1]}']" if term[2] else f"vars.V_{term[1]}"
            return f"${{{{ {ref} }}}}" if kind == "var" else f"${{{{ {ref} == 'x' && 'macos-26' || 'ubuntu-24.04' }}}}"
        if kind == "input":
            return f"${{{{ inputs.{term[1]} }}}}"
        if kind == "cond_input":
            return f"${{{{ inputs.{term[1]} == 'x' && 'macos-26' || 'ubuntu-24.04' }}}}"
        return "${{ matrix.runner }}"

    def matrix(self, rng, inputs):
        if rng.random() < 0.5:
            return None
        if rng.random() < 0.25:
            return ("fromjson", rng.choice("ABCD"))
        return ("cells", [self.term(rng, inputs, None) for _ in range(rng.randint(1, 3))])

    def graph(self, rng):
        names = [f"w{i}.yml" for i in range(rng.randint(1, 4))]
        model = {}
        for name in names:
            inputs = rng.sample(["p", "q", "r"], rng.randint(0, 3))
            defaults = {i: self.term(rng, inputs, None) for i in inputs if rng.random() < 0.6}
            matrix = self.matrix(rng, inputs)
            calls = []
            for _ in range(rng.randint(0, 2)):
                target = rng.choice(names)
                cmatrix = self.matrix(rng, inputs)
                calls.append((target, cmatrix, {}))  # with: filled once every target's inputs are known
            model[name] = {"inputs": inputs, "defaults": defaults, "matrix": matrix,
                           "runs_on": self.term(rng, inputs, matrix), "calls": calls}
        for name, flow in model.items():
            for target, cmatrix, passed in flow["calls"]:
                for i in model[target]["inputs"]:
                    if rng.random() < 0.6:
                        passed[i] = self.term(rng, flow["inputs"], cmatrix)
        return model

    def render(self, flow):
        lines = []
        if flow["inputs"]:
            lines += ["on:", "  workflow_call:", "    inputs:"]
            for i in flow["inputs"]:
                default = f", default: {json.dumps(self.text(flow['defaults'][i]))}" if i in flow["defaults"] else ""
                lines.append(f"      {i}: {{type: string{default}}}")
        lines.append("jobs:")

        def matrix_lines(matrix):
            if matrix is None:
                return []
            if matrix[0] == "fromjson":
                return ["    strategy:", f"      matrix: ${{{{ fromJSON(vars.V_{matrix[1]}) }}}}"]
            return ["    strategy:", "      matrix:", "        runner:"] + [
                f"          - {json.dumps(self.text(t))}" for t in matrix[1]]
        lines += ["  run:", *matrix_lines(flow["matrix"]), f"    runs-on: {json.dumps(self.text(flow['runs_on']))}"]
        for index, (target, cmatrix, passed) in enumerate(flow["calls"]):
            lines += [f"  call{index}:", *matrix_lines(cmatrix), f"    uses: ./.github/workflows/{target}"]
            if passed:
                lines.append("    with:")
                lines += [f"      {k}: {json.dumps(self.text(v))}" for k, v in passed.items()]
        return "\n".join(lines) + "\n"

    def reference(self, model, name, term, matrix, seen):
        """The variables TERM, written in workflow NAME under MATRIX, reads; raises LookupError on a loop."""
        kind = term[0]
        if kind in ("var", "cond"):
            return {f"V_{term[1]}"}
        if kind in ("input", "cond_input"):
            return self.input_reference(model, name, term[1], seen)
        if kind == "matrix":
            if matrix[0] == "fromjson":
                return {f"V_{matrix[1]}"}
            return set().union(*(self.reference(model, name, t, None, seen) for t in matrix[1]))
        return set()

    def input_reference(self, model, name, key, seen):
        if (name, key) in seen:
            raise LookupError((name, key))
        callers = [(caller, index) for caller, flow in model.items() for index, call in enumerate(flow["calls"])
                   if call[0] == name]
        found = set()
        for caller, index in callers:
            found |= self.call_reference(model, name, caller, index, key, seen | {(name, key)})
        return found

    def call_reference(self, model, name, caller, index, key, seen):
        """What input KEY of NAME reads for the one call CALLER makes at INDEX: its `with:` value, read in the
        caller, or else the default, whose own inputs are this same call's (defaults hold no matrix)."""
        if (name, caller, index, key) in seen:
            raise LookupError((name, caller, index, key))
        here = seen | {(name, caller, index, key)}
        _, cmatrix, passed = model[caller]["calls"][index]
        if key in passed:
            return self.reference(model, caller, passed[key], cmatrix, here)
        default = model[name]["defaults"].get(key)
        if default is None:
            return set()
        if default[0] in ("input", "cond_input"):
            return self.call_reference(model, name, caller, index, default[1], here)
        return self.reference(model, name, default, None, here)

    def test_vars_read_matches_the_reference_on_random_graphs(self) -> None:
        import random
        wj = checker.load_workflow_jobs()
        for seed in range(self.CASES):
            rng = random.Random(seed)
            model = self.graph(rng)
            texts = {name: self.render(flow) for name, flow in model.items()}
            workflows = wj.Workflows({name: wj.document(text) for name, text in texts.items()})
            for name, flow in model.items():
                job = workflows.documents[name]["jobs"]["run"]
                resolved = wj.resolve(job, "run", name, workflows)
                got = {r.name for r in resolved.vars_read if r.field == "runs-on"}
                unverifiable = any(u.field == "runs-on" for u in resolved.unverifiable)
                try:
                    want, looped = self.reference(model, name, flow["runs_on"], flow["matrix"], frozenset()), False
                except LookupError:
                    want, looped = None, True
                with self.subTest(seed=seed, workflow=name):
                    detail = f"seed {seed} {name}:\n" + "\n".join(f"--- {n}\n{t}" for n, t in texts.items())
                    self.assertEqual(unverifiable, looped, detail)
                    if not looped:
                        self.assertEqual(got, want, detail)


def load_gate():
    spec = importlib.util.spec_from_file_location("prepush_gate_single_host", ROOT / "scripts" / "cmux-next" / "prepush-gate.py")
    gate = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = gate
    spec.loader.exec_module(gate)
    return gate


class PrepushGateLayer(unittest.TestCase):
    """The pre-push layer refuses whenever the checker gives no verdict; only a missing install warns."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.gate = load_gate()

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        (self.repo / ".github" / "workflows").mkdir(parents=True)
        self.git("init", "-q")
        shutil.copy(DECLARATION, self.repo / ".github" / "single-host-fallbacks.json")
        self.workflow("a.yml", "${{ vars.RUNNER_POOLS }}")
        self.base = self.commit("base")
        self.installed = Path(self.tmp.name) / "installed"
        self.installed.mkdir()

    def git(self, *args: str) -> str:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=fixture",
                               "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", *args],
                              check=True, capture_output=True, text=True, env=env).stdout.strip()

    def workflow(self, name: str, runs_on: str) -> None:
        (self.repo / ".github" / "workflows" / name).write_text(f"jobs:\n  a:\n    runs-on: {runs_on}\n",
                                                                 encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--no-gpg-sign", "-m", message)
        return self.git("rev-parse", "HEAD")

    def checker(self, source: str | None) -> None:
        path = self.installed / "check-single-host-fallbacks.py"
        if source is None:
            shutil.copy(SCRIPT, path)
            shutil.copy(ROOT / "tests" / "workflow_jobs.py", self.installed / "workflow_jobs.py")
        else:
            path.write_text(source, encoding="utf-8")

    def layer(self) -> list[str]:
        with contextlib.redirect_stderr(io.StringIO()):
            return self.gate.single_host_fallback_problems(self.repo, self.base, self.git("rev-parse", "HEAD"),
                                                           self.installed)

    def test_a_checker_that_gives_no_verdict_refuses(self) -> None:
        self.workflow("b.yml", "${{ vars.RUNNER_POOLS }}")
        self.commit("head")
        for source in ("raise RuntimeError('boom')\n", "print('garbage')\n", "print('[]')\nraise SystemExit(2)\n",
                       "print('{\"key\": 1}')\n", "print('[{\"no\": \"key\"}]')\n", ""):
            with self.subTest(source=source):
                self.checker(source)
                refused = self.layer()
                self.assertEqual(len(refused), 1, refused)
                self.assertIn("did not give a verdict", refused[0])

    def test_a_missing_pyyaml_refuses_with_its_install_line(self) -> None:
        self.checker(None)
        self.workflow("b.yml", "${{ vars.RUNNER_POOLS }}")
        self.commit("head")
        with unittest.mock.patch.object(self.gate, "has_pyyaml", return_value=False), \
                unittest.mock.patch.object(self.gate, "pyyaml_install_command", return_value="PY -m pip install X"):
            self.assertEqual(self.layer(), ["PyYAML missing: run PY -m pip install X"])
        # The probe asks the hook's own interpreter the way the hook runs it (-I, so no user site).
        self.assertTrue(self.gate.has_pyyaml(sys.executable))
        self.assertFalse(self.gate.has_pyyaml(str(Path(self.tmp.name) / "no-such-python")))

    def test_the_install_line_reaches_the_interpreter_the_hook_runs(self) -> None:
        command = self.gate.pyyaml_install_command
        with tempfile.TemporaryDirectory() as tmp:
            writable, stdlib = Path(tmp) / "site", Path(tmp) / "lib"
            writable.mkdir(); stdlib.mkdir()
            python = "/opt/py 3/bin/python3"
            self.assertEqual(command(python, str(writable), str(stdlib), apt=False),
                             "'/opt/py 3/bin/python3' -m pip install PyYAML==6.0.3")
            (stdlib / "EXTERNALLY-MANAGED").write_text("", encoding="utf-8")
            self.assertEqual(command(python, str(writable), str(stdlib), apt=False),
                             "'/opt/py 3/bin/python3' -m pip install --break-system-packages PyYAML==6.0.3")
            unwritable = str(Path(tmp) / "missing-site")
            self.assertEqual(command(python, unwritable, str(stdlib), apt=True), "sudo apt-get install -y python3-yaml")
            self.assertEqual(command(python, unwritable, str(stdlib), apt=False),
                             "sudo '/opt/py 3/bin/python3' -m pip install PyYAML==6.0.3")
            for line in (command(python, str(writable), str(stdlib), apt=False),
                         command(python, unwritable, str(stdlib), apt=False)):
                self.assertNotIn("--user", line, "-I ignores user site-packages, so a --user install never helps")

    def test_an_install_without_the_shared_resolver_refuses_with_the_reinstall_command(self) -> None:
        self.checker(None)
        (self.installed / "workflow_jobs.py").unlink()
        self.workflow("b.yml", "${{ vars.RUNNER_POOLS }}")
        self.commit("head")
        refused = self.layer()
        self.assertEqual(len(refused), 1, refused)
        self.assertIn("rerun scripts/install-git-hooks.sh", refused[0])
        self.assertIn("workflow_jobs.py", refused[0])

    def test_a_missing_install_only_warns(self) -> None:
        self.workflow("b.yml", "${{ vars.NEW_X }}")
        self.commit("head")
        self.assertEqual(self.layer(), [])

    def test_the_real_checker_refuses_a_new_name_and_passes_a_declared_one(self) -> None:
        self.checker(None)
        self.workflow("b.yml", "${{ vars.RUNNER_POOLS }}")
        self.commit("declared")
        self.assertEqual(self.layer(), [])
        self.workflow("c.yml", "${{ vars.NEW_X }}")
        self.commit("undeclared")
        refused = self.layer()
        self.assertEqual(len(refused), 1, refused)
        self.assertTrue(refused[0].startswith("vars.NEW_X "), refused)

    def test_a_null_variables_section_refuses_instead_of_passing(self) -> None:
        self.checker(None)
        policy = load_declaration()
        policy["variables"] = None
        (self.repo / ".github" / "single-host-fallbacks.json").write_text(json.dumps(policy), encoding="utf-8")
        self.commit("null variables")
        refused = self.layer()
        self.assertTrue(refused, "a null variables section passed the layer")
        self.assertTrue(any("variables must be an object" in line for line in refused), refused)

    def test_an_unscanned_base_is_never_subtracted_from_the_head(self) -> None:
        """Codex F1 on #40840: a schema fault the base already had was subtracted as old debt, so a head that added
        vars.NEW_X passed with no scan. An incomplete scan refuses whatever the base had."""
        self.checker(None)
        policy = load_declaration()
        policy["variables"] = None
        (self.repo / ".github" / "single-host-fallbacks.json").write_text(json.dumps(policy), encoding="utf-8")
        self.base = self.commit("an unscannable declaration on the base")
        self.workflow("b.yml", "${{ vars.NEW_X }}")
        self.commit("adds vars.NEW_X")
        refused = self.layer()
        self.assertTrue(refused, "a new runs-on variable passed because the base's scan did not run either")
        self.assertTrue(all("did not run" in line for line in refused), refused)

    def test_output_of_the_wrong_shape_refuses(self) -> None:
        """Codex F2 on #40840: findings were str()-coerced, so `[{"key": [], "message": {}}]` was one equal finding on
        both sides and passed. Anything but objects with a string key, a string message and a known status refuses."""
        self.workflow("b.yml", "${{ vars.RUNNER_POOLS }}")
        self.commit("head")
        for listed in ([{"key": [], "message": {}}], [{"key": "k", "message": "m"}],
                       [{"key": "k", "message": 1, "status": "found"}], [{"key": "k", "message": "m", "status": "x"}],
                       ["vars.X"], [None]):
            with self.subTest(listed=listed):
                self.checker(f"print({json.dumps(json.dumps(listed))})\n")
                refused = self.layer()
                self.assertEqual(len(refused), 1, refused)
                self.assertIn("did not give a verdict", refused[0])
        # The same shape with a valid status gives a verdict, so the base's copy is subtracted.
        self.checker(f"print({json.dumps(json.dumps([{'key': 'k', 'message': 'm', 'status': 'found'}]))})\n")
        self.assertEqual(self.layer(), [])

    def test_every_json_finding_carries_a_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / ".github" / "workflows").mkdir(parents=True)
            shutil.copy(DECLARATION, root / ".github" / "single-host-fallbacks.json")
            (root / ".github" / "workflows" / "a.yml").write_text("jobs:\n  a:\n    runs-on: ${{ vars.NEW_X }}\n",
                                                                  encoding="utf-8")
            (root / ".github" / "workflows" / "b.yml").write_text("jobs: [\n", encoding="utf-8")
            found = checker.check(root)
            self.assertEqual({f["key"].split(":")[0]: f["status"] for f in found},
                             {"vars.NEW_X": "found", "unreadable": "incomplete"})


if __name__ == "__main__":
    sys.exit(unittest.main())
