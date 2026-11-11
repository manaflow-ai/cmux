#!/usr/bin/env python3
"""tests/shell_invocations.py against real bash: every fixture runs with each command stubbed to log its name, and
the answer must be sound in both directions a caller reads it: must_run() is a subset of the stubs bash ran, and
the stubs bash ran are a subset of what may_run() allows. A fixture with no construct the detector flags as uncertain
must also match exactly. Run: python3 tests/test_shell_invocations.py"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_invocations import may_run, may_run_program, must_run  # noqa: E402

STUBS = ("a", "b", "c", "sign", "create")

# (name, script, the stubs bash runs, the stubs must_run() reports or None for "the same as bash ran")
FIXTURES = [
    ("plain commands", "a\nb", {"a", "b"}, None),
    ("a quoted semicolon is an argument (hq#9150 F1)", 'echo ";" sign', set(), None),
    ("a quoted ampersand and pipe are arguments", "echo '&&' sign '|' a", set(), None),
    ("an escaped semicolon is an argument", "echo \\; sign", set(), None),
    ("a quoted << opens no heredoc and swallows nothing (hq#9150 F1)", "printf '%s\\n' '<<' EOF >/dev/null\nsign\nb", {"sign", "b"}, None),
    ("a double-quoted << opens no heredoc", 'printf "%s\\n" "<<" EOF >/dev/null\nsign', {"sign"}, None),
    ("an indented terminator under << is body (hq#9150 F2)", "cat <<EOF >/dev/null\nbody\n  EOF\nsign\nEOF\nb", {"b"}, None),
    ("a tab-indented terminator under <<- ends it (hq#9150 F2)", "cat <<-EOF >/dev/null\nbody\n\tEOF\nsign", {"sign"}, None),
    ("a space-indented terminator under <<- is body", "cat <<-EOF >/dev/null\nbody\n  EOF\nsign\n\tEOF\nb", {"b"}, None),
    ("a terminator with trailing space is body", "cat <<EOF >/dev/null\nEOF \nsign\nEOF\nb", {"b"}, None),
    ("two heredocs on a line, bodies in order", "cat <<A <<B >/dev/null\nx\nA\nsign\nB\nb", {"b"}, None),
    ("two heredocs, quoted delimiters", "cat <<'A' <<\"B\" >/dev/null\nx\nA\nsign\nB\nb", {"b"}, None),
    ("a heredoc body names commands", "cat <<'EOF' >/dev/null\nsign\nEOF\na", {"a"}, None),
    ("a command after the heredoc operator on its line", "cat <<EOF >/dev/null && a\nsign\nEOF\nb", {"a", "b"}, None),
    ("a here-string is no heredoc", "cat <<< x >/dev/null\nsign", {"sign"}, None),
    ("a comment names a command", "# sign\na # b\nb", {"a", "b"}, None),
    ("&&, || and ; separate commands", "a && b; c; false || sign", {"a", "b", "c", "sign"}, None),
    ("a pipe runs both sides", "a | b", {"a", "b"}, None),
    ("a backgrounded command", "a & b; wait", {"a", "b"}, None),
    ("an if condition and its branch", "if a; then b; fi", {"a", "b"}, None),
    ("a negated command", "! a", {"a"}, None),
    ("an env assignment before a command", "X=1 a", {"a"}, None),
    ("a quoted assignment value", 'X="p q" a', {"a"}, None),
    ("a quoted program name", '"a"', {"a"}, None),
    ("a redirection first", ">/dev/null a", {"a"}, None),
    ("a descriptor redirection", "a 2>/dev/null\nb 2>&1", {"a", "b"}, None),
    ("a quoted string over lines is one argument", 'echo "x\nsign\ny"\nb', {"b"}, None),
    ("a backslash continuation", "a \\\n  b", {"a"}, None),
    ("a brace group", "{ a; b; }", {"a", "b"}, None),
    ("a subshell", "(a; b)", {"a", "b"}, None),
    ("a quoted keyword is a command, not a keyword", '"if" a', set(), None),
    ("a variable in an argument does not hide the program", "x=1\necho $x sign", set(), None),
    ("an array value is not a command", "x=(a sign)\nb", {"b"}, None),
    ("an array assignment before a command", "x=(a) b", {"b"}, None),
    ("an array element substitution runs", "x=($(a))\nb", {"a", "b"}, {"b"}),
    ("an appended array", "x+=(sign)\nb", {"b"}, None),
    ("a single-quoted dollar is text", "echo '$(sign)' b", set(), None),
    # Uncertain constructs: must_run() leaves the command out, may_run() still allows what bash ran.
    ("an argument after a substitution (hq reviewer F2)", "echo $(true) sign", set(), set()),
    ("an argument after a nested substitution", "echo $(echo $(true)) sign", set(), set()),
    ("an argument after backticks", "echo `true` sign", set(), set()),
    ("an argument after nested backticks and a substitution", "echo `echo $(true)` sign", set(), set()),
    ("an argument after a process substitution", "cat <(true) sign >/dev/null", set(), set()),
    ("an argument after an arithmetic expansion", "echo $((1+2)) sign", set(), None),
    ("an argument after a parameter expansion with spaces", 'echo ${x:-p q} sign', set(), None),
    ("a substitution runs its command", "x=$(a)\necho \"$x\" >/dev/null", {"a"}, set()),
    ("a substitution in a double-quoted argument", 'echo "$(a)" sign', {"a"}, set()),
    ("a backtick runs its command", "x=`a`", {"a"}, set()),
    ("a nested substitution runs both", "x=$(echo $(a); b)", {"a", "b"}, set()),
    ("a substitution holding a quoted paren", "x=$(echo ')' ; a)", {"a"}, set()),
    ("a process substitution runs its command", "cat <(a) <(b) >/dev/null", {"a", "b"}, set()),
    ("an unquoted heredoc body substitution runs", "cat <<EOF >/dev/null\n$(a)\nEOF\nb", {"a", "b"}, {"b"}),
    ("a quoted heredoc body substitution is text", "cat <<'EOF' >/dev/null\n$(a)\nEOF\nb", {"b"}, None),
    ("eval runs its argument", "eval a", {"a"}, set()),
    ("a function runs its body when called", "f() { a; }\nf", {"a"}, set()),
    ("a function that is never called runs nothing", "f() { a; }\nb", {"b"}, set()),
    ("an alias is not expanded in a non-interactive shell", "alias sign=a\nb", {"b"}, set()),
    ("a variable as the program", "p=a\n$p", {"a"}, set()),
    ("a substitution as the program", "$(echo a)", {"a"}, set()),
]


def stub_prelude(log: Path) -> str:
    return "".join(f'{name}() {{ echo {name} >> "{log}"; }}\n' for name in STUBS)


def ran_in_bash(script: str) -> set[str]:
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp) / "ran"
        log.touch()
        subprocess.run(["bash", "--noprofile", "--norc", "-c", stub_prelude(log) + script],
                       capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        return set(log.read_text().split())


def certain(script: str) -> set[str]:
    return {words[0] for words in must_run(script)} & set(STUBS)


def possible(script: str) -> set[str]:
    return {name for name in STUBS if may_run_program(script, name)}


class AgainstBash(unittest.TestCase):
    def test_every_fixture_is_sound_in_both_directions(self) -> None:
        for name, script, ran, expected_certain in FIXTURES:
            with self.subTest(name):
                self.assertEqual(ran_in_bash(script), ran, f"the fixture is wrong about bash: {script!r}")
                must = certain(script)
                self.assertLessEqual(must, ran, f"must_run() credits a command bash did not run: {script!r}")
                self.assertLessEqual(ran, possible(script), f"may_run() misses a command bash ran: {script!r}")
                want = ran if expected_certain is None else expected_certain
                self.assertEqual(must, want, f"must_run() answers {must} for {script!r}")

    def test_a_certain_command_is_not_flagged_and_an_uncertain_one_is(self) -> None:
        by_word = {tuple(invocation.words[:1]): invocation for invocation in may_run("echo $(true) ./sign.sh\na")}
        self.assertFalse(by_word[("echo",)].certain)
        self.assertTrue(by_word[("a",)].certain)
        self.assertEqual(must_run("echo $(true) ./sign.sh\na"), [["a"]])

    def test_the_reviewer_cases(self) -> None:
        self.assertEqual(must_run('echo ";" python3 x'), [["echo", ";", "python3", "x"]])
        script = "echo $(true) ./scripts/ci/release-signer/sign-app.sh"
        self.assertNotIn("scripts/ci/release-signer/sign-app.sh", [words[0] for words in must_run(script)])
        self.assertFalse(may_run_program(script, "scripts/ci/release-signer/sign-app.sh"))
        self.assertTrue(may_run_program("eval ./scripts/ci/release-signer/sign-app.sh", "scripts/ci/release-signer/sign-app.sh"))
        self.assertTrue(may_run_program("x=$(./scripts/ci/release-signer/sign-app.sh)", "scripts/ci/release-signer/sign-app.sh"))

    def test_a_shell_running_a_script_reports_the_script(self) -> None:
        self.assertEqual(must_run("bash -e ./sign.sh app"), [["sign.sh", "app"]])

    def test_an_unlexable_script_may_run_anything_after_the_point_it_stopped(self) -> None:
        self.assertEqual(must_run("a\necho 'oops\nsign"), [["a"]])
        self.assertTrue(may_run_program("a\necho 'oops\nsign", "sign"))
        self.assertTrue(may_run_program("a\necho $(b", "sign"))
        self.assertFalse(may_run_program("a\necho b", "sign"))

    def test_there_is_no_default_reading(self) -> None:
        import shell_invocations
        self.assertFalse(hasattr(shell_invocations, "invocations"))


if __name__ == "__main__":
    unittest.main()
