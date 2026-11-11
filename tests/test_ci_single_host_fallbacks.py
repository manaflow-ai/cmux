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


if __name__ == "__main__":
    sys.exit(unittest.main())
