"""scripts/ci/cargo_test_verdict.py: a red pull request `cargo test` run passes only when each failing test is a
flake (it passed run again alone) or fails on the merge base too; a crash, a cut-short binary, a compile error or a
test the base passes is the change's own red."""
import importlib.util
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cargo_test_verdict.py"
spec = importlib.util.spec_from_file_location("cargo_test_verdict", SCRIPT)
verdict = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verdict)

JOB = "acpmux tests"


def binary(*results, total=None):
    """One cargo test binary's output: `test NAME ... ok|FAILED` lines and its closing `test result:` line."""
    lines = [f"running {total if total is not None else len(results)} tests"]
    failed = [name for name, outcome in results if outcome == "FAILED"]
    lines += [f"test {name} ... {outcome}" for name, outcome in results]
    if failed:
        lines += ["", "failures:", ""] + [f"    {name}" for name in failed]
    state = "FAILED" if failed else "ok"
    lines.append(f"test result: {state}. {len(results) - len(failed)} passed; {len(failed)} failed; 0 ignored; "
                 "0 measured; 0 filtered out; finished in 1.00s")
    return "\n".join(lines)


def log(*binaries):
    return "\n\n".join(binaries) + "\n"


HEAD = log(
    binary(("hub::inbox_tests::keeps_order", "ok"), ("hub::turn_cap_tests::caps", "FAILED")),
    binary(("agent_inbox::delivers", "FAILED"), ("carried_turns::carries", "ok")),
)


class Judge(unittest.TestCase):
    def judge(self, head, retry=None, base=None):
        return verdict.judge(head, retry, base, JOB)

    def test_failed_names_cover_every_binary(self):
        self.assertEqual(verdict.failed_names(HEAD), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])

    def test_a_test_the_base_passes_is_the_changes_own(self):
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        own, notes = self.judge(HEAD, base=base)
        self.assertTrue(own)
        self.assertTrue(any(n.startswith("::error") and "agent_inbox::delivers" in n for n in notes), notes)

    def test_a_test_missing_on_the_base_is_the_changes_own(self):
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(total=0))
        own, _ = self.judge(HEAD, base=base)
        self.assertTrue(own)

    def test_every_test_failing_on_the_base_too_warns(self):
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "FAILED")))
        own, notes = self.judge(HEAD, base=base)
        self.assertFalse(own)
        self.assertEqual(sum(n.startswith("::warning") and "(base red)" in n for n in notes), 2, notes)

    def test_no_base_log_excuses_nothing(self):
        own, _ = self.judge(HEAD)
        self.assertTrue(own)

    def test_a_test_that_passes_alone_is_a_flake(self):
        retry = log(binary(("hub::turn_cap_tests::caps", "ok")), binary(("agent_inbox::delivers", "ok")))
        own, notes = self.judge(HEAD, retry=retry)
        self.assertFalse(own)
        self.assertEqual(sum("(flaky)" in n for n in notes), 2, notes)

    def test_a_flake_and_a_base_red_together_pass(self):
        retry = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(total=0))
        own, notes = self.judge(HEAD, retry=retry, base=base)
        self.assertFalse(own, notes)

    def test_a_flake_does_not_hide_a_new_red(self):
        retry = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        base = log(binary(("hub::turn_cap_tests::caps", "ok")), binary(total=0))
        own, notes = self.judge(HEAD, retry=retry, base=base)
        self.assertTrue(own)
        self.assertTrue(any(n.startswith("::error") and "hub::turn_cap_tests::caps" in n for n in notes), notes)

    def test_a_crashed_binary_is_the_changes_own_even_when_the_base_crashes(self):
        crashed = log(
            binary(("hub::turn_cap_tests::caps", "ok")),
            "running 2 tests\ntest agent_inbox::delivers ... ok\n"
            "error: test failed, to rerun pass `--test hub_integration`\n\n"
            "Caused by:\n  process didn't exit successfully: `target/debug/deps/hub_integration-abc` "
            "(signal: 6, SIGABRT: process abort signal)",
        )
        own, notes = self.judge(crashed, retry=crashed, base=crashed)
        self.assertTrue(own)
        self.assertTrue(any("crashed" in n for n in notes), notes)

    def test_a_binary_that_never_finished_is_the_changes_own(self):
        cut = log(binary(("hub::turn_cap_tests::caps", "FAILED")), "running 3 tests\ntest agent_inbox::delivers ... ok")
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")))
        own, notes = self.judge(cut, base=base)
        self.assertTrue(own)
        self.assertTrue(any("not whole" in n for n in notes), notes)

    def test_a_compile_error_is_the_changes_own(self):
        own, notes = self.judge("error[E0425]: cannot find value `x` in this scope\nerror: could not compile `acpmux`\n")
        self.assertTrue(own)
        self.assertTrue(any("named no failing test" in n for n in notes), notes)

    def test_a_missing_head_log_is_the_changes_own(self):
        self.assertTrue(self.judge(None)[0])
        self.assertTrue(self.judge("")[0])

    def test_timestamps_and_colours_are_read(self):
        stamped = "\n".join(f"2026-10-31T01:02:03.4567890Z \x1b[0m{line}" for line in HEAD.splitlines())
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "FAILED")))
        self.assertEqual(verdict.failed_names(stamped), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])
        self.assertFalse(self.judge(stamped, base=base)[0])
        retry = log(binary(("hub::turn_cap_tests::caps", "ok")), binary(("agent_inbox::delivers", "ok")))
        self.assertFalse(self.judge(stamped, retry=retry)[0])


