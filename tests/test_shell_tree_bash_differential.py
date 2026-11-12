#!/usr/bin/env python3
"""The commands bash runs in a line are the commands tests/shell_tree.py reads in it.

A lint or detector that reads shell through shell_tree (parse(), commands(), words_run()) sees only the commands the
tree holds. A command bash runs that the tree misses is one no such check can see: a write, a publish or a mktemp
there passes unread. This is the differential detector for that. corpus() generates shell lines: every
atom (a command shape: wrappers, reserved words, groups, functions, coprocesses, substitutions of each form, eval, a
trap's action, a shell's -c string) inside every context (plain, $( ), backticks, a double-quoted $( ), a subshell, an
if, a function, a case item, eval, bash -c, a here-document's body). Each line is run by a real bash with PATH a folder
of its own: the stub commands c0..c9 each log their name and exit 0, and the wrappers and shells the atoms name are
the real ones. The stub names bash logged must be the stub names shell_tree reports for the line, both ways: a command
bash runs that the tree misses fails, and so does one the tree reports but bash never runs, unless EXTRA lists the
line with what bash did there. A line bash -n refuses fails as a corpus bug; a line shell_tree raises Unparsed for
fails as a miss.

Not in the corpus: commands another program runs from its arguments (xargs, find -exec, sudo), a shell reading its
script from stdin (`bash <<EOF`, `echo c1 | sh`), source and aliases.

Run it by hand after changing shell_tree.py: python3 tests/test_shell_tree_bash_differential.py (a few seconds, bash
and coreutils only).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import shell_tree  # noqa: E402

STUBS = tuple(f"c{k}" for k in range(10))
# Real programs the atoms run, linked into the oracle's PATH folder (bash and sh run -c strings, cat reads a
# here-document, the rest are shell_tree.WRAPPERS).
REAL = ("bash", "sh", "cat", "env", "nice", "nohup", "timeout", "stdbuf", "setsid")
SECONDS = 10.0

# Command shapes, each running stubs bash reaches with every stub exiting 0. NESTABLE ones go inside every context;
# the rest (an exec ends the shell, a here-document needs its own lines) are run as they are.
NESTABLE = (
    "c1",
    "c1 a 'b c'",
    "c1 | c2",
    "c1 |& c2",
    "c1 && c2",
    "c1; c2",
    "c1 & c2; wait",
    "{ c1; c2; }",
    "(c1)",
    "! c1",
    "time c1",
    "time -p c1",
    "x=1 c1",
    "c1 > /dev/null 2>&1",
    "c1 2>/dev/null",
    'c1 "$(c2)"',
    "c1 $(c2) $(c3)",
    'c1 "${v:-$(c2)}"',
    "c1 <(c2)",
    'c1 <<< "$(c2)"',
    "x=$(c1)",
    "x=$(c1; c2)",
    "declare x=$(c1)",
    "a=(x $(c1) y)",
    "[[ -z $(c1) ]]",
    "(( $(c1) 1 ))",
    "case a in a) c1 ;; esac",
    "case a in (a|b) c1 ;; esac",
    "case $(c1) in *) c2 ;; esac",
    "if c1; then c2; fi",
    "if ! c1; then :; else c2; fi",
    "while c1; do c2; break; done",
    "until ! c1; do c2; break; done",
    "for x in a; do c1; done",
    "for x in $(c1); do :; done",
    "for ((i = 0; i < 1; i++)); do c1; done",
    "f() { c1; }; f",
    "f() (c1); f",
    "function f { c1; }; f",
    "function f() { c1; }; f",
    "function f { c1; c2; }; f",
    # A coprocess runs beside the shell; wait, so bash's run is the same every time (in a substitution, a shell that
    # exits at once may take its coprocess down before it starts).
    "coproc c1; wait",
    "coproc { c1; }; wait",
    "coproc N { c1; }; wait",
    "coproc N (c1); wait",
    "eval c1",
    "eval c1 a",
    "eval 'c1; c2'",
    'eval "c1 && c2"',
    "eval 'c1 \"$(c2)\"'",
    "eval 'eval c1'",
    "trap c1 EXIT",
    "trap 'c1; c2' EXIT",
    "trap -- 'c1' EXIT",
    "bash -c c1",
    "bash -c 'c1; c2'",
    "bash -ec 'c1'",
    "bash -e -c 'c1 | c2'",
    "sh -c 'c1 && c2'",
    "sh -c 'c1' name arg",
    "bash -c 'eval c1'",
    "eval 'bash -c c1'",
    "env c1",
    "env X=1 c1",
    "env bash -c c1",
    "nice -n 5 c1",
    "nohup c1",
    "timeout 5 c1",
    "stdbuf -oL c1",
    "command c1",
    "command -v c1 >/dev/null",
    "nice env sh -c 'c1'",
    # A follow-up review of cmux#41624: an assignment eval runs (F1, a TypeError before), a $'...' string decoded as
    # bash decodes it, and a shell's options read whole before its -c text: each o or O in a group takes the next
    # word, and so do --rcfile and --init-file (F2).
    "eval x=$'hello'",
    "eval x=$'a' c1",
    "eval $'c1; c2'",
    "eval $'c1\\x20a'",
    "bash -c $'c1\\nc2'",
    "bash -co errexit 'c1; c2'",
    "bash -oc errexit 'c1; c2'",
    "bash -c -o errexit 'c1'",
    "bash -cO extglob 'c1'",
    "bash --rcfile /dev/null -c 'c1; c2'",
    "bash --init-file /dev/null -c c1",
    "bash --norc -c c1",
    # A Codex review of cmux#41745 (F1): bash ends a $'...' string's value at its first NUL, however it is written
    # (\0, \x00, \u0000, \U00000000, \400, \c@, \c followed by a space), and keeps the word's text after the string;
    # a \U value past 0x7FFFFFFF adds nothing. An argument, a -c string, a trap's action and a command's name are each
    # cut there, so the tree reads what bash runs, not the bytes after the NUL.
    "eval $'\\0; c1'",
    "eval $'c1\\0c2'",
    "eval $'c1\\x00; c2'",
    "eval $'c1\\u0000; c2'",
    "eval $'c1\\U00000000; c2'",
    "eval $'c1\\400; c2'",
    "eval $'c1\\c@; c2'",
    "eval $'c1\\c ; c2'",
    "eval $'c\\UFFFFFFFF1'",
    "eval $'c\\U800000001'",
    "eval $'c1\\0;' c2",
    "eval $'\\0' c1",
    "eval $'c1\\0x'\";c2\"",
    "bash -c $'c1\\0; c2'",
    "trap $'c1\\0; c2' EXIT",
    "$'c1\\0x'",
    "$'c1'",
    "env $'c1\\0x' a",
    # No NUL: each decodes to a command name, which the tree read from the undecoded text before (a name in an eval
    # string came from parse()'s text, so $'\x63' there stayed x63); then rows that must keep parsing as they did.
    "eval $'\\x631'",
    "eval $'c\\061'",
    "eval $'c\\u0031'",
    "eval $'c\\U00000031'",
    "eval $'c1\\x200'",
    "eval $'c1\\cAx; c2'",
    "eval $'c\\U7FFFFFFF; c1'",
)
WHOLE = (
    "exec c1",
    "c0; exec c1",
    "setsid -w c1",
    "cat <<EOF\n$(c1)\nEOF",
    "cat <<EOF | c2\n$(c1)\nEOF",
    "c1 <<'EOF'\n$(c2)\nEOF",
    "c1 \\\n  a; c2",
    "c1\nc2",
    # \c takes both backslashes of a \\ after it, so the 0 that follows is text, never a \0 (cmux#41745 F1).
    "eval $'c1\\c\\\\0; c2'",
    "eval $'c1\\c'; c2",
)


def _single(inner: str) -> str:
    return "'" + inner.replace("'", "'\\''") + "'"


def _backtick(inner: str) -> str:
    return "`" + inner.replace("\\", "\\\\").replace("`", "\\`") + "`"


CONTEXTS = {
    "plain": lambda x: x,
    "$( )": lambda x: "y=$(" + x + ")",
    "backticks": lambda x: "y=" + _backtick(x),
    '"$( )"': lambda x: 'c9 "$(' + x + ')"',
    "subshell": lambda x: "( " + x + " )",
    "if": lambda x: "if :; then " + x + "; fi",
    "function": lambda x: "g() { " + x + "; }; g",
    "case item": lambda x: "case z in z) " + x + " ;; esac",
    "eval": lambda x: "eval " + _single(x),
    "bash -c": lambda x: "bash -c " + _single(x),
    "here-document": lambda x: "cat <<EOF\n$(" + x + ")\nEOF",
}


# Lines where shell_tree reports a command bash does not run. An extra command never hides one from a detector, so it
# is allowed here, each with what bash did; a listed line that stops being extra fails, so the list only shrinks.
EXTRA = {
    "y=$(coproc c1; wait)": "bash ran no c1 for a coproc inside $( ), in every run on the CI runner's bash "
                            "(in backticks and a subshell it does); shell_tree reads the coprocess as a command",
    'c9 "$(coproc c1; wait)"': "the same coproc inside a double-quoted $( )",
}


def corpus() -> list[str]:
    """Every NESTABLE atom in every context, and each WHOLE line as it is."""
    out = [context(atom) for atom in NESTABLE for context in CONTEXTS.values()]
    return list(dict.fromkeys(out + list(WHOLE)))


STUB = """#!/bin/sh
printf '%%s\\n' %s >> %s
"""


def bash_runs(text: str) -> list[str] | str:
    """The stub names bash runs for TEXT, sorted and unique; a string saying why when bash gave no answer."""
    bash = shutil.which("bash")
    if subprocess.run([bash, "-n"], input=text, text=True, capture_output=True).returncode:
        return "bash -n refuses it: a corpus bug"
    root = tempfile.mkdtemp(prefix="shell-tree-diff-")
    try:
        bindir, log = os.path.join(root, "bin"), os.path.join(root, "ran")
        os.mkdir(bindir)
        for stub in STUBS:
            path = os.path.join(bindir, stub)
            with open(path, "w") as f:
                f.write(STUB % (stub, log))
            os.chmod(path, 0o700)
        for tool in REAL:
            found = shutil.which(tool)
            if not found:
                return f"{tool} is not on this host; the oracle needs it"
            os.symlink(found, os.path.join(bindir, tool))
        script = os.path.join(root, "script")
        with open(script, "w") as f:
            f.write(text + "\n")
        env = {"PATH": bindir, "HOME": root, "LC_ALL": "C"}
        run = subprocess.Popen([bash, "--noprofile", "--norc", script], cwd=root, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            run.communicate(timeout=SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(run.pid, 9)
            try:  # a process that left the group may still hold the pipe; never wait on it unbounded
                run.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                run.stdout.close()
                run.wait()
            return f"bash ran past {SECONDS:g} s"
        if not os.path.exists(log):
            return []
        with open(log) as f:
            return sorted(set(f.read().split()))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def tree_runs(text: str) -> list[str] | str:
    """The stub names shell_tree reports TEXT runs: the name each of its commands runs (words_run), at any depth;
    a string saying why when it reads none."""
    try:
        tree = shell_tree.parse(text)
    except shell_tree.Unparsed:
        return "shell_tree raised Unparsed"
    except Exception as error:  # a crash on one line is that line's difference, never one that hides the others
        return f"shell_tree raised {type(error).__name__}: {error}"
    found = set()
    for cmd in shell_tree.commands(tree):
        words = shell_tree.words_run(text, cmd)
        if words:
            found.add(shell_tree.name(text, words[0]).rsplit("/", 1)[-1])
    return sorted(found & set(STUBS))


def differences(texts: list[str]) -> list[tuple[str, object, object]]:
    """(line, what bash ran, what shell_tree reports) for each line where they differ: a command bash runs that the
    tree misses, an Unparsed line, a line bash gave no answer for, or an extra command on a line not in EXTRA. A line
    in EXTRA whose tree matches bash, or misses a command, is a difference too."""
    with ThreadPoolExecutor(max_workers=min(8, (os.cpu_count() or 1) * 2)) as pool:
        ran = list(pool.map(bash_runs, texts))
    out = []
    for t, r in zip(texts, ran):
        tree = tree_runs(t)
        if isinstance(r, str) or isinstance(tree, str):
            out.append((t, r, tree))
        elif t in EXTRA:
            if set(r) - set(tree) or set(r) == set(tree):
                out.append((t, r, tree))
        elif r != tree:
            out.append((t, r, tree))
    return out


class BashRunsWhatTheTreeReads(unittest.TestCase):
    def test_every_corpus_line(self):
        bad = differences(corpus())
        report = "\n".join(f"{line!r}\n    bash ran: {ran}\n    shell_tree: {tree}" for line, ran, tree in bad)
        self.assertEqual(bad, [], f"{len(bad)} of {len(corpus())} lines differ:\n{report}")

    def test_every_extra_line_is_in_the_corpus_with_its_reason(self):
        lines = set(corpus())
        for line, why in EXTRA.items():
            self.assertIn(line, lines)
            self.assertGreater(len(why), 20, line)

    def test_the_corpus_is_large_and_reaches_every_context(self):
        lines = corpus()
        self.assertGreater(len(lines), 600)
        for name, context in CONTEXTS.items():
            self.assertIn(context("c1"), lines, name)

    def test_the_oracle_logs_what_bash_runs(self):
        """A stub bash runs is logged and one it skips is not, also when only bash knows the command (a variable's
        text run by eval)."""
        self.assertEqual(bash_runs("c1 && c2"), ["c1", "c2"])
        self.assertEqual(bash_runs("false && c1"), [])
        self.assertEqual(bash_runs("command -v c1 >/dev/null"), [])
        self.assertEqual(bash_runs("echo c1"), [])
        self.assertEqual(bash_runs("x='c1'; eval \"$x\""), ["c1"])
        self.assertEqual(bash_runs("("), "bash -n refuses it: a corpus bug")


if __name__ == "__main__":
    unittest.main(verbosity=2)
