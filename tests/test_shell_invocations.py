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
    # #41133 review F2: a substitution inside a parameter expansion runs.
    ("a substitution in a parameter default runs", 'echo "${x:-$(a)}" >/dev/null', {"a"}, set()),
    ("a backtick in a parameter alternative runs", "x=1\necho ${x:+`a`} >/dev/null", {"a"}, set()),
    ("a substitution in a nested parameter default runs", 'echo "${x:-${y:-$(a)}}" >/dev/null', {"a"}, set()),
    # #41398 review F1: a substitution inside an arithmetic expansion runs, wherever the arithmetic is: in a parameter
    # default, an array subscript, a substring offset, a heredoc body; backticks unescape \\$ before their text runs.
    ("a substitution in arithmetic in a parameter default runs", 'echo "${x:-$(( $(a) + 1 ))}" >/dev/null', {"a"},
     set()),
    ("a substitution in a bare arithmetic expansion runs", "echo $(( $(a) + 1 )) >/dev/null", {"a"}, set()),
    ("a substitution in a legacy $[ ] runs", "echo $[ $(a) + 1 ] >/dev/null", {"a"}, set()),
    ("a substitution in an array subscript runs", 'arr=(1 2)\necho "${arr[$(a)]}" >/dev/null', {"a"}, set()),
    ("a substitution in a substring offset runs", 'y=abc\necho "${y:$(a)0:1}" >/dev/null', {"a"}, set()),
    ("a substitution in an arithmetic command runs", "(( $(a) + 1 ))", {"a"}, set()),
    ("a substitution in arithmetic in a heredoc body runs", "cat <<EOF >/dev/null\n$(( $(a) + 1 ))\nEOF\nb",
     {"a", "b"}, {"b"}),
    ("a quoted single quote in a parameter default does not hide a substitution",
     "echo \"${x:-'$(a)'}\" >/dev/null", {"a"}, set()),
    ("an escaped dollar in backticks is a substitution there", "echo `echo \\$(a)` >/dev/null", {"a"}, set()),
    # Found by the grammar below: arithmetic reads its body as double-quoted text, so a ${ }'s single quote is literal.
    ("a backtick in a single-quoted default in an arithmetic command runs", "(( \"\"${x:-'`a`'}\"\"0 ))", {"a"}, set()),
    ("a backtick in a single-quoted default in $(( )) runs", "echo $(( ${x:-'`a`'}0 )) >/dev/null", {"a"}, set()),
    ("a single-quoted default in $(( )) in a heredoc body runs", "cat <<EOF >/dev/null\n$(( \"\"${x:-'$(a)'}\"\"0 ))\nEOF",
     {"a"}, set()),
    ("a single-quoted default in $(( )) in ${:?} runs", "echo ${y:-$(( ${x:-\"\"${z:-'$(a)'}\"\"}0 + 1 ))} >/dev/null",
     {"a"}, set()),
]


