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


# Shell modes and wrappers (#40846 F1): bash runs each with `./sign.sh` an executable that logs `sign.sh` to a marker
# file when it runs (an absolute path, so `env -i` and `exec -c` keep it), and `a` an executable on PATH. Fixture:
# (script, whether bash runs sign.sh, whether must_run() may credit it). A mode that does not run the first operand
# as a script is never certain; a fixture bash runs but the model calls uncertain must still be allowed by may_run.
SCRIPT_FIXTURES = [
    ("bash ./sign.sh", True, True),
    ("bash -e ./sign.sh", True, True),
    ("bash -eux ./sign.sh 2>/dev/null", True, True),
    ("bash --noprofile --norc ./sign.sh", True, True),
    ("bash -- ./sign.sh", True, True),
    ("bash - ./sign.sh", True, True),
    ("sh ./sign.sh", True, True),
    ("bash -n ./sign.sh", False, False),
    ("sh -n ./sign.sh", False, False),
    ("bash -en ./sign.sh", False, False),
    ("bash -s ./sign.sh </dev/null", False, False),
    ("bash -s ./sign.sh <<'EOF'\nEOF", False, False),
    ("bash -c ./sign.sh", True, False),
    ("bash -c 'echo hi' ./sign.sh >/dev/null", False, False),
    ("bash -i ./sign.sh 2>/dev/null", True, False),
    ("bash --rcfile ./sign.sh </dev/null", False, False),
    ("bash --rcfile ./sign.sh -i </dev/null 2>/dev/null", True, False),
    ("bash --rcfile /dev/null ./sign.sh", True, False),
    ("bash -o noexec ./sign.sh", False, False),
    ("bash -o errexit ./sign.sh", True, False),
    ("bash +o errexit ./sign.sh", True, False),
    ("bash -eo noexec ./sign.sh", False, False),
    ("bash -O extglob ./sign.sh", True, False),
    ("bash <<'EOF'\n./sign.sh\nEOF", True, False),
    ("echo ./sign.sh | bash", True, False),
    ("env ./sign.sh", True, True),
    ("env -i ./sign.sh", True, True),
    ("env -u HOME X=1 ./sign.sh", True, True),
    ("env -- ./sign.sh", True, True),
    ("env --chdir=/ ./sign.sh 2>/dev/null", False, False),
    ("env -C / ./sign.sh 2>/dev/null", False, False),
    ("env -S './sign.sh'", True, False),
    ("env bash -n ./sign.sh", False, False),
    ("nice ./sign.sh", True, True),
    ("nice -n 5 ./sign.sh", True, True),
    ("nice -5 ./sign.sh", True, True),
    ("nice -n 1 env ./sign.sh", True, True),
    ("nohup ./sign.sh >/dev/null 2>&1", True, True),
    ("nohup bash -n ./sign.sh >/dev/null 2>&1", False, False),
    ("timeout 10 ./sign.sh", True, False),
    ("timeout -s KILL -k 1 10 ./sign.sh", True, False),
    ("timeout 10 bash -n ./sign.sh", False, False),
    ("stdbuf -oL ./sign.sh", True, True),
    ("setsid -w ./sign.sh", True, False),
    ("command ./sign.sh", True, True),
    ("command -v ./sign.sh >/dev/null", False, False),
    ("command -V ./sign.sh >/dev/null", False, False),
    ("time ./sign.sh 2>/dev/null", True, True),
    ("time -p ./sign.sh 2>/dev/null", True, True),
    ("builtin ./sign.sh 2>/dev/null", False, False),
    ("a\nexec ./sign.sh", True, True),
    ("exec -a renamed ./sign.sh", True, True),
    ("exec -c ./sign.sh", True, True),
    ("FLAGS=-n\nbash $FLAGS ./sign.sh", False, False),
    ("FLAGS=-e\nbash $FLAGS ./sign.sh", True, False),
]


def run_with_marker(script: str) -> tuple[bool, set[str]]:
    """Whether bash ran ./sign.sh, and the PATH stubs it ran."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        log = root / "ran"
        log.touch()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, path in (("sign.sh", root / "sign.sh"), ("a", bin_dir / "a")):
            path.write_text(f"#!/bin/sh\necho {name} >> '{log}'\n")
            path.chmod(0o755)
        environment = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(root), "LC_ALL": "C"}
        subprocess.run(["bash", "--noprofile", "--norc", "-c", script], cwd=root, env=environment,
                       capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        ran = set(log.read_text().split())
        return "sign.sh" in ran, ran - {"sign.sh"}


class ShellModesAndWrappersAgainstBash(unittest.TestCase):
    def test_every_mode_is_certain_only_when_bash_runs_the_script(self) -> None:
        for script, runs, credited in SCRIPT_FIXTURES:
            with self.subTest(script):
                ran, _ = run_with_marker(script)
                self.assertEqual(ran, runs, f"the fixture is wrong about bash: {script!r}")
                must = any(words[:1] == ["sign.sh"] for words in must_run(script))
                if must:
                    self.assertTrue(ran, f"must_run() credits ./sign.sh, which bash did not run: {script!r}")
                if ran:
                    self.assertTrue(may_run_program(script, "sign.sh"),
                                    f"may_run() misses ./sign.sh, which bash ran: {script!r}")
                self.assertEqual(must, credited, f"must_run() {'credits' if must else 'misses'} {script!r}")

    def test_the_reviewer_cases(self) -> None:
        # #40846 F1: neither runs the signer, so a certificate job with either is no signer step.
        for script in ("bash -n scripts/ci/release-signer/sign-app.sh app",
                       "bash -s scripts/ci/release-signer/sign-app.sh app"):
            with self.subTest(script):
                self.assertEqual(must_run(script), [])
                self.assertTrue(may_run_program(script, "scripts/ci/release-signer/sign-app.sh"))

    def test_wrappers_without_a_real_bash_fixture_are_never_certain(self) -> None:
        # sudo may refuse or run as another user; ionice may be absent; neither is credited, but the program it
        # names may run.
        for script in ("sudo ./sign.sh", "sudo -n -u root -- ./sign.sh", "ionice -c 3 ./sign.sh"):
            with self.subTest(script):
                self.assertEqual(must_run(script), [])
                self.assertTrue(may_run_program(script, "sign.sh"))
        for script in ("sudo -s ./sign.sh", "sudo -i", "sudo --unknown ./sign.sh", "ionice -p 1 ./sign.sh"):
            with self.subTest(script):
                self.assertEqual(must_run(script), [])
                self.assertTrue(may_run_program(script, "anything"))


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
        self.assertEqual(must_run("env X=1 nice -n 5 bash -e ./sign.sh app"), [["sign.sh", "app"]])

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
