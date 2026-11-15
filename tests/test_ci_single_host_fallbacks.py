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
import hashlib
import importlib.util
import io
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", os.path.join(os.path.dirname(os.path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
# sha256 of prepush-gate.py's PEP668_ROUTE. leo-workspace tools/test_host_baseline.py pins the same digest for the same
# text in machines/host-baseline.json, so the two PEP 668 decisions cannot drift apart.
PEP668_ROUTE_SHA256 = "1c3f19137ff17c7123fa3fc03093ff2fcdd3e33d9b9488415dd9f5d159de97b0"


def base_interpreter() -> str:
    """A Python that is not a venv (sys.prefix == sys.base_prefix), checked by asking it."""
    base = getattr(sys, "_base_executable", sys.executable)
    asked = subprocess.run([base, "-I", "-c", "import sys; print(sys.prefix == sys.base_prefix)"],
                           capture_output=True, text=True, check=True).stdout.strip()
    assert asked == "True", f"{base} is itself a venv, so it cannot stand for a base interpreter"
    return base
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

    def count_work(self, wj, run, budget: int | None = None):
        """Calls of Workflows.input_values and of the resolve step for one run (the harness the PR body reports). Past
        `budget` calls in all the run fails at once, so a trace that explodes is a failure, not a hang."""
        counts = {"input_values": 0, "_resolve": 0}

        def counted(name, real):
            def wrapper(*args, **kwargs):
                counts[name] += 1
                if budget is not None and sum(counts.values()) > budget:
                    raise AssertionError(f"more than {budget} calls: {counts}")
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

    def default_chain(self, inputs: int, callers: int):
        """`i0` .. `i<inputs-1>` of callee.yml, each defaulting to the next, the last to vars.LAST; runs-on reads i0;
        `callers` jobs call it passing nothing."""
        wj = checker.load_workflow_jobs()
        declared = "".join(f"      i{n}: {{type: string, default: '${{{{ inputs.i{n + 1} }}}}'}}\n" for n in range(inputs - 1))
        declared += f"      i{inputs - 1}: {{type: string, default: '${{{{ vars.LAST }}}}'}}\n"
        callee = ("on:\n  workflow_call:\n    inputs:\n" + declared + "jobs:\n  a:\n    runs-on: ${{ inputs.i0 }}\n")
        caller = "jobs:\n" + "".join(f"  c{n}:\n    uses: ./.github/workflows/callee.yml\n" for n in range(callers))
        workflows = wj.Workflows({"callee.yml": wj.document(callee), "caller.yml": wj.document(caller)})
        return wj, workflows, workflows.documents["callee.yml"]["jobs"]["a"]

    def test_review_f2_a_default_chain_at_ten_callers_is_near_linear_in_inputs(self) -> None:
        """Review F2 on #41015: at 10 callers, n inputs then 2n inputs in a default chain. The work must about double
        (near linear in inputs, linear in callers); read through every caller at each level it was callers^inputs."""
        callers, small = 10, 8
        totals = {}
        for inputs in (small, 2 * small):
            wj, workflows, job = self.default_chain(inputs, callers)
            found = {}
            # resolve() traces runs-on twice (runs_on_cells, runs_on_values); x4 slack per trace.
            budget = callers * inputs * 2 * 4
            counts = self.count_work(wj, lambda: found.setdefault("r", wj.resolve(job, "a", "callee.yml", workflows)),
                                     budget)
            self.assertEqual({r.name for r in found["r"].vars_read if r.field == "runs-on"}, {"LAST"})
            self.assertEqual(found["r"].unverifiable, frozenset())
            totals[inputs] = sum(counts.values())
            print(f"\ndefault chain, {callers} callers x {inputs} inputs: {counts}", file=sys.stderr)
        ratio = totals[2 * small] / totals[small]
        print(f"default chain, {callers} callers, inputs {small} -> {2 * small}: x{ratio:.2f}", file=sys.stderr)
        self.assertLessEqual(ratio, 2.5, totals)

    CALLS_NOTHING = "jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n"

    def runner_default(self, default: str, extra: str = "") -> str:
        """callee.yml whose `runner` defaults to `default` (YAML single-quoted) and whose runs-on reads it."""
        return self.DEFAULTED % (f"      runner: {{type: string, default: '{default.replace(chr(39), chr(39) * 2)}'}}\n"
                                 + extra)

    def test_review_f1_an_input_named_inside_a_string_literal_is_not_read(self) -> None:
        """Review F1 on #41015: the input reader was a regex over the expression, so `'inputs.runner'` (text) in
        runner's own default read as a self-reference and the trace reported a loop it does not have. Inputs are
        read by tokens now: a literal, a format() argument and a bracket form inside a literal read nothing."""
        branches = "&& 'blacksmith-8vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}"
        for default in ("${{ 'inputs.runner' == 'x' " + branches,
                        "${{ format('{0} inputs.runner', 'x') == 'y' " + branches,
                        "${{ 'inputs[\"runner\"]' == 'x' " + branches,
                        "${{ \"inputs.runner\" == 'x' " + branches):
            with self.subTest(default=default):
                files = {"callee.yml": self.runner_default(default), "caller.yml": self.CALLS_NOTHING}
                _, _, resolved = self.resolve_callee(files)
                self.assertEqual(resolved.unverifiable, frozenset())
                self.assertEqual((resolved.runs_on, resolved.runs_on_unresolved),
                                 ({"blacksmith-8vcpu-ubuntu-2404", "blacksmith-4vcpu-ubuntu-2404"}, set()))
                findings = self.scan(files)
                self.assertFalse([f for f in findings if "cannot be verified" in f], findings)

    def test_review_f1_a_real_input_beside_a_literal_is_read_and_only_that_input(self) -> None:
        """`inputs.runner_count` is not `inputs.runner`, `github.event.inputs.note` is a property of another context,
        and `inputs.size` inside a literal beside a real `inputs.runner` is text: only the real reads are traced."""
        extra = ("      runner_count: {type: string}\n      size: {type: string}\n      note: {type: string}\n")
        callee = self.runner_default("${{ inputs.runner_count == '2' && 'blacksmith-8vcpu-ubuntu-2404' || "
                                     "'blacksmith-4vcpu-ubuntu-2404' }}", extra)
        caller = ("jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                  "      runner_count: ${{ vars.NEW_RC }}\n")
        files = {"callee.yml": callee, "caller.yml": caller}
        _, _, resolved = self.resolve_callee(files)
        self.assertEqual(resolved.unverifiable, frozenset())
        self.assertEqual({r.name for r in resolved.vars_read if r.field == "runs-on"}, {"NEW_RC"})
        beside = self.DEFAULTED.replace("${{ inputs.runner }}",
                                        "${{ inputs.runner != 'inputs.size' && inputs.runner || "
                                        "github.event.inputs.note || 'blacksmith-4vcpu-ubuntu-2404' }}")
        callee = beside % ("      runner: {type: string}\n" + extra)
        caller = ("jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                  "      runner: ${{ vars.NEW_X }}\n      size: ${{ vars.NOT_A_RUNNER }}\n"
                  "      note: ${{ vars.NOT_A_RUNNER_EITHER }}\n")
        files = {"callee.yml": callee, "caller.yml": caller}
        _, _, resolved = self.resolve_callee(files)
        self.assertEqual({r.name for r in resolved.vars_read if r.field == "runs-on"}, {"NEW_X"})
        findings = self.scan(files)
        self.assert_names(findings, "NEW_X")
        self.assertFalse([f for f in findings if "NOT_A_RUNNER" in f], findings)

    def test_review_f1_every_context_reader_parses_the_expression(self) -> None:
        """The same class in the other readers over `${{ }}` text: a literal index inside a literal was rewritten to
        dot form (the label `lab["el"]` came out `lab.el`), `'matrix.os'` made the field an unexpandable matrix read,
        and `'secrets'` in a literal read every secret. Each reads by tokens now; real reads still count."""
        wj = checker.load_workflow_jobs()
        job = wj.document("jobs:\n  a:\n    runs-on: ${{ github.event_name == 'push' && 'lab[\"el\"]' || 'matrix.os' }}\n")
        resolved = wj.resolve(job["jobs"]["a"], "a", "x.yml")
        self.assertEqual((resolved.runs_on, resolved.runs_on_unresolved), ({'lab["el"]', "matrix.os"}, set()))
        self.assertEqual(wj.secret_names({"env": {"A": "${{ 'secrets.X' == 'secrets' && secrets.REAL || '' }}"}}),
                         {"REAL"})
        for text, expected in (("${{ secrets['Y'] }}", {"Y"}), ('${{ secrets["Y"] }}', {"Y"}),
                               ("${{ toJSON(secrets) }}", {wj.ALL_SECRETS}), ("${{ secrets[matrix.k] }}", {wj.ALL_SECRETS}),
                               ("${{ SECRETS.y }}", {"Y"}), ("secrets.W != ''", {"W"})):
            with self.subTest(text=text):
                self.assertEqual(wj.secret_names({"if": text}), expected)
        matrix = wj.document("jobs:\n  a:\n    strategy:\n      matrix:\n        os: [m1, m2]\n"
                             "    runs-on: ${{ matrix['os'] }}-${{ 'matrix.os' }}\n")
        self.assertEqual(wj.resolve(matrix["jobs"]["a"], "a", "x.yml").runs_on_cells, ["m1-${{ 'matrix.os' }}",
                                                                                      "m2-${{ 'matrix.os' }}"])

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

    def test_a_variable_named_inside_a_string_literal_is_not_read(self) -> None:
        """Codex on hq#9175: `${{ 'vars.X' }}` is the text "vars.X", not a read of X, so the resolver read a variable
        no runs-on consumes (the build-fleet expression readers agree; this one did not). A read beside it still
        counts, a quoted index still names its variable, and an escaped quote does not end the literal."""
        wj = checker.load_workflow_jobs()
        for text, expected in (("${{ 'vars.QUOTED' }}", []),
                               ("${{ 'it''s vars.Q' || vars.R }}", ["R"]),
                               ('${{ "vars.D" || vars.E }}', ["E"]),
                               ("${{ vars['B'] || 'vars.NOT_A_READ' }}", ["B"]),
                               ("${{ vars[format('{0}', 'vars.G')] }}", [None]),
                               ("${{ toJSON(vars) == 'vars.H' }}", [None])):
            with self.subTest(text=text):
                self.assertEqual(wj.variable_reads(text), expected)
        self.assertEqual(self.scan({"x.yml": "jobs:\n  a:\n    runs-on: ${{ 'vars.NEW_X' }}\n"}), [])

    def test_a_closing_brace_pair_inside_a_string_literal_does_not_end_the_expression(self) -> None:
        """Codex on hq#9175: the `${{ }}` scan stopped at the first `}}`, also one inside a quoted literal, so
        `contains('}}', '}') && vars.NEW_X || ...` hid the variable after it and the rest read as plain text. The scan
        is quote-aware: an expression ends at a `}}` outside every literal, and one never closed reads as a variable
        no declaration can name."""
        wj = checker.load_workflow_jobs()
        for text, expected in (("${{ contains('}}', '}') && vars.NEW_X || 'blacksmith-4vcpu-ubuntu-2404' }}", ["NEW_X"]),
                               ("${{ '}}' }}${{ vars.AFTER }}", ["AFTER"]),
                               ("${{ vars.A == 1e+2 || vars.B == -1 || vars.C == 0x1F || vars.D == 1.5E-3 }}",
                                ["A", "B", "C", "D"]),
                               ("${{ vars.OPEN ", [None])):
            with self.subTest(text=text):
                self.assertEqual(wj.variable_reads(text), expected)
        runs_on = "${{ contains('}}', '}') && vars.NEW_X || 'blacksmith-4vcpu-ubuntu-2404' }}"
        self.assert_names(self.scan({"x.yml": f'jobs:\n  a:\n    runs-on: "{runs_on}"\n'}), "NEW_X")

    def test_a_part_that_reads_no_variable_is_not_this_policys_business(self) -> None:
        for runs_on in ("${{ needs.setup.outputs.runner }}", "${{ fromJSON(needs.setup.outputs.runners).mac }}",
                        "${{ inputs.runner }}"):
            with self.subTest(runs_on=runs_on):
                self.assertEqual(self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {runs_on}\n"}), [])

    def runs_on(self, value: str, policy: dict | None = None) -> list[str]:
        """The findings for one job whose runs-on is VALUE (written as JSON, so any quote or `: ` in it stays)."""
        return self.scan({"x.yml": f"jobs:\n  a:\n    runs-on: {json.dumps(value)}\n"}, policy)

    def test_review_f1_a_constant_fromjson_label_is_read(self) -> None:
        """Review F1 on #40894: `fromJSON('["glaeda-runner-cmux22-new"]')` stayed unresolved and the label loop
        read only resolved values, so the undeclared label passed. A constant fromJSON is its labels now."""
        label = "glaeda-runner-cmux22-new"
        for value in (f"${{{{ fromJSON('[\"{label}\"]') }}}}", f"${{{{ fromJSON('\"{label}\"') }}}}",
                      f"${{{{ fromJSON('{{\"mac\": \"{label}\"}}').mac }}}}",
                      f"${{{{ fromJSON('{{\"mac\": \"{label}\"}}')['MAC'] }}}}",
                      f"${{{{ github.event_name == 'push' && fromJSON('[\"self-hosted\", \"{label}\"]') || 'ubuntu-24.04' }}}}"):
            with self.subTest(runs_on=value):
                findings = self.runs_on(value)
                self.assertTrue([f for f in findings if f"{label} is a single-host label" in f], findings)
                policy = load_declaration()
                policy["labels"][label] = {"fallback": "Blacksmith macOS", "after_minutes": 5}
                self.assertEqual(self.runs_on(value, policy), [])

    def test_review_f1_the_resolver_reads_a_constant_fromjson(self) -> None:
        wj = checker.load_workflow_jobs()
        for expression, expected in (("fromJSON('[\"a\", \"b\"]')", ({"a", "b"}, set())),
                                     ("fromJSON('\"a\"')", ({"a"}, set())),
                                     ("fromJSON('{\"Mac\": [\"a\"]}').mac", ({"a"}, set())),
                                     ("fromJSON('{\"mac\": \"a\"}').linux", (set(), {"fromJSON('{\"mac\": \"a\"}').linux"})),
                                     ("fromJSON('not json')", (set(), {"fromJSON('not json')"})),
                                     ("fromJSON(needs.a.outputs.b)", (set(), {"fromJSON(needs.a.outputs.b)"}))):
            with self.subTest(expression=expression):
                self.assertEqual(wj.expression_values(expression), expected)

    def test_review_f1_a_label_inside_an_unresolved_part_is_read(self) -> None:
        label = "glaeda-runner-cmux22-new"
        findings = self.runs_on(f"${{{{ fromJSON(needs.a.outputs.x || '[\"{label}\"]') }}}}")
        self.assertTrue([f for f in findings if f"{label} is a single-host label" in f], findings)

    def test_review_f1_an_expression_the_resolver_cannot_settle_fails(self) -> None:
        """Fail closed: a part the resolver cannot settle may be any self-hosted label, so it is a finding, never
        skipped. Only a literal, a declared vars.NAME, a placement job's output or a caller-less input (and fromJSON
        of those) is settled."""
        for value in ("${{ format('{0}-{1}', needs.a.outputs.x, needs.a.outputs.y) }}",
                      "glaeda-${{ needs.a.outputs.x }}",
                      "${{ toJSON(needs.a.outputs.x) }}",
                      "${{ github.event.inputs.runner }}",
                      "${{ needs.a.outputs.x || format('{0}', 'y') }}"):
            with self.subTest(runs_on=value):
                findings = self.runs_on(value)
                self.assertTrue([f for f in findings if "cannot settle" in f], findings)
        matrix = ("jobs:\n  a:\n    strategy:\n      matrix: ${{ fromJSON(needs.p.outputs.m) }}\n"
                  "    runs-on: ${{ matrix.runner }}\n")
        findings = self.scan({"x.yml": matrix})
        self.assertTrue([f for f in findings if "cannot settle" in f], findings)

    def test_review_f1_a_settled_picker_still_passes(self) -> None:
        for value in ("${{ fromJSON(github.run_attempt > 1 && needs.r.outputs.retry || needs.r.outputs.runs_on) }}",
                      "${{ fromJSON(needs.p.outputs.runners || '{}')['cli-product'] }}",
                      "${{ (needs.p.outputs.a != '' && needs.p.outputs.a) || inputs.runner }}",
                      "${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}"):
            with self.subTest(runs_on=value):
                self.assertEqual(self.runs_on(value), [])


    def test_review_f3_a_literal_fromjson_runner_array_is_scanned(self) -> None:
        label = "glaeda-runner-cmux22-review"
        findings = self.runs_on(f"${{{{ fromJSON('[\"{label}\"]') }}}}")
        self.assertTrue([f for f in findings if f"{label} is a single-host label" in f], findings)

    def test_review_p2_an_unsettled_wrapped_reusable_input_is_not_accepted(self) -> None:
        callee = ("on:\n  workflow_call:\n    inputs:\n      runner: {type: string}\n"
                  "jobs:\n  a:\n    runs-on: ${{ format('{0}', inputs.runner) }}\n")
        caller = ("jobs:\n  c:\n    uses: ./.github/workflows/callee.yml\n    with:\n"
                  "      runner: ${{ vars.NEW_X }}\n")
        findings = self.scan({"callee.yml": callee, "caller.yml": caller})
        self.assertTrue([f for f in findings if "cannot settle" in f], findings)

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
        for key, value in git_fixture_env.OPT_OUT:  # in the repository's own config too
            self.git("config", key, value)
        shutil.copy(DECLARATION, self.repo / ".github" / "single-host-fallbacks.json")
        self.workflow("a.yml", "${{ vars.RUNNER_POOLS }}")
        self.base = self.commit("base")
        self.installed = Path(self.tmp.name) / "installed"
        self.installed.mkdir()

    def git(self, *args: str) -> str:
        # No GIT_* from the caller (a pre-push hook's GIT_DIR would aim this at the pushing repository), then
        # the helper's maintenance opt-out back on top.
        env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
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
        apt_dir = self.gate.APT_DIST_PACKAGES
        base = base_interpreter()
        with tempfile.TemporaryDirectory() as tmp:
            writable, stdlib = Path(tmp) / "site", Path(tmp) / "lib"
            writable.mkdir(); stdlib.mkdir()
            (Path(tmp) / "py 3").mkdir()
            python = str(Path(tmp) / "py 3" / "python3")
            os.symlink(base, python)
            quoted = shlex.quote(python)
            unwritable = str(Path(tmp) / "missing-site")
            # Codex on #40880 (F2): apt on the host says nothing about this interpreter. A venv or a custom Python whose
            # sys.path lacks apt's dist-packages gets pip, as -I (user site off), into its own prefix.
            self.assertEqual(command(python, str(writable), str(stdlib), apt=True, syspath=[str(writable)]),
                             f"{quoted} -I -m pip install PyYAML==6.0.3")
            self.assertEqual(command(python, unwritable, str(stdlib), apt=True, syspath=[unwritable]),
                             f"sudo {quoted} -I -m pip install PyYAML==6.0.3")
            # The interpreter apt's python3-yaml reaches: apt.
            self.assertEqual(command(python, unwritable, str(stdlib), apt=True, syspath=[unwritable, apt_dir]),
                             "sudo apt-get install -y python3-yaml")
            self.assertEqual(command(python, str(writable), str(stdlib), apt=False, syspath=[apt_dir]),
                             f"{quoted} -I -m pip install PyYAML==6.0.3")
            for line in (command(python, str(writable), str(stdlib), apt=True, syspath=[]),
                         command(python, unwritable, str(stdlib), apt=False, syspath=[])):
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

    def test_the_interpreters_own_sys_path_decides_the_apt_route(self) -> None:
        # Without SYSPATH the command reads the target interpreter's sys.path as the hook runs it (-I).
        command = self.gate.pyyaml_install_command(sys.executable, apt=True)
        reaches = self.gate.APT_DIST_PACKAGES in self.gate.interpreter_sys_path(sys.executable)
        self.assertEqual(command == "sudo apt-get install -y python3-yaml", reaches, command)

    def test_the_pep668_route_matrix(self) -> None:
        # Codex on leo-workspace#4198 (F1): a PEP 668 interpreter whose prefix this user can write (Homebrew) installs
        # with --break-system-packages; one whose prefix it cannot write (a system Python under /usr) refuses with what
        # to do; a venv, which reads its base's stdlib and so sees the marker (Codex on #40966), gets plain pip. The
        # decision is PEP668_ROUTE, the same text as leo-workspace machines/host-baseline.json's PyYAML install
        # carries; both repos pin its sha256 here, so a change to one side fails until the other matches.
        command = self.gate.pyyaml_install_command
        base = base_interpreter()
        with tempfile.TemporaryDirectory() as tmp:
            managed, plain, writable, env = (Path(tmp) / n for n in ("managed", "plain", "site", "venv"))
            for d in (managed, plain, writable):
                d.mkdir()
            (managed / "EXTERNALLY-MANAGED").write_text("", encoding="utf-8")
            unwritable = str(Path(tmp) / "missing-site")  # os.access says no even for root
            subprocess.run([base, "-I", "-m", "venv", "--without-pip", str(env)], check=True, capture_output=True)
            venv = str(env / "bin" / "python3")
            pin = "PyYAML==6.0.3"
            for python, stdlib, purelib, want, line in (
                    (base, managed, str(writable), "break",
                     f"{shlex.quote(base)} -I -m pip install --break-system-packages {pin}"),
                    (base, managed, unwritable, "refuse", None),
                    (venv, managed, str(writable), "pip", f"{shlex.quote(venv)} -I -m pip install {pin}"),
                    (base, plain, str(writable), "pip", f"{shlex.quote(base)} -I -m pip install {pin}"),
                    (base, plain, unwritable, "sudo-pip", f"sudo {shlex.quote(base)} -I -m pip install {pin}")):
                with self.subTest(python=python, stdlib=stdlib.name, purelib=purelib, want=want):
                    got = command(python, purelib, str(stdlib), apt=False, syspath=[])
                    if line is None:
                        self.assertIn("externally managed", got)
                        self.assertNotIn("pip install", got)
                    else:
                        self.assertEqual(got, line)
                    self.assertEqual(self.gate.pep668_route(python, str(stdlib), purelib), want)
        # Last, so a behavior regression fails on behavior first: the route text is leo-workspace's, byte for byte.
        self.assertEqual(hashlib.sha256(self.gate.PEP668_ROUTE.encode()).hexdigest(), PEP668_ROUTE_SHA256)

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



class DeletedCheckInputs(unittest.TestCase):
    """Review F1 on #40894 (P1, security): the layer skipped the scan whenever HEAD lacked
    .github/single-host-fallbacks.json, base or no base, so a push that deleted the declaration and added an
    undeclared `runs-on: ${{ vars.X }}` passed. The class: an exemption "HEAD has no such file, so the check does not
    apply" holds only for a branch older than the file, whose base lacks it too (deleted_inputs). Each check that
    keys an exemption on a file at HEAD (the fallback declaration, the Ghostty reserved-keys list and the surfaces it
    judges against, and the check script itself through check_script) has a row here."""

    # PrepushGateLayer's fixture (a repository whose base has the declaration), without rerunning its tests.
    setUpClass = vars(PrepushGateLayer)["setUpClass"]
    setUp, git, workflow, commit, checker, layer = (vars(PrepushGateLayer)[name] for name in (
        "setUp", "git", "workflow", "commit", "checker", "layer"))

    def delete_declaration(self) -> None:
        (self.repo / ".github" / "single-host-fallbacks.json").unlink()

    def test_deleting_the_declaration_with_an_undeclared_variable_refuses(self) -> None:
        self.checker(None)
        self.delete_declaration()
        self.workflow("c.yml", "${{ vars.NEW_X }}")
        head = self.commit("delete the declaration, add an undeclared variable")
        for trusted in (self.installed, None):  # the hook's installed copy, and a manual run
            with self.subTest(trusted=trusted), contextlib.redirect_stderr(io.StringIO()):
                refused = self.gate.single_host_fallback_problems(self.repo, self.base, head, trusted)
                self.assertEqual(len(refused), 1, refused)
                self.assertIn("deletes .github/single-host-fallbacks.json", refused[0])
                self.assertIsInstance(refused[0], self.gate.NoVerdict)

    def test_deleting_the_declaration_alone_refuses(self) -> None:
        self.checker(None)
        self.delete_declaration()
        self.commit("delete the declaration")
        refused = self.layer()
        self.assertEqual(len(refused), 1, refused)
        self.assertIn("deletes .github/single-host-fallbacks.json", refused[0])

    def test_a_branch_whose_base_lacks_the_declaration_stays_exempt(self) -> None:
        self.checker(None)
        self.delete_declaration()
        self.base = self.commit("a base older than the declaration")
        self.workflow("c.yml", "${{ vars.NEW_X }}")
        self.commit("head")
        self.assertEqual(self.layer(), [])

    def test_a_directory_or_dangling_symlink_declaration_refuses_the_scan(self) -> None:
        self.checker(None)
        declaration = self.repo / ".github" / "single-host-fallbacks.json"
        for kind in ("directory", "dangling symlink"):
            with self.subTest(kind=kind):
                self.git("checkout", "-q", "--detach", self.base)
                declaration.unlink()
                if kind == "directory":
                    declaration.mkdir()
                    (declaration / "placeholder").write_text("not a declaration\n", encoding="utf-8")
                else:
                    declaration.symlink_to("missing-declaration.json")
                self.workflow("c.yml", "${{ vars.NEW_X }}")
                head = self.commit(f"malformed declaration: {kind}")
                refused = self.gate.single_host_fallback_problems(self.repo, self.base, head, self.installed)
                self.assertEqual(len(refused), 1, refused)
                self.assertIn("must be a regular file", refused[0])

    def write(self, path: str, text: str) -> None:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def test_deleting_what_the_reserved_keys_check_reads_refuses(self) -> None:
        checker = "import sys\nsys.exit(0)\n"
        self.write(self.gate.RESERVED_SCRIPT, checker)
        self.write(self.gate.RESERVED_LIST, "[]\n")
        self.write(self.gate.RESERVED_SURFACES, "{}\n")
        self.base = self.commit("base with the reserved keys check")
        (self.installed / Path(self.gate.RESERVED_SCRIPT).name).write_text(checker, encoding="utf-8")
        for path in (self.gate.RESERVED_LIST, self.gate.RESERVED_SURFACES):
            with self.subTest(path=path):
                self.git("checkout", "-q", "--detach", self.base)
                (self.repo / path).unlink()
                head = self.commit(f"delete {path}")
                for trusted in (self.installed, None):
                    refused = self.gate.reserved_keys(self.repo, self.base, head, trusted)
                    self.assertEqual(len(refused), 1, refused)
                    self.assertIn(f"deletes {path}", refused[0])
        # A branch older than the check (its base has none of it) stays exempt.
        self.git("checkout", "-q", "--detach", self.base)
        for path in (self.gate.RESERVED_SCRIPT, self.gate.RESERVED_LIST, self.gate.RESERVED_SURFACES):
            (self.repo / path).unlink()
        older = self.commit("older than the check")
        self.assertEqual(self.gate.reserved_keys(self.repo, older, older, None), [])

    def test_a_deleted_check_script_still_runs(self) -> None:
        self.write(self.gate.UI_FONT_SCRIPT, "BASE = 1\n")
        self.base = self.commit("base with the check")
        (self.repo / self.gate.UI_FONT_SCRIPT).unlink()
        head = self.commit("delete the check")
        installed = self.installed / Path(self.gate.UI_FONT_SCRIPT).name
        installed.write_text("INSTALLED = 1\n", encoding="utf-8")
        check_script = self.gate.check_script
        self.assertEqual(check_script(self.repo, head, self.gate.UI_FONT_SCRIPT, self.installed, self.base),
                         b"INSTALLED = 1\n")
        self.assertEqual(check_script(self.repo, head, self.gate.UI_FONT_SCRIPT, None, self.base), b"BASE = 1\n")
        installed.unlink()  # an install without the check this push's base has refuses, never skips
        with self.assertRaises(SystemExit):
            check_script(self.repo, head, self.gate.UI_FONT_SCRIPT, self.installed, self.base)
        # A branch older than the check: neither side has it.
        self.assertIsNone(check_script(self.repo, head, self.gate.UI_FONT_SCRIPT, self.installed, head))


if __name__ == "__main__":
    sys.exit(unittest.main())