def workflow_paths(workflow: str) -> dict[str, list[str]]:
    """Each trigger's `paths:` globs in WORKFLOW, read without a YAML parser."""
    found, event, inside = {}, None, False
    for line in workflow.splitlines():
        if match := re.match(r"^  (push|pull_request):", line):
            event, inside = match.group(1), False
        elif re.match(r"^\S", line):
            event = None
        elif event and re.match(r"^    paths:", line):
            inside = True
            found[event] = []
        elif inside and (match := re.match(r'^      - "([^"]+)"', line)):
            found[event].append(match.group(1))
        elif inside and not re.match(r"^\s*(#.*)?$", line):
            inside = False
    return found


def glob_matches(glob: str, path: str) -> bool:
    pattern = "".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                      for part in re.split(r"(\*\*|\*)", glob))
    return re.fullmatch(pattern, path) is not None


class Scope(unittest.TestCase):
    CRATE = "cmux-tui/crates/acpmux"

    def test_the_crate_its_path_dependencies_and_their_includes_are_inputs(self):
        dirs, files = verdict.crate_inputs(ROOT, self.CRATE)
        self.assertIn(self.CRATE, dirs)
        self.assertIn("cmux-tui/crates/cmux-server", dirs)  # a direct path dependency
        self.assertIn("cmux-tui/crates/cmux-json", dirs)  # through `workspace = true`
        self.assertIn("skills/cmux-cua/SKILL.md", files)  # include_str! from outside the crates
        changed = ["cmux-tui/crates/cmux-json/src/lib.rs", "skills/cmux-cua/SKILL.md", "cmux-tui/Cargo.lock",
                   "README.md", "webviews/src/app.tsx", "cmux-tui/crates/ghostty-vt/src/lib.rs"]
        self.assertEqual(verdict.touches(ROOT, self.CRATE, changed), changed[:3])

    def test_the_workflow_runs_for_every_included_file_outside_cmux_tui(self):
        _, files = verdict.crate_inputs(ROOT, self.CRATE)
        outside = [path for path in files if not path.startswith("cmux-tui/")]
        self.assertTrue(outside)
        paths = workflow_paths((ROOT / ".github/workflows/cmux-tui-spec.yml").read_text())
        self.assertEqual(set(paths), {"push", "pull_request"})
        for event, globs in paths.items():
            for path in outside + [p.rstrip("/") + ("/x" if p.endswith("/") else "") for p in verdict.ALWAYS]:
                with self.subTest(event=event, path=path):
                    self.assertTrue(any(glob_matches(glob, path) for glob in globs),
                                    f"cmux-tui-spec.yml's {event} paths miss {path}, an input of acpmux's tests")


class Cli(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False,
                              stdin=subprocess.DEVNULL)

    def test_failed_and_judge(self):
        with tempfile.TemporaryDirectory() as tmp:
            head, base = Path(tmp, "head.log"), Path(tmp, "base.log")
            head.write_text(HEAD)
            base.write_text(log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok"))))
            out = self.run_cli("failed", str(head))
            self.assertEqual(out.stdout.split(), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])
            out = self.run_cli("judge", "--head", str(head), "--base", str(base), "--retry", str(Path(tmp, "none")),
                               "--job", JOB)
            self.assertEqual(out.returncode, 1, out.stdout + out.stderr)
            self.assertIn("::error title=acpmux tests::", out.stdout)
            base.write_text(log(binary(("hub::turn_cap_tests::caps", "FAILED")),
                                binary(("agent_inbox::delivers", "FAILED"))))
            out = self.run_cli("judge", "--head", str(head), "--base", str(base), "--job", JOB)
            self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def test_touches(self):
        run = lambda changed: subprocess.run(  # noqa: E731
            [sys.executable, str(SCRIPT), "touches", "cmux-tui/crates/acpmux", "--repo", str(ROOT)],
            input=changed, capture_output=True, text=True, check=False)
        out = run("README.md\ncmux-tui/crates/cmux-server/src/lib.rs\n")
        self.assertEqual((out.returncode, out.stdout), (0, "cmux-tui/crates/cmux-server/src/lib.rs\n"), out.stderr)
        out = run("README.md\n")
        self.assertEqual((out.returncode, out.stdout), (1, ""), out.stderr)


if __name__ == "__main__":
    unittest.main()
