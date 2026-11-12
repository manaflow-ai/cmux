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

STUBS = ("a", "b", "c", "sign", "create", "gh")

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
    ("a command after the heredoc operator on its line", "cat <<EOF >/dev/null && a\nsign\nEOF\nb", {"a", "b"}, {"b"}),
    ("a here-string is no heredoc", "cat <<< x >/dev/null\nsign", {"sign"}, None),
    ("a comment names a command", "# sign\na # b\nb", {"a", "b"}, None),
    ("&&, || and ; separate commands", "a && b; c; false || sign", {"a", "b", "c", "sign"}, {"a", "c"}),
    ("a pipe runs both sides", "a | b", {"a", "b"}, None),
    ("a backgrounded command", "a & b; wait", {"a", "b"}, None),
    ("an if condition and its branch", "if a; then b; fi", {"a", "b"}, {"a"}),
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
    # Control flow (cmux#40784 F1, Codex BLOCK at 341c7c1b): a command bash may skip is never credited. The left side of
    # && and || and the first if condition run; the right side, an if's branches, loop and case bodies, a function
    # body and everything after exit or return may not.
    ("the right side of && is not credited (#40784 F1)", "false && sign", set(), None),
    ("an if branch is not credited (#40784 F1)", "if false; then sign; fi", set(), None),
    ("the left side of || is credited (#40784 F1)", "sign || true", {"sign"}, None),
    ("the left side of && is credited", "a && false", {"a"}, None),
    ("a later command after an && list is credited", "false && b\nsign", {"sign"}, None),
    ("&& continued on the next line", "false &&\n  sign\nb", {"b"}, None),
    ("an elif and an else branch", "if false; then a; elif false; then sign; else b; fi\nc", {"b", "c"}, {"c"}),
    ("an if condition list after its first command", "if true && a; then b; fi", {"a", "b"}, set()),
    ("a while body", "while false; do sign; done\nb", {"b"}, None),
    ("a for body", "for x in; do sign; done\nb", {"b"}, None),
    ("a case branch", "case x in y) sign;; esac\nb", {"b"}, None),
    ("a brace group behind &&", "false && { sign; }\nb", {"b"}, None),
    ("a subshell behind ||", "true || (sign)\nb", {"b"}, None),
    ("&& inside a brace group", "{ false && sign; b; }", {"b"}, None),
    ("after exit nothing runs", "exit 0\nsign", set(), None),
    ("exit in a branch makes the rest uncertain", "if false; then exit 0; fi\nsign", {"sign"}, set()),
    ("exec with a program ends the script", "exec true\nsign", set(), None),
    # A skipped `exit N` with a literal nonzero N ends only a failing run: the rest is still certain on success.
    ("a skipped failing exit leaves the rest certain", "true || exit 1\nsign", {"sign"}, None),
    ("a failing exit in a branch leaves the rest certain", "if false; then exit 3; fi\nsign", {"sign"}, None),
    ("a skipped exit 0 does not", "true || exit 0\nsign", {"sign"}, set()),
    ("a skipped exit 256 is exit 0", "true || exit 256\nsign", {"sign"}, set()),
    ("a skipped exit with a dynamic status does not", "rc=1\ntrue || exit $rc\nsign", {"sign"}, set()),
    ("a reached failing exit ends the script", "exit 1\nsign", set(), None),
    ("exec with only redirections does not", "exec 2>/dev/null\nsign", {"sign"}, None),

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
    # A parameter or arithmetic expansion runs the substitutions inside it (#40784 review F2): may_run() must allow
    # them. Nested commands are never certain.
    ("a substitution in a double-quoted default (#40784 F2)", 'echo "${X:-$(gh release create v1 dist/x)}" >/dev/null',
     {"gh"}, set()),
    ("a substitution in an assigned default", "echo ${X:=$(a)} >/dev/null", {"a"}, set()),
    ("backticks in an alternate value", "X=1\necho ${X:+`a`} >/dev/null", {"a"}, set()),
    ("a substitution in a replacement pattern", "X=p\necho ${X/$(a)/q} >/dev/null", {"a"}, set()),
    ("a substitution in a substring offset", "X=abc\necho ${X:$(a)0} >/dev/null", {"a"}, set()),
    ("a double-quoted substitution in a double-quoted default", 'echo "${X:-"$(a)"}" >/dev/null', {"a"}, set()),
    ("a single-quoted substitution in a double-quoted default", "echo \"${X:-'$(a)'}\" >/dev/null", {"a"}, set()),
    ("a substitution in a nested default", 'echo "${X:-${Y:-$(a)}}" >/dev/null', {"a"}, set()),
    ("a process substitution in a default", "cat ${X:-<(a)} >/dev/null 2>&1", {"a"}, set()),
    ("a substitution in an arithmetic expansion", "echo $(( $(a) + 1 )) >/dev/null", {"a"}, set()),
    ("a substitution in a heredoc body's arithmetic expansion", "cat <<EOF >/dev/null\n$(( $(a) + 1 ))\nEOF",
     {"a"}, set()),
    # The parser reads what bash reads (#41768 review: a `case` pattern credited as a command, `X+=x cmd` unseen). Each
    # row is a place the two disagreed: a word bash takes as an assignment, a pattern, an arithmetic or conditional
    # expression, or an expansion of the program word.
    ("an append assignment before a command (#41768 F2)", "X+=x gh release create v1", {"gh"}, None),
    ("a subscripted assignment before a command", "X[0]=v gh", {"gh"}, None),
    ("a subscripted append assignment before a command", "X[i]+=v gh", {"gh"}, None),
    ("a quoted subscript in an assignment before a command", 'X["k y"]=v gh', {"gh"}, None),
    ("a quoted equals in a subscripted assignment is not an assignment (dep-fleet-6 F1)", 'X[0]"=v" gh', set(), None),
    ("a quoted assignment is the program, not an assignment", '"X=1" gh', set(), None),
    ("an escaped = is the program, not an assignment", "X\\=1 gh", set(), None),
    ("a keyword after an assignment is the program", "X=1 if gh", set(), None),
    ("a ! after an assignment is the program", "X=1 ! gh", set(), None),
    ("a case pattern after ;& is no command (#41768 F1)", "case x in x) a ;& gh) b ;; esac", {"a", "b"}, None),
    ("a case pattern list is no command", "case x in x|gh) a ;; esac", {"a"}, None),
    ("a case pattern after a leading paren is no command", "case gh in (gh) a ;; esac", {"a"}, None),
    ("a case pattern after ;;& is no command", "case x in x) a ;;& x|gh) b ;; esac", {"a", "b"}, None),
    ("a later matching case clause is not reached (dep-fleet-6 F2)", "case x in x) a ;; x) b ;; esac", {"a"}, None),
    ("a case in a skipped branch does not clear control flow (dep-fleet-6 F3)",
     "if false; then case x in x) a ;; esac; fi", set(), set()),
    ("a conditional in a skipped branch does not clear control flow (dep-fleet-6 F3)",
     "if false; then [[ -n x ]]; a; fi", set(), set()),
    ("a case over lines", "case x\nin\n  x|gh)\n    a\n    ;;\nesac", {"a"}, None),
    ("a nested case", "case x in x) case y in y|gh) a ;; esac ;& c) b ;; esac", {"a", "b"}, None),
    ("a case pattern's paren does not close a substitution", "x=$(case x in y) echo ;; gh) a ;; esac)\nb",
     {"b"}, None),
    ("an arithmetic command names no command", "(( gh = 1 ))\na", {"a"}, None),
    ("a shift in an arithmetic command opens no heredoc", "(( 1 << 2 ))\na", {"a"}, None),
    ("an arithmetic for loop header names no command", "for (( gh=0; gh<1; gh++ )); do a; done", {"a"}, None),
    ("a conditional expression's operators split no command", "[[ -n x && ( gh || b ) ]]\na", {"a"}, None),
    ("a coprocess runs its command", "coproc a\nwait", {"a"}, set()),
    ("a coprocess after time runs its command (dep-fleet-6 F4)", "time coproc a; wait", {"a"}, set()),
    ("env treats coproc as a program name (dep-fleet-6 F1)", "env coproc a", set(), set()),
    ("time env treats coproc as a program name (dep-fleet-6 F1)", "time env coproc a", set(), set()),
    ("an assignment makes coproc a program name (dep-fleet-6 F1)", "X=1 coproc a", set(), set()),
    ("a brace expansion in the program word", "{a,b}", {"a"}, set()),
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
    # Assignments the way each reader takes them (#41768 F2): env takes any word with `=`, `time` takes bash's.
    ("env X+=1 ./sign.sh", True, True),
    ("env 'A B=1' ./sign.sh", True, True),
    ("env Y[0]=2 ./sign.sh", True, False),
    ("time X+=1 ./sign.sh 2>/dev/null", True, True),
    ("./sig*.sh", True, False),
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
    def test_coproc_program_position_is_not_any_program(self) -> None:
        for script in ("env coproc a", "time env coproc a", "X=1 coproc a"):
            with self.subTest(script=script):
                self.assertFalse(may_run_program(script, "a"))

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
