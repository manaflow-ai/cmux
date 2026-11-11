#!/usr/bin/env python3
"""tests/shell_invocations.py against real bash: every fixture runs with each command stubbed to log its name, and
the programs invocations() reports must be exactly the stubs bash ran. Run: python3 tests/test_shell_invocations.py"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from shell_invocations import invocations  # noqa: E402

STUBS = ("a", "b", "c", "sign", "create")

# (name, script, the stubs bash runs). Scripts use only the stubs plus echo, printf and cat.
FIXTURES = [
    ("plain commands", "a\nb", {"a", "b"}),
    ("a quoted semicolon is an argument (hq#9150 F1)", 'echo ";" sign', set()),
    ("a quoted ampersand and pipe are arguments", "echo '&&' sign '|' a", set()),
    ("an escaped semicolon is an argument", "echo \\; sign", set()),
    ("a quoted << opens no heredoc and swallows nothing (hq#9150 F1)", "printf '%s\\n' '<<' EOF >/dev/null\nsign\nb", {"sign", "b"}),
    ("a double-quoted << opens no heredoc", 'printf "%s\\n" "<<" EOF >/dev/null\nsign', {"sign"}),
    ("an indented terminator under << is body (hq#9150 F2)", "cat <<EOF >/dev/null\nbody\n  EOF\nsign\nEOF\nb", {"b"}),
    ("a tab-indented terminator under <<- ends it (hq#9150 F2)", "cat <<-EOF >/dev/null\nbody\n\tEOF\nsign", {"sign"}),
    ("a space-indented terminator under <<- is body", "cat <<-EOF >/dev/null\nbody\n  EOF\nsign\n\tEOF\nb", {"b"}),
    ("a terminator with trailing space is body", "cat <<EOF >/dev/null\nEOF \nsign\nEOF\nb", {"b"}),
    ("two heredocs on a line, bodies in order", "cat <<A <<B >/dev/null\nx\nA\nsign\nB\nb", {"b"}),
    ("two heredocs, quoted delimiters", "cat <<'A' <<\"B\" >/dev/null\nx\nA\nsign\nB\nb", {"b"}),
    ("a heredoc body names commands", "cat <<'EOF' >/dev/null\nsign\nEOF\na", {"a"}),
    ("a command after the heredoc operator on its line", "cat <<EOF >/dev/null && a\nsign\nEOF\nb", {"a", "b"}),
    ("a here-string is no heredoc", "cat <<< x >/dev/null\nsign", {"sign"}),
    ("a comment names a command", "# sign\na # b\nb", {"a", "b"}),
    ("&&, || and ; separate commands", "a && b; c; false || sign", {"a", "b", "c", "sign"}),
    ("a pipe runs both sides", "a | b", {"a", "b"}),
    ("a backgrounded command", "a & b; wait", {"a", "b"}),
    ("an if condition and its branch", "if a; then b; fi", {"a", "b"}),
    ("a negated command", "! a", {"a"}),
    ("an env assignment before a command", "X=1 a", {"a"}),
    ("a quoted assignment value", 'X="p q" a', {"a"}),
    ("a command substitution runs its command", 'x=$(a)\necho "$x" >/dev/null', {"a"}),
    ("a quoted program name", '"a"', {"a"}),
    ("a redirection first", ">/dev/null a", {"a"}),
    ("a descriptor redirection", "a 2>/dev/null\nb 2>&1", {"a", "b"}),
    ("a quoted string over lines is one argument", 'echo "x\nsign\ny"\nb', {"b"}),
    ("a backslash continuation", "a \\\n  b", {"a"}),
    ("a brace group", "{ a; b; }", {"a", "b"}),
    ("a subshell", "(a; b)", {"a", "b"}),
    ("a quoted keyword is a command, not a keyword", '"if" a', set()),
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


def reported(script: str) -> set[str]:
    return {words[0] for words in invocations(script)} & set(STUBS)


class AgainstBash(unittest.TestCase):
    def test_every_fixture_reports_what_bash_runs(self) -> None:
        for name, script, expected in FIXTURES:
            with self.subTest(name):
                self.assertEqual(ran_in_bash(script), expected, f"the fixture is wrong about bash: {script!r}")
                self.assertEqual(reported(script), expected, f"invocations() disagrees with bash on {script!r}")

    def test_the_quoted_semicolon_is_one_command(self) -> None:
        self.assertEqual(invocations('echo ";" python3 x'), [["echo", ";", "python3", "x"]])

    def test_a_shell_running_a_script_reports_the_script(self) -> None:
        self.assertEqual(invocations("bash -e ./sign.sh app"), [["sign.sh", "app"]])

    def test_an_unterminated_quote_runs_nothing_after_it(self) -> None:
        self.assertEqual(invocations("a\necho 'oops\nsign"), [["a"], ["echo"]])


if __name__ == "__main__":
    unittest.main()