# Shell modes and wrappers (#40846 F1): bash runs each with `./sign.sh` an executable that logs `sign.sh` to a marker
# file when it runs (an absolute path, so `env -i` and `exec -c` keep it), and `a` an executable on PATH. Fixture:
# (script, whether bash runs sign.sh, whether must_run() may credit it). A mode that does not run the first operand
# as a script is never certain; a fixture bash runs but the model calls uncertain must still be allowed by may_run.
SCRIPT_FIXTURES = [
    ("bash ./sign.sh", True, True),
    # #41133 review F1: a shell or wrapper named by its absolute path is the same program.
    ("/bin/bash ./sign.sh", True, True),
    ("/bin/bash -n ./sign.sh", False, False),
    ("/usr/bin/env ./sign.sh", True, True),
    ("/usr/bin/env bash -e ./sign.sh", True, True),
    ("/bin/bash -c ./sign.sh", True, False),
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

    def test_gh_api_request_reads_the_method_the_way_gh_does(self) -> None:
        from shell_invocations import gh_api_request
        writes = {
            "-f": ["x", "-f", "a=1"], "-F": ["x", "-F", "a=1"], "--field": ["x", "--field", "a=1"],
            "--raw-field": ["x", "--raw-field", "a=1"], "--input": ["x", "--input", "f"], "-fa=1": ["x", "-fa=1"],
            "--field=": ["x", "--field=a=1"], "--input=": ["x", "--input=f"], "-XPOST": ["x", "-XPOST"],
            "-X POST": ["x", "-X", "POST"], "--method POST": ["x", "--method", "POST"],
            "--method=post": ["--method=post", "x"], "-iXPOST": ["-iXPOST", "x"], "-X PATCH": ["x", "-X", "PATCH"],
            "-X $M": ["x", "-X", "$M"], "an unknown flag": ["x", "--frobnicate"],
            # Writes first: a write method anywhere wins over a read one, and a request body makes a GET a write.
            "-X POST then -X GET": ["x", "-X", "POST", "-X", "GET"], "-XGET then --method=PUT": ["-XGET", "x", "--method=PUT"],
            "-X GET --input": ["x", "-X", "GET", "--input", "f"], "--method=HEAD --input=": ["x", "--method=HEAD", "--input=f"],
        }
        for label, args in writes.items():
            with self.subTest(write=label):
                self.assertTrue(gh_api_request(args).writes, args)
        reads = {"bare": ["x"], "-X GET -f": ["x", "-X", "GET", "-f", "a=1"], "--method=GET -F": ["x", "--method=GET", "-F", "a=1"],
                 "-XGET -f": ["-XGET", "x", "-f", "a=1"], "-H -q": ["x", "-H", "Accept: y", "-q", ".id"],
                 "--paginate -i": ["--paginate", "-i", "x"], "-X HEAD": ["x", "-X", "HEAD"]}
        for label, args in reads.items():
            with self.subTest(read=label):
                self.assertFalse(gh_api_request(args).writes, args)
        self.assertEqual(gh_api_request(["-H", "Accept: y", "repos/o/r/releases", "-f", "a=1"]).endpoint, "repos/o/r/releases")
        self.assertIsNone(gh_api_request(["-f", "a=1"]).endpoint)  # no endpoint: xargs feeds it
        self.assertIsNone(gh_api_request(["$URL", "-f", "a=1"]).endpoint)  # an endpoint it cannot read
        self.assertIsNone(gh_api_request(["user", "repos/o/r/releases", "-XPOST"]).endpoint)  # two endpoints: either

    def test_may_run_nested_reads_wrapped_commands_and_marks_what_it_cannot_read(self) -> None:
        from shell_invocations import may_run_nested
        inner = ["gh", "release", "create", "v1"]
        for script in ("bash -c 'gh release create v1'", "eval gh release create v1", "eval \"sh -c 'gh release create v1'\"",
                       "sudo -E bash -c 'gh release create v1'", "xargs gh release create v1 < f",
                       "env -S 'gh release create v1'", "su u -c 'gh release create v1'",
                       "find . -exec gh release create v1 \\;", "x=$(gh release create v1)"):
            with self.subTest(wrapped=script):
                # find -exec keeps its `;` terminator as a last word: the command is what the words start with.
                self.assertTrue(any(words[:len(inner)] == inner for words in may_run_nested(script)), script)
        for script in ("bash <<'EOF'\ngh release create v1\nEOF", "eval \"$cmd\"", "bash -c \"$cmd\"", "source ./gen.sh",
                       ". ./gen.sh", "sh -s < f", "bash -c 'unterminated", "eval \"$(cat gen.sh)\""):
            with self.subTest(unreadable=script):
                self.assertIn([], may_run_nested(script))
        for script in ("echo hi", "f() { echo hi; }\nf", "xargs rm -f \"$x\" < f", "sudo apt-get install -y gh",
                       "bash -c 'echo gh release create'", "cat <<'EOF'\ngh release create v1\nEOF",
                       "\"$python\" -m venv \"$dir\"", "python3 - <<'PY'\nprint(1)\nPY"):
            with self.subTest(readable=script):
                self.assertNotIn([], may_run_nested(script))
                self.assertFalse(any(words[:len(inner)] == inner for words in may_run_nested(script)), script)

    def test_absolute_paths_and_parameter_substitutions_are_read_like_the_plain_forms(self) -> None:
        from shell_invocations import may_run_nested
        inner = ["gh", "api", "repos/o/r/releases", "-f", "tag_name=v1"]
        for script in ("/bin/bash -c 'gh api repos/o/r/releases -f tag_name=v1'",
                       "/usr/bin/env bash -c 'gh api repos/o/r/releases -f tag_name=v1'",
                       "/usr/bin/sudo -E /bin/sh -c 'gh api repos/o/r/releases -f tag_name=v1'",
                       "/usr/bin/xargs gh api repos/o/r/releases -f tag_name=v1 < f",
                       'echo "${x:-$(gh api repos/o/r/releases -f tag_name=v1)}"',
                       "echo ${x:+`gh api repos/o/r/releases -f tag_name=v1`}",
                       'echo "${x:-${y:-$(gh api repos/o/r/releases -f tag_name=v1)}}"'):
            with self.subTest(script):
                self.assertTrue(any(words[:len(inner)] == inner for words in may_run_nested(script)), script)
        # An absolute program this does not know, given -c, may run anything.
        self.assertIn([], may_run_nested("/opt/tools/bin/fish -c 'gh api repos/o/r/releases -f tag_name=v1'"))
        self.assertNotIn([], may_run_nested("/usr/bin/python3 ./build.py"))

    def test_a_shell_option_value_after_c_is_not_the_script(self) -> None:
        # #41133 BLOCK at aa1c6f09, F2: `bash -co pipefail TEXT` took pipefail as the script, so the release went unseen.
        from shell_invocations import may_run_nested
        inner = ["gh", "release", "create", "v1"]
        for script in ("bash -co pipefail 'gh release create v1'", "bash -oc pipefail 'gh release create v1'",
                       "bash -c -o pipefail 'gh release create v1'", "bash -ceo pipefail 'gh release create v1'",
                       "bash -cO extglob 'gh release create v1'", "bash +O extglob -c 'gh release create v1'",
                       "bash -coo pipefail errexit 'gh release create v1'", "sh -c -- 'gh release create v1'",
                       "/bin/bash -euco pipefail 'gh release create v1'"):
            with self.subTest(script):
                self.assertTrue(any(words[:len(inner)] == inner for words in may_run_nested(script)), script)
        # -c with its text missing, or held in a variable: it may run anything.
        for script in ("bash -co pipefail", "bash -co pipefail \"$cmd\""):
            with self.subTest(unreadable=script):
                self.assertIn([], may_run_nested(script))

    def test_there_is_no_default_reading(self) -> None:
        import shell_invocations
        self.assertFalse(hasattr(shell_invocations, "invocations"))


# One seeded grammar, run in real bash, for every way a script hides or shows a command: nestings (#41398 review F1:
# parameter expansion > arithmetic > command substitution > a release), function bodies in every form, defined
# before or after the call and nested (#41133 BLOCK F1: `function publish { gh ..; }` hid the gh), case arms, also
# inside a substitution (#41768 F2: a pattern's `)` ended the scan), and control flow (#40784 F1: `false && sign`
# was credited). Each sample runs with a fake gh on PATH that logs its call and the exit status. Both directions:
# a sample whose gh bash ran must have gh in may_run_program() and `gh release create` (or [], content it cannot
# read) in may_run_nested(); a sample must_run() credits with the release must have run it whenever bash ran the
# script to a 0 exit. Deterministic: GRAMMAR_SEEDS samples, no time budget.
GRAMMAR_SEEDS = 20000
NEST_LEAF = "gh release create v1 dist/x"
NEST_PRELUDE = "unset x0 x1 x2 x3 x4 x5\ny=abc\narr=(0 1)\n"


def _escape_for_backticks(text: str, escape_dollars: bool) -> str:
    text = text.replace("\\", "\\\\").replace("`", "\\`")
    return text.replace("$", "\\$") if escape_dollars else text


def nest_word(rng, depth: int, level: int = 0) -> str:
    """A word whose expansion runs NEST_LEAF, wrapped in DEPTH random expansion forms."""
    if depth == 0:
        return rng.choice((f"$({NEST_LEAF})", f"`{NEST_LEAF}`", f"$(case x in x) {NEST_LEAF};; esac)",
                           f"$(case x in (y) :;; x|z) {NEST_LEAF};; esac)"))
    inner = nest_word(rng, depth - 1, level + 1)
    name = f"x{level}"
    forms = (
        f"${{{name}:-{inner}}}", f"${{{name}-{inner}}}", f"${{{name}:={inner}}}", f"${{{name}:?{inner}}}",
        f"${{y:+{inner}}}", f"${{y+{inner}}}", f"${{y#{inner}}}", f"${{y%{inner}}}", f"${{y/{inner}/r}}",
        f"${{y//b/{inner}}}", f"${{y:{inner}0:1}}", f"${{y:0:{inner}1}}", f"${{arr[{inner}0]}}",
        f"${{#arr[{inner}0]}}", f"$(( {inner}0 + 1 ))", f"$[ {inner}0 + 1 ]", f"$((arr[{inner}0]))",
        f"$(echo {inner})", f"`echo {_escape_for_backticks(inner, rng.random() < 0.5)}`", f'"{inner}"',
        f"${{{name}:-\"{inner}\"}}", f"\"${{{name}:-'{inner}'}}\"",  # in double quotes a ${ }'s ' is literal
        f"$(case x in x) echo {inner};; esac)",
    )
    return rng.choice(forms)


def nest_statement(rng) -> str:
    """A statement that runs NEST_LEAF, plainly or through a word's expansions."""
    if rng.random() < 0.3:
        return NEST_LEAF
    word = nest_word(rng, rng.randint(1, 4))
    return rng.choice((
        f"echo {word} >/dev/null", f": {word}", f"v={word}", f"(( {word}0 ))", f"arr[{word}0]=1",
        f"[[ -n {word} ]]", f"case {word} in *) ;; esac", f"cat <<EOF >/dev/null\n{word}\nEOF",
        f"local_v=({word})", f"for i in {word}; do :; done", f"export v={word}",
    ))


def _body(rng, statement: str) -> tuple[str, str]:
    """How a body opens and closes around STATEMENT: newlines, or `; ` where the statement is one line."""
    if "\n" in statement or rng.random() < 0.5:
        return "\n", "\n"
    return " ", "; "


def wrap_statement(rng, statement: str, level: int) -> str:
    """STATEMENT inside one construct that runs it (a function called, a case arm taken, a branch, a loop, a
    subshell or substitution), or one that may skip it."""
    a, z = _body(rng, statement)
    f = f"f{level}"
    forms = (
        # Function bodies, every form; the call before the definition runs through a caller defined first.
        f"{f}() {{{a}{statement}{z}}}\n{f}", f"{f}() ({a}{statement}{z})\n{f}", f"function {f} {{{a}{statement}{z}}}\n{f}",
        f"function {f}() {{{a}{statement}{z}}}\n{f}", f"function {f} ({a}{statement}{z})\n{f}",
        f"{f}() if true; then{a}{statement}{z}fi\n{f}", f"function {f} for i in 1; do{a}{statement}{z}done\n{f}",
        f"g{level}() {{ {f}; }}\n{f}() {{{a}{statement}{z}}}\ng{level}",
        f"{f}() {{ function h{level} {{{a}{statement}{z}}}; h{level}; }}; {f}",
        # Case arms.
        f"case x in x){a}{statement}{z};; esac", f"case x in (y) :;; x|z){a}{statement}{z};; esac",
        f"case x in x) :;&\ny){a}{statement}{z};; esac",
        # Control flow that runs it, and that may skip it.
        f"true && {{{a}{statement}{z}}}", f"false || {{{a}{statement}{z}}}", f"if true; then{a}{statement}{z}fi",
        f"if false; then :; else{a}{statement}{z}fi", f"if false; then :; elif true; then{a}{statement}{z}fi",
        f"while true; do{a}{statement}{z}break; done", f"for i in 1; do{a}{statement}{z}done",
        f"until false; do{a}{statement}{z}break; done", f"{{{a}{statement}{z}}}", f"({a}{statement}{z})",
        f"false && {{{a}{statement}{z}}}", f"if false; then{a}{statement}{z}fi", f"true || exit 0\n{statement}",
        f"if false; then exit 3; fi\n{statement}", f"exit 0\n{statement}",
        # Substitutions of a whole statement.
        f"v=$({a}{statement}{z})", f"echo \"${{x9:-$({a}{statement}{z})}}\" >/dev/null",
    )
    return rng.choice(forms)


def grammar_script(seed: int) -> str:
    import random
    rng = random.Random(seed)
    statement = nest_statement(rng)
    for level in range(rng.choice((0, 0, 1, 1, 2, 3))):
        statement = wrap_statement(rng, statement, level)
    return NEST_PRELUDE + statement + "\n"


def bash_runs_gh(scripts: list[str]) -> set[int]:
    """The indexes of SCRIPTS whose gh call bash ran, each script run once by its own bash with a fake gh."""
    return bash_runs(scripts)[0]


def bash_runs(scripts: list[str]) -> tuple[set[int], set[int]]:
    """The indexes of SCRIPTS whose gh call bash ran, and of those bash ran to a 0 exit."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        log = root / "ran"
        log.touch()
        passed = root / "passed"
        passed.touch()
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "gh").write_text(f"#!/bin/sh\necho \"$SAMPLE\" >> '{log}'\n")
        (bin_dir / "gh").chmod(0o755)
        samples = root / "s"
        samples.mkdir()
        for index, script in enumerate(scripts):
            (samples / f"{index}.sh").write_text(script)
        driver = (f"cd '{samples}'\nfor n in $(seq 0 {len(scripts) - 1}); do\n"
                  "  if SAMPLE=$n timeout 10 bash --noprofile --norc ./$n.sh </dev/null >/dev/null 2>&1; then\n"
                  f"    echo $n >> '{passed}'\n  fi\ndone\n")
        environment = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(root), "LC_ALL": "C"}
        subprocess.run(["bash", "--noprofile", "--norc", "-c", driver], env=environment, capture_output=True,
                       text=True, timeout=3600, stdin=subprocess.DEVNULL, check=True)
        return ({int(line) for line in log.read_text().split()}, {int(line) for line in passed.read_text().split()})


def _releases(words: list[str]) -> bool:
    return words[:3] == ["gh", "release", "create"]


class GrammarAgainstBash(unittest.TestCase):
    maxDiff = None

    def test_the_estimate_covers_every_release_bash_runs_and_credits_none_it_skips(self) -> None:
        from shell_invocations import may_run_nested
        scripts = [grammar_script(seed) for seed in range(GRAMMAR_SEEDS)]
        ran, passed = bash_runs(scripts)
        # The grammar is only a check if bash really runs most of it, and skips some.
        self.assertGreater(len(ran), GRAMMAR_SEEDS // 2, f"bash ran gh in only {len(ran)} of {GRAMMAR_SEEDS} samples")
        self.assertGreater(GRAMMAR_SEEDS - len(ran), GRAMMAR_SEEDS // 50, "the grammar skips too few releases")
        missed, credited = [], []
        for index, script in enumerate(scripts):
            if index in ran:
                nested = may_run_nested(script)
                if not may_run_program(script, "gh") or not any(words == [] or _releases(words) for words in nested):
                    missed.append(script)
            elif index in passed and any(_releases(words) for words in must_run(script)):
                credited.append(script)
        self.assertEqual(missed, [], f"{len(missed)} of {len(ran)} samples bash ran gh in were estimated not to")
        self.assertEqual(credited, [], f"{len(credited)} samples must_run() credits with a release bash skipped")

    def test_the_reviewer_rows(self) -> None:
        from shell_invocations import may_run_nested
        rows = (
            'echo "${x:-$(( $(gh release create v1 dist/x) + 1 ))}"',  # #41398 F1
            "unset x0 x1 x2 x3 x4 x5\ny=abc\narr=(0 1)\nf0() ( : ${y/$[ ${x2:-\"\"${x3:-'$(gh release create v1 dist/x)'}\"\"}0 + 1 ]/r}; )\nf0",  # legacy $[ ] inside a parameter pattern
            "eval -- gh release create v1 dist/x",  # #41133 BLOCK F3
            "function publish { gh release create v1 dist/x; }; publish",  # #41133 BLOCK F1
            'echo "${X:-$(case x in x) gh release create v1 dist/x;; esac)}"',  # #41768 F2
            "echo $(case x in x) gh release create v1 dist/x;; esac)",
        )
        self.assertEqual(bash_runs_gh(list(rows)), set(range(len(rows))))
        for script in rows:
            with self.subTest(script):
                self.assertTrue(may_run_program(script, "gh"))
                self.assertIn(["gh", "release", "create", "v1", "dist/x"], may_run_nested(script))

    def test_an_expansion_it_cannot_parse_may_run_anything(self) -> None:
        from shell_invocations import may_run_nested
        for script in ('echo "${x:-$(( 1 + }"', "echo ${x:-$(( $(a) + 1 )", "echo $(case x in x) a;;)"):
            with self.subTest(script):
                self.assertIn([], may_run_nested(script))
                self.assertTrue(may_run_program(script, "anything"))


if __name__ == "__main__":
    unittest.main()
