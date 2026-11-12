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


def coloured(text):
    """TEXT as cargo prints it to a colour terminal: each outcome and the summary's state in its own colour codes,
    each line stamped as the job log serves it."""
    for word, code in (("FAILED", 31), ("ok", 32)):
        text = re.sub(rf"(\.\.\. |test result: ){word}\b",
                      lambda m, word=word, code=code: f"{m.group(1)}\x1b[{code}m{word}\x1b[0m", text)
    return "\n".join(f"2026-10-31T01:02:03.4567890Z {line}" for line in text.splitlines())


class ColouredSummary(unittest.TestCase):
    """#41329's review F2: "scripts/ci/cargo_test_verdict.py:160: the summary rewrite searches the raw line, so ANSI
    codes around FAILED stop it matching. The flaky result drops out while its failure count stays, and judge() calls
    a passing retry an own red. Rewrite the normalized summary, and add a fixture with inline colour codes." And
    "strip ANSI once, at the log reader, so no parser sees raw colour"."""

    # One binary, a flake and a base red in it: taking the flake out leaves `1 failed`, its one named failure.
    HEAD = log(binary(("hub::turn_cap_tests::caps", "FAILED"), ("agent_inbox::delivers", "FAILED"),
                      ("carried_turns::carries", "ok")))
    RETRY = log(binary(("hub::turn_cap_tests::caps", "ok"), ("agent_inbox::delivers", "FAILED")))
    BASE = log(binary(("hub::turn_cap_tests::caps", "ok"), ("agent_inbox::delivers", "FAILED")))

    def test_a_flake_in_a_coloured_binary_leaves_its_count_matching_its_names(self):
        head = coloured(self.HEAD)
        self.assertIn("test result: \x1b[31mFAILED\x1b[0m. 1 passed; 2 failed;", head)
        out = verdict.without_failures(head, {"hub::turn_cap_tests::caps"})
        self.assertEqual([line for line in verdict.test_reds.lines_of(out) if line.startswith("test result: ")],
                         ["test result: FAILED. 2 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out; "
                          "finished in 1.00s"])
        own, notes = verdict.judge(head, coloured(self.RETRY), coloured(self.BASE), JOB)
        self.assertFalse(own, notes)
        self.assertEqual(sum("(flaky)" in n for n in notes), 1, notes)
        self.assertEqual(sum("(base red)" in n for n in notes), 1, notes)

    def test_the_log_reader_strips_colour_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "head.log")
            path.write_text(coloured(self.HEAD) + "\n\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07\n")
            text = verdict.read_text(path)
        self.assertNotIn("\x1b", text)
        self.assertIn("test result: FAILED. 1 passed; 2 failed;", text)


class TitleSequencesKeepTheLinesBetweenThem(unittest.TestCase):
    """#41382's review F1 (test_reds.py:64): "The OSC pattern is greedy and runs to the last ESC \\ in the log, so
    plain() deletes every line between two title sequences. Reproduced through cargo_test_verdict.read_text: a head
    with one new and one existing failure loses the new one, and judge() excuses it."""

    TITLE = "\x1b]0;cargo test\x1b\\"

    def test_a_new_failure_between_two_titles_is_the_changes_own(self):
        head = log(binary(("hub::turn_cap_tests::caps", "FAILED")),
                   self.TITLE + binary(("agent_inbox::delivers", "FAILED")), self.TITLE + "done")
        base = log(binary(("hub::turn_cap_tests::caps", "FAILED")), binary(("agent_inbox::delivers", "ok")))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "head.log")
            path.write_text(head)
            text = verdict.read_text(path)
        self.assertEqual(verdict.failed_names(text), ["agent_inbox::delivers", "hub::turn_cap_tests::caps"])
        own, notes = verdict.judge(text, None, base, JOB)
        self.assertTrue(own, notes)
        self.assertTrue(any(n.startswith("::error") and "agent_inbox::delivers" in n for n in notes), notes)


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


class Running(unittest.TestCase):
    """A run cut short by the job's timeout names the test it was waiting on (cmux job 130955236972, 2026-11-12: the
    acpmux lib's run was cancelled at 40 min while one list test had run 35 min, and the log named nothing)."""

    CUT = "\n".join([
        "2026-11-12T03:42:42.7815755Z running 5292 tests",
        "2026-11-12T03:42:42.7825519Z test acp_todo_plan::tests::a ... ok",
        "2026-11-12T03:44:46.7293584Z test server::list_fit_tests::b has been running for over 60 seconds",
        "2026-11-12T03:44:50.2501733Z test server::list_web_page_tests::c has been running for over 60 seconds",
        "2026-11-12T03:45:00.3448379Z \x1b[0mtest server::reply_size_tests::d has been running for over 60 seconds",
        "2026-11-12T03:46:48.4522430Z test server::reply_size_tests::d ... \x1b[32mok\x1b[0m",
        "2026-11-12T03:53:06.8139680Z test server::list_fit_tests::b ... ok",
        "2026-11-12T04:18:43.7625057Z ##[error]The operation was canceled.",
    ]) + "\n"

    def test_the_test_still_running_at_the_cut_is_named(self):
        self.assertEqual(verdict.running_names(verdict.test_reds.plain(self.CUT)),
                         ["server::list_web_page_tests::c"])

    def test_a_finished_binary_names_nothing_and_a_new_binary_starts_over(self):
        finished = self.CUT.replace("##[error]The operation was canceled.",
                                    "test server::list_web_page_tests::c ... ok")
        self.assertEqual(verdict.running_names(finished), [])
        second = log(binary(("x::slow", "ok")), "running 2 tests\ntest y::hung has been running for over 60 seconds")
        self.assertEqual(verdict.running_names(second), ["y::hung"])

    def test_the_cli_prints_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "head.log"
            path.write_text(self.CUT)
            out = subprocess.run([sys.executable, str(SCRIPT), "running", str(path)], capture_output=True, text=True)
        self.assertEqual((out.returncode, out.stdout), (0, "server::list_web_page_tests::c\n"), out.stderr)


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
        # Pull requests carry no paths: feat-cmux-next requires the clippy job, so the workflow runs on every
        # one and its `changes` job routes them by these `push` paths (.github/scripts/cmux-tui-spec-changed.py).
        self.assertEqual(set(paths), {"push"})
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
