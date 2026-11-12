"""A small shell parser for lints: shell text becomes a tree of commands, so a lint asks what a word is, never what
text sits near it.

parse(text) returns a Script: its Commands, each with argv Words and Redirects (a here-document's body included).
A Word is a list of parts: Lit (literal text, quoted or not), Param ($x, ${x...}), Arith ($(( ))) and Sub (a
command substitution, $( ) or backticks, or a process substitution <( ) or >( )), whose script is parsed the same
way, to any depth, inside ${ } too. The literal text an eval, a trap's action or a shell's -c runs is parsed onto its
command's scripts (decoded as bash decodes it, a $'...' string included), and the compound command after `function
NAME` or `coproc NAME` is a command of its own. Every node keeps its start and end offset in the text parse() was
given, backticks inside backticks included. An array's words, a case subject and its patterns, [[ ]] and (( )) are
data, never argv, though each substitution in them is a script. Text this parser cannot read through (an unclosed quote
or substitution, an unbalanced parenthesis, nesting deeper than MAX_DEPTH) raises Unparsed. A mktemp counts only in
command position.

The noclobber lints use it through code(), which drops comments where the shell does, and scan_text(): the text
with only the literal part of each mktemp template word blanked out. A template word is an argument of a command
named mktemp whose own literal text has XXXXXX. Each command substitution inside that word stays in and is walked like
any other script, so a template there exempts only itself; a redirection's target is never a template, wherever it
is. scan_file() reads a shell file or a workflow's run block whole, so a here-document keeps its context. MISSES
holds every review fixture, corpus() the shapes they missed, FILES whole files, and bash_writes() the differential
check: what bash does with a fixture, beside what the tree reads in it.

Each copy of this file is vendored byte for byte from a pinned upstream blob: change it upstream, and only there.
Each copy's sweep pins its SHA-256, and the upstream's own test checks every copy against the blob it pins.

Run as a script it reads a JSON list of strings on stdin and prints the list of their scan_text(code(...))
(a TypeScript sweep runs it so); --corpus, --file-corpus, --files, --unparsed, --bash, --no-oracle
and --tree-only print corpus(), FILES, each file's scan_file(), each file's unparsed(), each text's oracle() (true,
false or {"no_oracle": reason}), no_oracle() of the texts and TREE_ONLY as JSON.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

REDIRECTS = ("&>>", "&>", "<<<", "<<-", "<<", "<>", "<&", ">&", ">>", ">|", "<", ">")
WORD_END = " \t\n;&|()<>"
SPECIAL = "\\'\"$`"
SPECIAL_PARAMS = "$?#@*!-0123456789"
# A ${ }'s name, after an optional # (length) or ! (indirection), with its subscript: the operator follows it. A ] in
# quotes or escaped is the subscript's own, never its end: in "${a["]#"]-'$(cmd)'}" the operator is -, so the single
# quotes are literal and cmd runs (upstream #4380 review, F1).
SUBSCRIPT = r"\[(?:[^\]'\"\\]|\\.|'[^']*'|\"(?:[^\"\\]|\\.)*\")*\]"
PARAM_HEAD = re.compile(r"[#!]?(?:[A-Za-z_]\w*|\d+|[@*#?$!-])(?:" + SUBSCRIPT + ")?", re.S)
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=")
MAX_DEPTH = 32  # substitutions and expansions inside one another; deeper text is Unparsed, never a RecursionError
# Reserved words after which a command starts again: a ( there is a subshell, a (( arithmetic, a case or [[ itself.
START_WORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "time", "coproc"}
# What may follow `function NAME` or `coproc NAME`: a compound command, which starts a command of its own.
COMPOUND_WORDS = ("{", "if", "while", "until", "for", "select", "case", "[[")
# Command wrappers: each runs the command after its options, so unwrap() reads through them. Per wrapper: its options
# that take no argument, those that take one (-n 5, -n5, --adjustment=5), its long options whose argument is optional
# (only as --opt=ARG), and how many operands come before the command (timeout's DURATION). A long option may be cut
# to any unique prefix, as getopt reads it. env's NAME=value words are skipped, and its -S string is split into words.
# An option that is in none of these makes unwrap() UNRESOLVED: what runs cannot be told.
WRAPPERS = {
    "time": ({"-p", "-a", "-v", "-q", "--portability", "--append", "--verbose", "--quiet"},
             {"-f", "-o", "--format", "--output"}, set(), 0),
    # GNU env's whole option table (upstream #4382 review at cc43afa6, F3).
    "env": ({"-i", "-0", "-v", "--ignore-environment", "--null", "--debug", "--list-signal-handling"},
            {"-u", "-C", "-a", "-S", "--unset", "--chdir", "--argv0", "--split-string"},
            {"--default-signal", "--ignore-signal", "--block-signal"}, 0),
    "nice": (set(), {"-n", "--adjustment"}, set(), 0),
    "nohup": (set(), set(), set(), 0),
    "command": ({"-p"}, set(), set(), 0),
    "exec": ({"-c", "-l"}, {"-a"}, set(), 0),
    "builtin": (set(), set(), set(), 0),
    "timeout": ({"-v", "--verbose", "--preserve-status", "--foreground"}, {"-s", "-k", "--signal", "--kill-after"},
                set(), 1),
    "stdbuf": (set(), {"-i", "-o", "-e", "--input", "--output", "--error"}, set(), 0),
    "setsid": ({"-c", "-f", "-w", "--ctty", "--fork", "--wait"}, set(), set(), 0),
}
KEYWORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "coproc"}  # time is in WRAPPERS
# Reserved words this reads no command through: where one reaches a command's first word, what runs is UNRESOLVED,
# never a command named for it and never nothing (a for or select's words, a done, fi or esac with words after it).
UNMODELED = {"for", "select", "in", "done", "fi", "esac", "function", "case", "[[", "]]"}
# The builtins that read NAME=value in their arguments after quote removal, as env does: export "X"=1 sets X.
DECLARES = {"export", "declare", "typeset", "local", "readonly"}


class Unparsed(Exception):
    """The text is not shell this parser can read through."""


@dataclass
class Lit:
    start: int
    end: int


@dataclass
class Param:
    start: int
    end: int
    parts: list = field(default_factory=list)


@dataclass
class Arith:
    start: int
    end: int
    parts: list = field(default_factory=list)


@dataclass
class Sub:
    start: int
    end: int
    form: str  # "$(", "`", "<(" or ">("
    script: "Script"


@dataclass
class Word:
    start: int
    end: int
    parts: list
    # The word's text as the parser that read it saw it: an eval's or -c string's word is read from the string's
    # decoded value, and a backtick body's with its \` \\ \$ unescaped, which parse()'s text at START:END need not
    # hold (a $'\x63' there is a c here).
    text: str | None = None


@dataclass
class Redirect:
    op: str
    target: Word
    body: Word | None = None  # a here-document's body


@dataclass
class Command:
    words: list = field(default_factory=list)  # argv, assignments first
    redirects: list = field(default_factory=list)
    # Words that are no argv: an array's elements, a case's subject and patterns, an arithmetic command (( )). Their
    # substitutions run, so they are walked; none is ever a command's name or argument.
    data: list = field(default_factory=list)
    # The text the command has bash run as shell, parsed: an eval's arguments, a trap's action, a shell's -c string
    # (after unwrap()), when that text is all literal. Its nodes keep the offsets of the text parse() was given.
    scripts: list = field(default_factory=list)


@dataclass
class Script:
    commands: list


class _Parser:
    def __init__(self, s: str, origin: list[int], comments: list, level: list[int], string: bool = False):
        self.s, self.n, self.o = s, len(s), origin  # o[i]: the offset in parse()'s text of s[i]; o[n] the end
        # Shared with the parsers of nested backticks: (start, end) of each comment; [how deep the parse is].
        self.comments, self.level = comments, level
        # S is text bash runs as a string of its own (an eval's, a -c string's or a trap's text, a backtick body): a
        # backslash that ends it has nothing to escape, and bash keeps it as a character (`eval 'c1\'` runs c1\).
        self.string = string

    def nested(self, read, *args):
        """READ(*ARGS) one substitution or expansion deeper; Unparsed past MAX_DEPTH."""
        self.level[0] += 1
        if self.level[0] > MAX_DEPTH:
            raise Unparsed(self.s)
        got = read(*args)
        self.level[0] -= 1
        return got

    def script(self, i: int, close: str | None) -> tuple[Script, int]:
        """Commands from i up to CLOSE (")"; "case": a case item's ;; ;& ;;&, consumed, or its esac, not; None: the
        end); the index after it."""
        s, n = self.s, self.n
        commands, cmd, depth, pending, texts, last_end, spans = [], Command(), 0, [], [], -1, []

        def end():
            nonlocal cmd
            if cmd.words:
                self.strings(cmd, spans)
            if cmd.words or cmd.redirects or cmd.data:
                commands.append(cmd)
            cmd = Command()
            texts.clear()
            spans.clear()

        while True:
            while i < n and (s[i] in " \t" or s.startswith("\\\n", i)):
                i += 2 if s[i] == "\\" else 1
            if i >= n:
                if close is not None or depth:
                    raise Unparsed(s)
                end()
                return Script(commands), i
            c = s[i]
            if c == "#":  # at a word's start, outside quotes: a comment to the line's end
                i = self.comment(i)
                continue
            if c == ")" and close == ")" and depth == 0:
                end()
                return Script(commands), i + 1
            start = not cmd.redirects and all(t in START_WORDS for t in texts)
            # `function NAME` and `coproc NAME` before a compound command (function f { ...; }, coproc N { ...; },
            # coproc N (...), function f if ...; fi), after any reserved words: NAME is a name, never a command, and
            # the compound command is a command of its own, read as any other (upstream #4382
            # review, F2). NAME's substitutions run, so it is data (coproc "$(X=0 cmd)" { ...; }; upstream #4441
            # review). The reserved words before it are a command of their own, which runs nothing.
            if not start and len(texts) >= 2 and texts[-2] in ("function", "coproc") and not cmd.redirects and all(
                    t in START_WORDS for t in texts[:-2]) and (
                    any(self.keyword(i, k) for k in COMPOUND_WORDS) or s.startswith("((", i)
                    or c == "(" and texts[-2] == "coproc"):
                named = cmd.words[-2:]
                del cmd.words[-2:], spans[-2:]
                end()
                cmd.data += named
                end()
                start = True
            if close == "case" and depth == 0:
                op = next((t for t in (";;&", ";;", ";&") if s.startswith(t, i)), None)
                if op or (start and self.keyword(i, "esac")):
                    end()
                    return Script(commands), i + len(op or "")
            if start and self.keyword(i, "case"):
                end()
                data, bodies, i = self.nested(self.case, i + 4)
                commands.append(Command(data=data))
                for body in bodies:
                    commands += body.commands
                continue
            if start and self.keyword(i, "[["):  # a test: its words, ( ) and regexes are data
                end()
                cmd.data, i = self.test(i + 2)
                end()
                continue
            if not s.startswith(("<(", ">("), i):
                op = next((r for r in REDIRECTS if s.startswith(r, i)), None)
                if op:
                    i += len(op)
                    while i < n and s[i] in " \t":
                        i += 1
                    if i >= n or (s[i] in WORD_END and not s.startswith(("<(", ">("), i)):
                        raise Unparsed(s)
                    a = i
                    target, i = self.word(i)
                    cmd.redirects.append(Redirect(op, target))
                    if op in ("<<", "<<-"):
                        pending.append((cmd.redirects[-1], s[a:i]))
                    continue
            if c == "\n":
                end()
                i = self.heredocs(i + 1, pending)
                pending = []
                continue
            if c in ";&|":
                end()
                i += 2 if s.startswith(("&&", "||", ";;", "|&", ";&"), i) else 1
                continue
            if c == ")":
                if depth == 0:
                    raise Unparsed(s)
                end()
                depth, i = depth - 1, i + 1
                continue
            if c == "(":
                if texts and last_end == i and texts[-1].endswith("="):
                    i = self.array(i + 1, cmd.data)  # NAME=( ... ): an array's elements, never a command
                    continue
                if texts and texts[-1] == "for" and all(t in START_WORDS for t in texts[:-1]) and s.startswith(
                        "((", i):  # for (( ; ; )): arithmetic, no argv, also after a reserved word
                    got, i = self.nested(self.arith, i, 2)
                    cmd.data.append(Word(got.start, got.end, [got]))
                    continue
                if start:
                    end()
                elif texts:  # after a word only a function's () may follow
                    j = i + 1
                    while j < n and s[j] in " \t":
                        j += 1
                    if j >= n or s[j] != ")":
                        raise Unparsed(s)
                    if len(texts) >= 2 and texts[-2] == "function" and all(t in START_WORDS for t in texts[:-2]):
                        named = cmd.words[-2:]  # function NAME (): NAME is a name, never a command
                        del cmd.words[-2:], spans[-2:]
                        end()
                        cmd.data += named
                    end()
                    i = j + 1
                    continue
                if s.startswith("((", i):  # an arithmetic command: its words are no argv
                    got, j = self.nested(self.arith, i, 2)
                    cmd.data.append(Word(got.start, got.end, [got]))
                    i = j
                    continue
                end()
                depth, i = depth + 1, i + 1
                continue
            w, j = self.word(i)
            if s[i:j].isdigit() and j < n and s[j] in "<>":
                i = j  # a file descriptor's number: its redirection follows
                continue
            texts.append(s[i:j])
            cmd.words.append(w)
            spans.append((i, j))
            i = last_end = j

    def strings(self, cmd: Command, spans: list) -> None:
        """Parse onto CMD.scripts the text CMD has bash run as shell (Command.scripts); SPANS: each word's (start,
        end) in this parser's text. Text that is not all literal, or that does not parse, adds nothing. The command
        is read through its wrappers as resolve() reads it: what runs is a suffix of its own words."""
        s, argv, values = self.s, [], []
        for w, (a, b) in zip(cmd.words, spans):
            got = _unquote(w.text) if all(isinstance(p, Lit) for p in w.parts) else None
            values.append(got)  # whether the word decodes, apart from the X= unwrap() reads an assignment as
            argv.append("X=" if ASSIGNMENT.match(s, a) else "\0" if got is None else got[0])
        names = frozenset(k for k, (a, _) in enumerate(spans) if not ASSIGNMENT.match(s, a))
        bare = frozenset(k for k, (a, b) in enumerate(spans) if s[a:b] == argv[k])
        where: list = []
        run = unwrap(argv, None, where, names, bare)
        if not run or len(where) != len(run):
            return
        prog = run[0].rsplit("/", 1)[-1]
        picks: list[int] = []  # indexes in RUN
        # eval and trap read their options as bash's builtins do: one -- ends them, and the word after it is an
        # operand whatever it starts with (trap -- '-x; c1' EXIT runs c1: upstream #4620 review, F1). Before any --,
        # a word that starts with - (other than - alone) is an option: eval takes none, so it refuses it and runs
        # nothing; trap's -l, -p and -P print, and any other it refuses. A lone - is trap's reset (trap - SIG,
        # trap -- - SIG), and eval's first word.
        j = 1
        if prog in ("eval", "trap") and j < len(run) and run[j] != "-" and run[j].startswith("-"):
            j = j + 1 if run[j] == "--" else len(run)
        if prog == "eval":
            picks = list(range(j, len(run)))
        elif prog == "trap":
            if j < len(run) and run[j] != "-":
                picks = [j]
        elif prog in SHELLS:
            j = _script_index(run)
            if isinstance(j, int):
                picks = [j]
        if not picks:
            return
        # Each picked word is one of the command's own words, or a word of an env -S string (where: per character
        # the range of that -S word's value it comes from). env -S 'bash' -c c1 runs c1, and so does
        # env -S 'bash -c c1': the script is read from wherever its word comes from (upstream #4620 review, F2).
        body, origin, prev = "", [], None
        for r in picks:
            index, chars = where[r]
            if values[index] is None or "\0" in run[r]:
                return  # only a run can tell what it holds
            a, b = spans[index]
            text, at = values[index]
            if chars is None:
                word, starts, end = text, [self.o[a + x] for x in at], self.o[b]
            else:
                word, starts = run[r], [self.o[a + at[lo]] for lo, _ in chars]
                end = self.o[a + at[chars[-1][1]]] if chars and chars[-1][1] < len(at) else self.o[b]
            if prev is not None:  # the space between two arguments: at the end of the one before it
                body += " "
                origin.append(prev)
            prev = end
            body += word
            origin += starts
        origin.append(prev)
        level = self.level[0]
        try:  # comments in the string are not the text's: code() must never cut them out of it
            script, _ = self.nested(_Parser(body, origin, [], self.level, True).script, 0, None)
        except Unparsed:
            self.level[0] = level
            return
        cmd.scripts.append(script)

    def comment(self, i: int) -> int:
        """Record the comment at s[i] (a #); the index of its line's end."""
        j = self.s.find("\n", i)
        j = self.n if j < 0 else j
        self.comments.append((self.o[i], self.o[j]))
        return j

    def keyword(self, i: int, word: str) -> bool:
        return self.s.startswith(word, i) and (i + len(word) >= self.n or self.s[i + len(word)] in WORD_END)

    def blanks(self, i: int, lines: bool) -> int:
        """The index after blanks (and, when LINES, newlines and comments) from i."""
        s, n = self.s, self.n
        while i < n:
            if s[i] in " \t" or (lines and s[i] == "\n"):
                i += 1
            elif s.startswith("\\\n", i):
                i += 2
            elif lines and s[i] == "#":
                i = self.comment(i)
            else:
                break
        return i

    def test(self, i: int) -> tuple[list, int]:
        """The words of a [[ test from just after its [[, as data, and the index after its ]]."""
        s, n, out = self.s, self.n, []
        while True:
            i = self.blanks(i, True)
            if i >= n:
                raise Unparsed(s)
            if self.keyword(i, "]]"):
                return out, i + 2
            if s[i] in "()|&<>!;":  # an operator, a group, or part of a regex
                i += 1
                continue
            w, i = self.word(i)
            out.append(w)

    def array(self, i: int, data: list) -> int:
        """An array's elements, from just after its (, onto DATA; the index after its )."""
        s, n = self.s, self.n
        while True:
            i = self.blanks(i, True)
            if i >= n:
                raise Unparsed(s)
            if s[i] == ")":
                return i + 1
            if s[i] in WORD_END and not s.startswith(("<(", ">("), i):
                raise Unparsed(s)
            w, i = self.word(i)
            data.append(w)

    def case(self, i: int) -> tuple[list, list, int]:
        """A case statement from just after its `case`: its subject and patterns (data, never argv), each item's
        script, and the index after its esac."""
        s, n = self.s, self.n
        i = self.blanks(i, False)
        if i >= n or s[i] in WORD_END:
            raise Unparsed(s)
        subject, i = self.word(i)
        data, bodies = [subject], []
        i = self.blanks(i, True)
        if not self.keyword(i, "in"):
            raise Unparsed(s)
        i = self.blanks(i + 2, True)
        while True:
            if i >= n:
                raise Unparsed(s)
            if self.keyword(i, "esac"):
                return data, bodies, i + 4
            if s[i] == "(":
                i = self.blanks(i + 1, False)
            while True:  # patterns: WORD | WORD ... )
                if i >= n or s[i] in WORD_END:
                    raise Unparsed(s)
                w, i = self.word(i)
                data.append(w)
                i = self.blanks(i, False)
                if i < n and s[i] == "|":
                    i = self.blanks(i + 1, False)
                    continue
                if i < n and s[i] == ")":
                    i += 1
                    break
                raise Unparsed(s)
            body, i = self.script(i, "case")
            bodies.append(body)
            i = self.blanks(i, True)

    def heredocs(self, i: int, pending: list) -> int:
        """Read the body of each here-document in PENDING ((redirect, its delimiter word's source)) from line start
        I; the index after the last delimiter."""
        s, n = self.s, self.n
        for r, raw in pending:
            delim = re.sub(r"[\"'\\]", "", raw)
            quoted = bool(re.search(r"[\"'\\]", raw))
            start = i
            while i < n:
                e = s.find("\n", i)
                e = n if e < 0 else e
                # Unquoted, a line ending in an odd run of backslashes goes on into the next before it is matched with
                # the delimiter, as bash reads it.
                while not quoted and e < n and (len(s[i:e]) - len(s[i:e].rstrip("\\"))) % 2:
                    e2 = s.find("\n", e + 1)
                    e = n if e2 < 0 else e2
                line = s[i:e] if quoted else re.sub(r"\\\n\t*" if r.op == "<<-" else r"\\\n", "", s[i:e])
                if (line.lstrip("\t") if r.op == "<<-" else line) == delim:
                    body_end, i = i, min(e + 1, n)
                    break
                i = min(e + 1, n)
            else:
                body_end = n  # unterminated: the text ends inside the body
            if quoted:
                parts = [Lit(self.o[start], self.o[body_end])]
            else:
                parts, _ = self.parts(start, body_end, "")
            r.body = Word(self.o[start], self.o[body_end], parts)
        return i

    def word(self, i: int) -> tuple[Word, int]:
        start = i
        parts = []
        while i < self.n and (self.s[i] not in WORD_END or self.s.startswith(("<(", ">("), i)):
            got, i = self.piece(i, WORD_END)
            parts += got
        text = self.s[start:i]
        if self.string and i == self.n and (len(text) - len(text.rstrip("\\"))) % 2:
            text += "\\"  # the string's last character, an unescaped backslash, is one: the word's text says \\
        return Word(self.o[start], self.o[i], parts, text), i

    def parts(self, i: int, stop: int, quotes: str) -> tuple[list, int]:
        """Parts of s[i:stop] read as double-quoted text (a here-document's body); the index after."""
        s, out = self.s, []
        while i < stop:
            c = s[i]
            if c == "\\":
                out.append(Lit(self.o[i], self.o[min(i + 2, stop)]))
                i += 2
            elif c in "$`":  # inside double quotes or a here-document: a ${ }'s single quotes are literal
                got, i = self.dollar(i, True) if c == "$" else self.backtick(i)
                out.append(got)
            else:
                j = i
                while j < stop and s[j] not in "\\$`" + quotes:
                    j += 1
                if j == i:
                    break
                out.append(Lit(self.o[i], self.o[j]))
                i = j
        return out, min(i, stop)

    def piece(self, i: int, stop: str) -> tuple[list, int]:
        """The parts of the quoted string, expansion, escape or literal run at s[i] in unquoted text, and the index
        after; a literal run ends at a character in STOP."""
        s, n = self.s, self.n
        c = s[i]
        if c == "\\":
            j = min(i + 2, n)
            return [Lit(self.o[i], self.o[j])], j
        if c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise Unparsed(s)
            return [Lit(self.o[i], self.o[j + 1])], j + 1
        if s.startswith("$'", i):
            j = i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            if j >= n:
                raise Unparsed(s)
            return [Lit(self.o[i], self.o[j + 1])], j + 1
        if c == '"':
            parts, j = self.parts(i + 1, n, '"')
            if j >= n or s[j] != '"':
                raise Unparsed(s)
            return [Lit(self.o[i], self.o[i + 1])] + parts + [Lit(self.o[j], self.o[j + 1])], j + 1
        if c == "$":
            got, j = self.dollar(i)
            return [got], j
        if c == "`":
            got, j = self.backtick(i)
            return [got], j
        if s.startswith(("<(", ">("), i):
            script, j = self.nested(self.script, i + 2, ")")
            return [Sub(self.o[i], self.o[j], s[i:i + 2], script)], j
        j = i + 1  # a literal run; a <( or >( in it (inside ${ }) is a process substitution
        while j < n and s[j] not in stop and s[j] not in SPECIAL and not s.startswith(("<(", ">("), j):
            j += 1
        return [Lit(self.o[i], self.o[j])], j

    def dollar(self, i: int, quoted: bool = False):
        """The expansion at s[i]; QUOTED when it is inside double quotes or a here-document's body."""
        if self.s.startswith(("$(", "${"), i):
            return self.nested(self.expansion, i, quoted)
        return self.expansion(i)

    def arith(self, i: int, skip: int) -> tuple[Arith, int]:
        """The arithmetic at s[i] ($(( or ((, SKIP long) up to its )); the index after."""
        s, n = self.s, self.n
        parts, depth, j = [], 0, i + skip
        while j < n:
            c = s[j]
            if c in "$`\"'\\":
                got, j = self.piece(j, "")
                parts += got
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    if s.startswith("))", j):
                        return Arith(self.o[i], self.o[j + 2], parts), j + 2
                    raise Unparsed(s)
                depth -= 1
            j += 1
        raise Unparsed(s)

    def expansion(self, i: int, quoted: bool = False):
        s, n = self.s, self.n
        if s.startswith("$((", i):
            return self.arith(i, 3)
        if s.startswith("$(", i):
            script, j = self.script(i + 2, ")")
            return Sub(self.o[i], self.o[j], "$(", script), j
        if s.startswith("${", i):
            parts, j = [], i + 2
            head = PARAM_HEAD.match(s, j)
            if quoted and head and s[head.end():head.end() + 1] in tuple("#%/^,"):
                quoted = False  # a pattern: in double quotes too, its single quotes quote, as bash reads it
            while j < n and s[j] != "}":
                if quoted and s[j] == "'":  # literal, as bash reads it: a $( ) after it runs
                    parts.append(Lit(self.o[j], self.o[j + 1]))
                    j += 1
                    continue
                if quoted and s[j] == "$":  # a ${ } inside keeps the quoting it is in
                    got, j = self.dollar(j, True)
                    parts.append(got)
                    continue
                got, j = self.piece(j, "}'" if quoted else "}")
                parts += got
            if j >= n:
                raise Unparsed(s)
            return Param(self.o[i], self.o[j + 1], parts), j + 1
        m = re.compile(r"[A-Za-z_]\w*").match(s, i + 1)
        if m:
            return Param(self.o[i], self.o[m.end()]), m.end()
        if i + 1 < n and s[i + 1] in SPECIAL_PARAMS:
            return Param(self.o[i], self.o[i + 2]), i + 2
        return Lit(self.o[i], self.o[i + 1]), i + 1

    def backtick(self, i: int):
        """A `...` substitution: its body, with \\`, \\\\ and \\$ unescaped, is parsed as a script of its own whose
        nodes keep this text's offsets."""
        s, n = self.s, self.n
        j, body, origin = i + 1, [], []
        while j < n and s[j] != "`":
            if s[j] == "\\" and j + 1 < n and s[j + 1] in "`\\$":
                j += 1
            body.append(s[j])
            origin.append(self.o[j])
            j += 1
        if j >= n:
            raise Unparsed(s)
        origin.append(self.o[j])
        inner = _Parser("".join(body), origin, self.comments, self.level, True)
        script, _ = self.nested(inner.script, 0, None)
        return Sub(self.o[i], self.o[j + 1], "`", script), j + 1


# $'...' escapes (bash's ANSI-C quoting) that stand for one fixed character.
ANSI_C = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v",
          "\\": "\\", "'": "'", '"': '"', "?": "?"}


def _ansi_c(raw: str, i: int, out: list, at: list) -> int:
    """Decode the $'...' string whose $ is at RAW[i] as bash does onto OUT, each character's (start, end) range in RAW
    (an escape's: the whole escape) onto AT; the index after its closing quote. The string ends at the first ' no
    backslash escapes, then its text is decoded: \\nnn, \\xHH, \\uHHHH, \\UHHHHHHHH and \\cX (X & 0x1F; a \\\\ after it
    is one backslash, a \\c at the end stays as it is) are read, and another backslash stays as it is. A \\U value
    past 0x7FFFFFFF adds nothing. Bash keeps a string in C strings, so its value ends at its first NUL (\\0, \\x00,
    \\u0000, \\400, \\c@, ...): nothing after it in the string is kept, while the word's text after the string is."""
    n, k = len(raw), i + 2
    end = k
    while end < n and raw[end] != "'":
        end += 2 if raw[end] == "\\" else 1
    end = min(end, n)
    while k < end:
        c, start = raw[k], k
        if c != "\\" or k + 1 >= end:
            out.append(c)
            at.append((k, k + 1))
            k += 1
            continue
        e = raw[k + 1]
        k += 2
        if e in ANSI_C:
            ch = ANSI_C[e]
        elif e in "01234567":
            j = k
            while j < end and j < k + 2 and raw[j] in "01234567":
                j += 1
            ch, k = chr(int(raw[k - 1:j], 8) & 0xFF), j
        elif e in "xuU" and k < end and raw[k] in "0123456789abcdefABCDEF":
            j = k
            while j < end and j < k + {"x": 2, "u": 4, "U": 8}[e] and raw[j] in "0123456789abcdefABCDEF":
                j += 1
            value, k = int(raw[k:j], 16), j
            ch = "" if value > 0x7FFFFFFF else chr(min(value, 0x10FFFF))
        elif e == "c" and k < end:
            if raw[k] == "\\" and k + 1 < end and raw[k + 1] == "\\":
                k += 1
            ch, k = "\x7f" if raw[k] == "?" else chr(ord(raw[k]) & 0x1F), k + 1
        else:
            out += "\\" + e
            at += [(start, start + 1), (start + 1, start + 2)]
            continue
        if ch == "\0":
            break
        if ch:
            out.append(ch)
            at.append((start, k))
    return end + 1


def _unquote(raw: str) -> tuple[str, list[int]]:
    """The value of RAW, an all-literal word as bash reads it (line continuations, quotes and escapes removed, a
    $'...' string decoded, a $"..." string read as "..." is in the C locale), with the offset in RAW of each of its
    characters."""
    out, at, i, n = [], [], 0, len(raw)
    while i < n:
        c = raw[i]
        if c == "$" and raw.startswith("$'", i):
            ranges: list = []
            i = _ansi_c(raw, i, out, ranges)
            at += [a for a, _ in ranges]
            continue
        if c == "$" and raw.startswith('$"', i):
            i += 1  # $"...": bash translates it by the locale's catalog; with none it is "..."
            continue
        if c == "'":
            j = raw.find("'", i + 1)
            j = n if j < 0 else j
            out += raw[i + 1:j]
            at += range(i + 1, j)
            i = j + 1
        elif c == '"':
            i += 1
            while i < n and raw[i] != '"':
                if raw[i] == "\\" and i + 1 < n and raw[i + 1] in '$`"\\\n':
                    if raw[i + 1] != "\n":
                        out.append(raw[i + 1])
                        at.append(i + 1)
                    i += 2
                    continue
                out.append(raw[i])
                at.append(i)
                i += 1
            i += 1
        elif c == "\\":
            if i + 1 < n and raw[i + 1] != "\n":
                out.append(raw[i + 1])
                at.append(i + 1)
            i += 2
        else:
            out.append(c)
            at.append(i)
            i += 1
    return "".join(out), at


def parse(text: str, comments: list | None = None) -> Script:
    """TEXT as a tree of commands; Unparsed when it is not shell this parser reads through. Each comment's (start,
    end) goes on COMMENTS."""
    found = [] if comments is None else comments
    script, _ = _Parser(text, list(range(len(text) + 1)), found, [0]).script(0, None)
    return script


def code(text: str) -> str:
    """TEXT without its comments: a # that starts a word outside quotes, to the line's end. A '#' in quotes or in a
    word stays (`printf '%s' 'a # b' > f` keeps its redirection), and text that does not parse keeps every #."""
    if "#" not in text:
        return text
    found: list = []
    try:
        parse(text, found)
    except Unparsed:
        return text
    for a, b in sorted(found, reverse=True):
        text = text[:a] + text[b:]
    return text


def subs(parts: list):
    """The command substitutions in PARTS, at the top of each (one inside another is in its script)."""
    for p in parts:
        if isinstance(p, Sub):
            yield p
        elif isinstance(p, (Param, Arith)):
            yield from subs(p.parts)


def commands(script: Script, strings: bool = True):
    """Every command in SCRIPT and in every substitution and here-document inside it, at any depth, and with STRINGS
    in every Command.scripts too (the text an eval, a trap or a shell's -c runs)."""
    for cmd in script.commands:
        yield cmd
        if strings:
            for nested in cmd.scripts:
                yield from commands(nested)
        words = cmd.words + cmd.data + [r.target for r in cmd.redirects] + [r.body for r in cmd.redirects if r.body]
        for w in words:
            for sub in subs(w.parts):
                yield from commands(sub.script, strings)


def literal(text: str, word: Word) -> str:
    """WORD's literal text: its Lit parts, quotes included, never what an expansion or substitution holds."""
    return "".join(text[p.start:p.end] for p in word.parts if isinstance(p, Lit))


def unfold(text: str) -> str:
    """TEXT without its line continuations: each backslash-newline outside single quotes, which bash removes before it
    reads a word (mk\\<newline>temp is mktemp)."""
    if "\\\n" not in text:
        return text
    out, k, quote = [], 0, ""
    while k < len(text):
        c = text[k]
        if c in "'\"" and quote in ("", c):
            quote = "" if quote else c
        elif c == "\\" and quote != "'":
            if text[k + 1:k + 2] == "\n":
                k += 2
                continue
            out.append(text[k:k + 2])
            k += 2
            continue
        out.append(c)
        k += 1
    return "".join(out)


def name(text: str, word: Word) -> str:
    """WORD's value when it is all literal (line continuations, quotes and escapes removed, a $'...' string decoded),
    else ""."""
    if any(not isinstance(p, Lit) for p in word.parts):
        return ""
    if word.text is None:
        return re.sub(r"[\"'\\]", "", unfold(literal(text, word)))
    return _unquote(word.text)[0]


def _raw(text: str, word: Word) -> str:
    """WORD's text as its parser read it (Word.text), else TEXT at its offsets."""
    return text[word.start:word.end] if word.text is None else word.text


# Blanks between words: spaces, tabs and line continuations (cmux#41482 review at 657379ab, security F1:
# `mktemp \<newline>() { ...; }` defines mktemp).
BLANKS = r"(?:[ \t]|\\\n)*"


ENV_ESCAPES = {"_": " ", "t": "\t", "n": "\n", "r": "\r", "f": "\f", "v": "\v", "\\": "\\", "'": "'", '"': '"',
               "#": "#", "$": "$"}
ENV_VAR = re.compile(r"\$\{[A-Za-z_]\w*\}")


def _split(value: str) -> list[tuple[str, list[tuple[int, int]]]] | None:
    """VALUE split into words as GNU env -S splits its string, each with, per character, the (start, end) range of
    VALUE it comes from: words at blanks or an unquoted \\_, '...' (only \\\\ and \\' escaped in it), "..." and \\
    escapes, \\c ending it and an unquoted # that starts a word starting a comment. Each ${NAME} env expands is "\0".
    None when env refuses VALUE (a $ without braces, an unknown escape, an open quote)."""
    words, word, spans, quote, inword, k, n = [], [], [], None, False, 0, len(value)

    def end():
        nonlocal word, spans, inword
        if inword:
            words.append(("".join(word), spans))
        word, spans, inword = [], [], False

    while k < n:
        c = value[k]
        if quote == "'":
            if c == "'":
                quote, k = None, k + 1
            elif c == "\\" and value[k + 1:k + 2] in ("\\", "'"):
                word.append(value[k + 1])
                spans.append((k, k + 2))
                k += 2
            else:
                word.append(c)
                spans.append((k, k + 1))
                k += 1
            continue
        if c == "\\":
            nxt = value[k + 1:k + 2]
            if nxt == "c" and quote is None:
                break
            if nxt == "_" and quote is None:
                end()
                k += 2
                continue
            if nxt not in ENV_ESCAPES:
                return None
            word.append(ENV_ESCAPES[nxt])
            spans.append((k, k + 2))
            inword, k = True, k + 2
            continue
        if c == "$":
            m = ENV_VAR.match(value, k)
            if not m:
                return None
            word.append("\0")
            spans.append((k, m.end()))
            inword, k = True, m.end()
            continue
        if quote == '"':
            if c == '"':
                quote = None
            else:
                word.append(c)
                spans.append((k, k + 1))
            k += 1
            continue
        if c in " \t\n\r\f\v":
            end()
        elif c == "#" and not inword:
            break
        elif c in "'\"":
            quote, inword = c, True
        else:
            word.append(c)
            spans.append((k, k + 1))
            inword = True
        k += 1
    if quote:
        return None
    end()
    return words


def split_string(value: str) -> list[str] | None:
    """VALUE split into words as env -S splits it (_split): "\0" for each ${NAME} env expands; None when env refuses
    it."""
    got = _split(value)
    return None if got is None else [w for w, _ in got]


class _Unresolved(list):
    def __repr__(self):
        return "UNRESOLVED"


# What unwrap() returns when a wrapper's option is one it does not know, or env's -S string does not split: a
# command runs, and which one cannot be told. It is an empty list, so `if not run` covers it with None.
UNRESOLVED: list = _Unresolved()


def unwrap(argv: list[str], assigned: list | None = None, where: list | None = None,
           names: frozenset = frozenset(), bare: frozenset | None = None,
           through: list | None = None) -> list[str] | None:
    """The command ARGV runs and its arguments, read through NAME=value words, reserved words (!, if, do, ...) and
    the command wrappers in WRAPPERS with their options: `time -p env -i X=1 nice -n 5 mktemp t` runs
    ["mktemp", "t"]. An env -S string is split into words (_split). None when ARGV runs nothing (command -v, --help,
    an env with no command); UNRESOLVED when a wrapper has an option this does not know or an -S string env would
    refuse, so a caller cannot tell what runs and fails closed.

    Each NAME=value word read through goes on ASSIGNED as (index, word, spans). Where a word is one depends on where
    it sits, as bash reads it (ASSIGNMENT_WORDS): before the command, and after the time keyword, bash takes NAME=value
    only with its name unquoted (NAMES holds the indexes of ARGV words that are not, as "X"=1 or X\\_Y=1), so a quoted
    one is the command's name. env reads its words after quote removal, so any word with a = in it is env's,
    whatever its quoting: env "X"=1 sets X. A word of env's whose value only a run can tell ("\0", as "$V") with no =
    may be either, so the command is UNRESOLVED. After exec, and any other wrapper, NAME=value is the command's name.
    WHERE gets (index, spans) for each word returned. INDEX is the ARGV word it comes from; SPANS is None for that
    whole word, or for a word of an env -S string, per character the (start, end) range of ARGV[INDEX] it comes
    from.

    A bare `time` that starts the command (after reserved words, before any NAME=value or wrapper) is bash's
    reserved word, which takes -p and nothing else: `time -f F cmd` runs the command -f. Any other time (`command
    time`, /usr/bin/time, `X=1 time`, a quoted "time") is GNU time, with its options (upstream #4380
    review at 27a11d16, F2). It takes one -p and one --, each unquoted: `time -p -p cmd` and `time "-p" cmd` run the
    command -p (upstream #4434 review, F1). BARE holds the indexes of ARGV words with no quoting (all of them when
    None). THROUGH gets the name of each wrapper read through, in order. A reserved word this reads nothing through
    (UNMODELED) where a command starts makes it UNRESOLVED."""
    argv, k, assigns = list(argv), 0, "shell"
    origin: list = [(i, None) for i in range(len(argv))]
    first = True  # no NAME=value and no wrapper yet: a bare time here is the reserved word

    def unquoted(j: int) -> bool:  # an ARGV word with no quoting, as it is (no word of an -S string)
        return origin[j][1] is None and (bare is None or origin[j][0] in bare)

    def named(j: int) -> bool:  # an ARGV word NAMES holds, as it is (no word of an -S string)
        return origin[j][1] is None and origin[j][0] in names

    def split_at(at: int, off: int) -> bool:
        """Put the words of argv[at][off:] (an -S string) in its place, after argv[at]; False when env refuses it. A
        part only a run can tell ("\0": a shell expansion, $prefix, or env's own ${NAME}) may add words or quotes to
        what env splits, so a word of the string holding one may be anything: where one is at or before the command's
        name (an option, its operand, the name itself), what runs only a run can tell, and the command is UNRESOLVED
        (a downstream review at 7948495f, F1; cmux#41371 review, F1: vars="X touch";
        env -S "env -u $vars mktemp ..." runs touch). After the name it changes only the command's arguments, as an
        expansion outside -S does (cmux#41336 review, F1: env -S "mktemp /tmp/$USER.XXXXXX" is mktemp's
        template)."""
        if through is not None:
            through.append("env -S")  # what the host's env must do: split a string (requires' env-split)
        got = _split(argv[at][off:])
        if got is None:
            return False
        index, outer = origin[at]
        mapped = []
        for _, spans in got:
            shifted = [(lo + off, hi + off) for lo, hi in spans]
            mapped.append((index, shifted if outer is None else [(outer[lo][0], outer[hi - 1][1]) for lo, hi in
                                                                 shifted]))
        argv[at + 1:at + 1] = [w for w, _ in got]
        origin[at + 1:at + 1] = mapped
        return True

    while k < len(argv):
        # A reserved word is one only unquoted, where a command starts: "coproc", or coproc after X=1, is a command
        # named coproc (upstream #4441 review).
        keyword = assigns == "shell" and first and argv[k] in KEYWORDS and unquoted(k)
        if keyword or assigns == "shell" and ASSIGNMENT.match(argv[k]) and not named(k) or \
                assigns == "env" and "=" in argv[k]:
            if keyword and argv[k] == "coproc" and through is not None:
                # bash's own coprocess, wherever a command starts: after !, {, do, ... and inside another coproc's
                # { ...; } (each a subshell of its own)
                through.append("coproc keyword")
            if not keyword:
                first = False
                if assigned is not None:
                    assigned.append((origin[k][0], argv[k], origin[k][1]))
            k += 1
            continue
        if first and argv[k] == "time" and unquoted(k):
            k += 1  # bash's reserved word: one -p, one --, and the next word is the command, whatever it is
            if k < len(argv) and argv[k] == "-p" and unquoted(k):
                k += 1
            if k < len(argv) and argv[k] == "--" and unquoted(k):
                k += 1
            continue
        if argv[k] in UNMODELED and unquoted(k):
            return UNRESOLVED
        first = False
        if assigns == "env" and "\0" in argv[k]:
            return UNRESOLVED  # "$V" may be NAME=value or the command
        base = argv[k].rsplit("/", 1)[-1]
        if base not in WRAPPERS:
            if any(origin[j][1] is not None and "\0" in argv[j] for j in range(k + 1)):
                return UNRESOLVED  # an -S string's expansion at or before the name: what runs only a run can tell
            if where is not None:
                where.extend(origin[k:])
            return argv[k:]
        if through is not None:
            through.append(base)
        flags, takes, optional, operands = WRAPPERS[base]
        longs = sorted(o for o in flags | takes | optional if o.startswith("--"))
        k += 1
        while k < len(argv):
            opt = argv[k]
            if base == "env" and (opt == "-" or "=" in opt and not opt.startswith("-")):
                if assigned is not None and opt != "-":
                    assigned.append((origin[k][0], opt, origin[k][1]))
                k += 1  # env's - (as -i) and its NAME=value words
                continue
            if "\0" in opt and not opt.startswith("-"):
                return UNRESOLVED  # "$V": an option, NAME=value or the command, only a run can tell
            if not opt.startswith("-") or opt == "-":
                break
            k += 1
            if opt == "--":
                break
            if opt.startswith("--"):
                key, eq, val = opt.partition("=")
                if key in ("--help", "--version"):
                    return None
                # Its own name: NAMES is the caller's (a downstream review at 52412c22, F2).
                matches = [o for o in longs if o == key] or [o for o in longs if o.startswith(key)]
                if len(matches) != 1:
                    return UNRESOLVED
                key = matches[0]
                if key == "--split-string":
                    if not eq:
                        if k >= len(argv):
                            return UNRESOLVED
                        k += 1
                    if not split_at(k - 1, len(opt) - len(val) if eq else 0):
                        return UNRESOLVED
                    del argv[k - 1], origin[k - 1]  # its words take its place
                    k -= 1
                elif key in takes:
                    k += 0 if eq else 1
                elif eq and key not in optional:
                    return UNRESOLVED  # a flag given an argument
                continue
            if base == "nice" and opt[1:].isdigit():
                continue  # nice -5
            for j in range(1, len(opt)):  # short options, grouped (-cl) or with an argument attached (-n5, -oL)
                c = "-" + opt[j]
                if base == "command" and c in ("-v", "-V"):
                    return None  # it looks the command up and runs nothing
                if base == "env" and c == "-S":
                    if j + 1 < len(opt):
                        ok = split_at(k - 1, j + 1)
                    elif k < len(argv):
                        k += 1
                        ok = split_at(k - 1, 0)
                    else:
                        return UNRESOLVED
                    if not ok:
                        return UNRESOLVED
                    del argv[k - 1], origin[k - 1]
                    k -= 1
                    break
                if c in takes:
                    k += 0 if j + 1 < len(opt) else 1
                    break
                if c not in flags:
                    return UNRESOLVED
        # env reads its own NAME=value after --, too. exec's NAME=value is the command's name
        # (a downstream review at 52412c22, F1).
        # GNU time (a path, after command, after NAME=value: any time this loop reads) is a program, so NAME=value
        # after it is the command's name; only bash's keyword, read above, takes NAME=value (upstream #4490 review, F3).
        assigns = "env" if base == "env" else None
        k += operands
    return None


@dataclass
class Resolved:
    """What a command runs, read through its wrappers (unwrap()): WORDS, the command's words with its name first (an
    env -S string's words each a Word over the characters of the -S argument it comes from), each one's VALUE (quotes
    removed, "\0" for each part only a run can tell), and the NAME=value words read through (ASSIGNED, each with its
    value). WORDS is None when it runs nothing, and UNRESOLVED when that cannot be told. A declaration builtin's
    (DECLARES) NAME=value arguments are in ASSIGNED too, as it reads them, after quote removal (export "X"=1 sets X);
    its arguments whose value only a run can tell with no = in it (export "$V") are in UNKNOWN: each may be one. A
    value whose name has "\0" in it is NAME=value with a name only a run can tell (env $'X'=1). THROUGH names each
    wrapper read through, in order ("env -S" after env for each -S string it splits)."""
    words: list | None
    values: list
    assigned: list
    unknown: list = field(default_factory=list)
    through: list = field(default_factory=list)


def _value(text: str, word: Word) -> tuple[str, list[tuple[int, int]]]:
    """WORD's value with its quotes removed and a $'...' string decoded as bash decodes it (_ansi_c), "\0" for each
    part only a run can tell (an expansion, a substitution), and per character the (start, end) range of TEXT it comes
    from. An all-literal word read from text TEXT does not hold at its offsets (an eval's or -c string's decoded
    value, Word.text) is decoded from that text, each character the whole word's range."""
    if word.text is not None and word.text != text[word.start:word.end] and all(
            isinstance(p, Lit) for p in word.parts):
        value = _unquote(word.text)[0]
        return value, [(word.start, word.end)] * len(value)
    out, spans, quote = [], [], None
    for p in sorted(word.parts, key=lambda p: p.start):
        if not isinstance(p, Lit):
            out.append("\0")
            spans.append((p.start, p.end))
            continue
        k = p.start
        while k < p.end:
            c = text[k]
            if quote == "'":
                if c == "'":
                    quote = None
                else:
                    out.append(c)
                    spans.append((k, k + 1))
                k += 1
            elif quote == '"':
                if c == '"':
                    quote = None
                    k += 1
                elif c == "\\" and k + 1 < p.end and text[k + 1] in '$`"\\\n':
                    if text[k + 1] != "\n":
                        out.append(text[k + 1])
                        spans.append((k, k + 2))
                    k += 2
                else:
                    out.append(c)
                    spans.append((k, k + 1))
                    k += 1
            elif c == "\\" and k + 1 < p.end:
                if text[k + 1] != "\n":
                    out.append(text[k + 1])
                    spans.append((k, k + 2))
                k += 2
            elif c == "$" and text[k + 1:k + 2] == "'":
                k = _ansi_c(text[:p.end], k, out, spans)
            elif c in "'\"":
                quote = c
                k += 1
            else:
                out.append(c)
                spans.append((k, k + 1))
                k += 1
    return "".join(out), spans


def _clip(word: Word, start: int, end: int) -> Word:
    """The part of WORD from START to END: its literal parts cut to it, and every other part that overlaps it."""
    parts = []
    for p in word.parts:
        if isinstance(p, Lit):
            if max(p.start, start) < min(p.end, end):
                parts.append(Lit(max(p.start, start), min(p.end, end)))
        elif p.start < end and start < p.end:
            parts.append(p)
    return Word(start, end, parts)


def resolve(text: str, cmd: Command) -> Resolved:
    """What CMD runs (unwrap()), with each word mapped back to TEXT: the command's words, an env -S string's words
    included, each a Word at the characters it sits on (upstream #4368 review at cfd7897e, F3)."""
    words, values = cmd.words, [_value(text, w) for w in cmd.words]
    argv = [value for value, _ in values]
    # A quoted "X"=1 is a command's name (or an -S string), never an assignment, whatever its value.
    names = frozenset(i for i, w in enumerate(words) if not ASSIGNMENT.match(_raw(text, w)))
    bare = frozenset(i for i, w in enumerate(words) if _raw(text, w) == argv[i])
    assigned, where, through = [], [], []
    run = unwrap(argv, assigned, where, names, bare, through)

    def at(index: int, spans) -> Word:
        word, (_, chars) = words[index], values[index]
        if spans is None:
            return word
        if not spans:
            return Word(word.start, word.start, [])
        return _clip(word, chars[spans[0][0]][0], chars[spans[-1][1] - 1][1])

    got = [(at(i, spans), raw) for i, raw, spans in assigned]
    if run is None or run is UNRESOLVED:
        return Resolved(run, [], got, through=through)
    found = [at(i, spans) for i, spans in where]
    unknown = []
    # A declaration builtin is bash's only in bash's own command position, or after command or builtin; after env,
    # nice or any other program it is a program named export (upstream #4419 review, F1).
    if run[0] in DECLARES and all(b in ("command", "builtin") for b in through):
        for word, value in zip(found[1:], run[1:]):
            if value.startswith(("-", "+")) and "=" not in value:
                continue  # an option: export -n, declare -x, declare +x
            if "=" in value:
                got.append((word, value))
            elif "\0" in value:
                unknown.append(word)
    return Resolved(found, run, got, unknown, through)


# The host capability (a sweep's requires()) each program or keyword programs() names needs: a test that runs one goes
# through requires() for it (upstream #4441 review, F1 and F2).
CAPABILITIES = {"setsid": "setsid", "timeout": "timeout", "stdbuf": "stdbuf", "time": "gnu-time",
                "env -S": "env-split", "coproc keyword": "coproc"}


def _coproc_named(text: str, cmd: Command) -> bool:
    """Whether CMD is coproc NAME, before its compound command: the parser keeps both words as data. Only an unquoted
    coproc is bash's own; a quoted "coproc" is a command named coproc."""
    return not cmd.words and bool(cmd.data) and text[cmd.data[0].start:cmd.data[0].end] == "coproc"


def programs(text: str) -> list[str]:
    """Each program TEXT's commands run, in order, at any depth: the wrappers each is read through (resolve()'s THROUGH:
    a time other than bash's keyword is "time", an env -S split "env -S"), then the command's own name ("?" when only
    a run can tell), and "coproc keyword" for each unquoted coproc bash reads as its keyword: where a command starts,
    after ! or { or another reserved word too (unwrap() reads it), and before a NAME (coproc NAME { ...; }, whose
    words the parser keeps as data). Raises Unparsed as parse() does."""
    out = []
    for cmd in commands(parse(text), strings=False):  # a shell's -c string is read below, expansions and all
        if _coproc_named(text, cmd):
            out.append("coproc keyword")
        run = resolve(text, cmd)
        out += run.through
        if run.words is UNRESOLVED:
            out.append("?")
        elif run.words:
            name = "?" if "\0" in run.values[0] else run.values[0].rsplit("/", 1)[-1]
            out.append(name)
            inner = shell_string(run.values) if name in SHELLS else None
            if inner == UNKNOWN_SCRIPT:
                out.append("?")
            elif inner is not None:  # a shell's -c string runs too: its programs, at any depth (cmux#41371 review, F2)
                try:
                    out += programs(inner)
                except Unparsed:
                    out.append("?")
    return out


def argv_needs(argv: list[str]) -> list[str]:
    """needs() of a program run by its ARGV, with no shell: its first word is a program, never bash's time or coproc
    keyword and never NAME=value, so ["time", "-f", F, cmd] is GNU time (upstream #4441 review, F4)."""
    return needs("command -- " + shlex.join(argv))


# A shell's options that take an operand, as bash's own option reader takes them: -o and +o (alone or last in a
# group, -eo pipefail), and the long ones that name a file.
SHELL_OPERAND_LONGS = ("--rcfile", "--init-file")
# What shell_string() answers for a -c script only a run can tell (all of it an expansion), or that does not parse:
# programs() names it, and bash_processes() counts it past MAX_BASH_PROCESSES, so bash never runs it and the tree's
# answer stands.
UNKNOWN_SCRIPT = "-c ?"


def _script_index(values: list[str]) -> int | str | None:
    """The index in VALUES (a shell's words, its name first, quotes removed) of the script it runs with -c, read as
    shell_string() says; UNKNOWN_SCRIPT when an option only a run can tell may hold c, None when no -c is given or
    the shell refuses its options. An option group is one argument: a character in it that is no option letter (a
    space, a digit, a -) makes bash and sh refuse the whole command line and run nothing, so `bash '-c c1' c2` and
    `env -S bash '-c c1' c2` run no c2 (upstream #4647 review, F1)."""
    c, i = False, 1
    while i < len(values):
        word = values[i]
        i += 1
        if word in ("--", "-"):
            break  # a lone - ends them as -- does: bash -c - '-x; c1' runs -x; c1 (upstream #4620 F1's sweep)
        if word.startswith("--"):
            i += word in SHELL_OPERAND_LONGS
            continue
        if word[:1] in "-+" and len(word) > 1 or word == "+":  # a lone + is an empty option group: bash -c + T runs T
            if "\0" in word:
                return UNKNOWN_SCRIPT if c or "c" in word else None
            if not all(ch.isascii() and ch.isalpha() for ch in word[1:]):
                return None  # "-c c1": an invalid option, so the shell exits with its usage and runs nothing
            c = c or (word[0] == "-" and "c" in word[1:])
            i += word[1:].count("o") + word[1:].count("O")  # each o or O takes the next word: -o N, +O N, -coo A B
            continue
        i -= 1
        break
    if not c or i >= len(values):
        return None  # no -c, or bash -c with no script, which bash refuses
    return i


def shell_string(values: list[str]) -> str | None:
    """The text a shell's words (VALUES, its name first, quotes removed) run with -c, read as bash reads its options:
    option groups (-e, +x, -ec), each o or O in a group taking the next word as its operand, in order (bash -o
    errexit -c T, -eo pipefail, -cO extglob T, -coo A B T: cmux#41745's F2),
    --rcfile and --init-file taking theirs, other long options none, a lone + an empty group, and -- or a lone -
    ending them, so the word after one is the script whatever it starts with (bash -c -- '-x; c1'); the first word
    that is no option is the script when a group held c, anywhere before it (bash -c -e T). An expansion in the
    script ("\0") is kept as a literal word, so its other programs still count (upstream #4490 review, F2); a script
    that is all expansion is UNKNOWN_SCRIPT. None when no -c is given (a script file, or stdin)."""
    i = _script_index(values)
    if not isinstance(i, int):
        return i
    script = values[i]
    if not script.replace("\0", "").strip():
        return UNKNOWN_SCRIPT
    return script.replace("\0", " _ ")


def needs(text: str) -> list[str]:
    """The host capabilities (CAPABILITIES) TEXT's programs need, each once, in order; [] when TEXT does not parse."""
    try:
        found = programs(text)
    except Unparsed:
        return []
    return list(dict.fromkeys(CAPABILITIES[p] for p in found if p in CAPABILITIES))


def runs(text: str) -> str | None:
    """The name of the command TEXT's first command runs (resolve()): None when it runs nothing, "?" when that
    cannot be told."""
    run = resolve(text, next(commands(parse(text))))
    if run.words is UNRESOLVED:
        return "?"
    # A name with an expansion in it ("\0", e.g. "$V") only a run can tell (upstream #4441 review).
    return ("?" if "\0" in run.values[0] else run.values[0]) if run.words else None


def assigned_names(text: str) -> list[str]:
    """The names TEXT's commands set with NAME=value words (resolve()), in order: "?" for one whose name only a run
    can tell, a declaration builtin's word that may be NAME=value (export "$V"), or a command that is UNRESOLVED."""
    out = []
    for cmd in commands(parse(text)):
        run = resolve(text, cmd)
        for _, raw in run.assigned:
            name = re.sub(r"\[.*$", "", raw.split("=", 1)[0].rstrip("+"))
            out.append("?" if "\0" in name else name)
        out += ["?"] * len(run.unknown)
        if run.words is UNRESOLVED:
            out.append("?")  # what it sets cannot be told
    return out


def words_run(text: str, cmd: Command) -> list[Word] | None:
    """CMD's words from the command it runs on (resolve()), its name first: None when that cannot be told."""
    return resolve(text, cmd).words or None


def template_words(text: str, cmd: Command, shadow: frozenset = frozenset()) -> list[Word]:
    """CMD's mktemp template words: an argument of a command named mktemp (after its wrappers, resolve()) whose own
    literal text has XXXXXX; inside an env -S string, the characters of the word env makes. None under -u
    (--dry-run): mktemp then only prints a name it never makes, and whatever writes it later writes a name another
    account may have made first (cmux#41336 review, F2, found by the oracle). Its options are read as GNU
    mktemp reads them, anywhere before --: an option or a word only a run can tell ("$opts", -"$x") may be -u, so it is
    never proven no dry run, and none is exempt (upstream #4441 review, F3). An expansion in a template word itself or
    in an option's argument (-p "$dir", --suffix="$s") is no option."""
    run = resolve(text, cmd)
    if not run.words or run.values[0].rsplit("/", 1)[-1] != "mktemp":
        return []
    if not trusted(run, shadow):
        return []  # a function, alias or code this cannot follow may be what runs (shadows())
    args, i = list(zip(run.words[1:], run.values[1:])), 0
    while i < len(args):
        word, value = args[i]
        i += 1
        if value == "--":
            break
        if value.startswith("--"):
            key, eq, _ = value.partition("=")
            if "\0" in key:
                return []
            got = [o for o in MKTEMP_LONG if o == key] or [o for o in MKTEMP_LONG if o.startswith(key)]
            if len(got) != 1 or got[0] == "--dry-run":
                return []  # a dry run, or an option mktemp refuses
            i += got[0] == "--suffix" and not eq  # --suffix SUFF
            continue
        if value.startswith("-") and value != "-":
            for j, c in enumerate(value[1:], 1):
                if c == "p":
                    i += j + 1 == len(value)  # -p DIR, or -pDIR
                    break
                if c not in "dqt":
                    return []  # -u, an option only a run can tell, or one mktemp refuses
            continue
        if "\0" in value and "XXXXXX" not in literal(text, word):
            return []  # "$opts": an option, or more than one, only a run can tell
    return [w for w in run.words[1:] if "XXXXXX" in literal(text, w)]


# GNU mktemp's long options (getopt takes any unique prefix).
MKTEMP_LONG = ("--directory", "--dry-run", "--quiet", "--suffix", "--tmpdir", "--help", "--version")


# Text that may name mktemp once quotes are removed ("mktemp", m"k"temp, \\mktemp): a quick filter before the parse,
# never the raw word (upstream #4346 review, F2).
MAY_MKTEMP = re.compile(r"m[\"'\\]*k[\"'\\]*t[\"'\\]*e[\"'\\]*m[\"'\\]*p")


def exempt(text: str) -> set[int]:
    """The offsets of TEXT a noclobber scan leaves out: each mktemp template word, less every substitution in it.
    None when TEXT does not parse."""
    if not MAY_MKTEMP.search(text):
        return set()
    try:
        tree = parse(text)
    except Unparsed:
        return set()
    return tree_exempt(text, tree)


# The wrappers that run their command by exec, from PATH: no shell function or alias of its name is ever it.
EXECS = {"env", "nice", "nohup", "timeout", "stdbuf", "setsid", "time", "exec"}
# The builtins that run code this does not read, or change what a name runs: what mktemp is after one only a run can
# tell.
DYNAMIC = {"source", ".", "eval", "enable"}


# A source this follows names its file by one variable, or by the source's own folder, then a literal rest: the
# variable's whole value is one of FOLDER_OF's forms, bound once (Sources).
_ARG0 = r'(?:"\$0"|\$0|"\$\{0\}"|"\$\{BASH_SOURCE\[0\]\}"|"\$\{BASH_SOURCE\}"|"\$BASH_SOURCE")'
_UP = r'(?:/\.\.)*/?'


def _is_arg0(arg: str) -> bool:
    """Whether ARG, one of _ARG0's forms, is $0 (the script a run starts, also inside a sourced file), not one of
    BASH_SOURCE's (the file being read). ${BASH_SOURCE[0]} holds a 0 too: a test for one read it as $0, so a source
    inside a sourced file resolved against the script's folder (cmux#41809 review, F1)."""
    return arg.replace('"', "") in ("$0", "${0}")
_DIRNAME = r'\$\(\s*dirname\s+(?P<arg>' + _ARG0 + r')\s*\)'
FOLDER_OF = (
    # "$(cd "$(dirname "$0")/.." && pwd)", with -P on either, the ../ inside the quotes or after them
    re.compile(r'(?P<q>"?)\$\(\s*cd\s+(?:-P\s+)?"' + _DIRNAME + r'(?P<up>' + _UP + r')"(?P<up2>' + _UP +
               r')\s*&&\s*pwd(?:\s+-[LP])?\s*\)(?P=q)'),
    re.compile(r'(?P<q>"?)' + _DIRNAME + r'(?P<up>' + _UP + r')(?P<up2>)(?P=q)'),
    re.compile(r'(?P<q>"?)\$\(\s*git\s+rev-parse\s+--show-toplevel\s*\)(?P=q)'),
)
_REST = r'(?P<rest>/[A-Za-z0-9._+/-]*)'
SOURCE_TARGET = (
    re.compile(r'"\$\{?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\}?' + _REST + r'"'),
    re.compile(r'"\$\{?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\}?"' + _REST),
    re.compile(r'"' + _DIRNAME + _REST + r'"'),
)
MAX_SOURCE_DEPTH = 16
MAX_SOURCED = 256


@dataclass
class Sources:
    """What shadows() needs to follow a source inside the repository ROOT: the script a run starts (SCRIPT, its $0),
    the file being read (FILE, its ${BASH_SOURCE[0]}), each file read (FILES: its text and comment spans), each
    variable bound to a folder so far (BOUND, in the order a run reads the files: each file where it is sourced) and
    each variable a source was resolved through (USED)."""
    root: str
    script: str
    file: str = ""
    files: dict = field(default_factory=dict)
    bound: dict = field(default_factory=dict)
    used: set = field(default_factory=set)
    depth: int = 0

    @classmethod
    def of(cls, root: str, path: str) -> "Sources":
        root = os.path.realpath(root)
        script = os.path.realpath(path if os.path.isabs(path) else os.path.join(root, path))
        return cls(root=root, script=script, file=script)


def _outer(text: str, tree: Script, comments: list) -> list[tuple[int, int]]:
    """The (start, depth) of each place in TEXT where a compound command opens or closes, so that the depth at an
    offset is the last depth before it: if/while/until/for/select and { (words the tree keeps) against fi, done and },
    and case and ( against esac and ) in what is left when every word, redirection target, here-document and comment
    is blanked. A ) that closes nothing outside a case closes what this cannot tell: from there on, nothing is at depth
    0."""
    marks = []
    for cmd in tree.commands:
        if not cmd.words:
            continue
        lead = [cmd.words[0]] + (cmd.words[2:3] if name(text, cmd.words[0]) == "function" else [])
        for w in lead:
            word = unfold(text[w.start:w.end])
            if word in ("if", "while", "until", "for", "select", "{"):
                marks.append((w.start, 1))
            elif word in ("fi", "done", "}"):
                marks.append((w.start, -1))
    skeleton = list(text)
    spans = list(comments)
    for cmd in commands(tree):
        for w in cmd.words + cmd.data + [r.target for r in cmd.redirects]:
            spans.append((w.start, w.end))
        for r in cmd.redirects:
            if r.body:
                spans.append((r.body.start, r.body.end))
    for a, b in spans:
        skeleton[a:b] = " " * (b - a)
    skeleton = "".join(skeleton)
    for m in re.finditer(r"\bcase\b|\besac\b|[()]", skeleton):
        marks.append((m.start(), {"case": 1, "esac": -1, "(": 1, ")": -1}[m.group()] * 1j))
    out, depth, stack = [], 0, []
    for at, step in sorted(marks, key=lambda m: m[0]):
        if isinstance(step, complex):
            what = {1j: "(", -1j: ")"}.get(step, "")
            word = skeleton[at:at + 4]
            if word == "case":
                stack.append("case")
            elif word == "esac":
                while stack and stack.pop() != "case":
                    pass
            elif what == "(":
                stack.append("(")
            elif stack and stack[-1] == "(":
                stack.pop()
            elif not stack or stack[-1] != "case":
                stack.append("?")  # a ) that closes nothing: never at depth 0 again
                stack.insert(0, "?")
        else:
            depth += step
        out.append((at, depth + len(stack)))
    return out


def _depth(marks: list[tuple[int, int]], at: int) -> int:
    depth = 0
    for start, d in marks:
        if start >= at:
            break
        depth = d
    return depth


def _folder(value: str, sources: Sources) -> str | None:
    """The folder VALUE, a variable's whole assigned text, names (FOLDER_OF), or None."""
    for form in FOLDER_OF:
        m = form.fullmatch(value)
        if not m:
            continue
        if "arg" not in form.groupindex:
            return sources.root  # the repository's top (a run inside it)
        base = sources.script if _is_arg0(m.group("arg")) else sources.file
        up = (m.group("up") + m.group("up2")).replace("/", " ").split()
        return os.path.normpath(os.path.join(os.path.dirname(base), *up))
    return None


def _binding(text: str, cmd: Command, marks: list) -> tuple[str, str] | None:
    """(NAME, value) when CMD is NAME=value alone on its line, at column 0 and depth 0 (_outer), with no line before it
    that carries on into it: a binding every run makes when it reaches it."""
    if len(cmd.words) != 1 or cmd.redirects or cmd.data:
        return None
    w = cmd.words[0]
    m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=", text[w.start:w.end])
    if not m or (w.start and text[w.start - 1] != "\n"):
        return None
    if not re.match(r"[ \t]*(?:\n|$)", text[w.end:]) or _depth(marks, w.start) != 0:
        return None
    before = code(text[:w.start]).rstrip()
    if before.endswith(("\\", "&&", "||", "|")):
        return None
    return m.group(1), text[w.start + m.end():w.end]


def _unconditional(text: str, cmd: Command, run: Resolved, marks: list) -> bool:
    """Whether CMD, a source (RUN, resolved), runs in the shell that reads TEXT each time a run reaches it: its name
    CMD's first word (no {, if, !, ... before it), at column 0 and depth 0 (_outer), no line before it that carries
    on into it (\\, &&, ||, |), and nothing after it on its line but ;, &&, || or a comment (never | or &: a subshell
    of its own). A source anywhere else (a function body, an if or case arm, a loop, a subshell, the right side of
    && or ||) binds only in a child scope (_shadow)."""
    if not cmd.words or not run.words or run.words[0].start != cmd.words[0].start:
        return False
    w = cmd.words[0]
    if (w.start and text[w.start - 1] != "\n") or _depth(marks, w.start) != 0:
        return False
    if code(text[:w.start]).rstrip().endswith(("\\", "&&", "||", "|")):
        return False
    end = max([x.end for x in cmd.words] + [r.target.end for r in cmd.redirects])
    return bool(re.match(r"[ \t]*(?:$|\n|#|;(?!;)|&&|\|\|)", text[end:]))


def _target(text: str, word: Word, sources: Sources) -> str | None:
    """The file in the repository a source's WORD names (SOURCE_TARGET), or None when this cannot tell which."""
    raw = text[word.start:word.end]
    for form in SOURCE_TARGET:
        m = form.fullmatch(raw)
        if not m:
            continue
        if "name" in form.groupindex:
            folder = sources.bound.get(m.group("name"))
            sources.used.add(m.group("name"))
        else:
            folder = os.path.dirname(sources.script if _is_arg0(m.group("arg")) else sources.file)
        if folder is None:
            return None
        path = os.path.realpath(os.path.join(folder, m.group("rest").lstrip("/")))
        if os.path.commonpath([path, sources.root]) != sources.root or not os.path.isfile(path):
            return None
        return path
    return None


def _sourced(path: str, sources: Sources) -> frozenset | None:
    """shadows() of the file at PATH, read as the script is, in SOURCES; None when it cannot be read or parsed."""
    if path in sources.files:
        return frozenset()  # read already: a cycle, or a second source of it
    if sources.depth >= MAX_SOURCE_DEPTH or len(sources.files) >= MAX_SOURCED:
        return None
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        found: list = []
        tree = parse(text, found)
    except (OSError, UnicodeDecodeError, Unparsed):
        return None
    outer = sources.file
    sources.files[path] = (text, found)
    sources.file, sources.depth = path, sources.depth + 1
    try:
        return _shadows(text, tree, sources, found)
    finally:
        sources.file, sources.depth = outer, sources.depth - 1


def _rebound(sources: Sources) -> bool:
    """Whether a variable a source was resolved through (USED) is, in any file read, named anywhere but in one
    binding and as $NAME or ${NAME...}: assigned again (NAME=, ${NAME=...}, ${NAME:=...}), read into (read, for,
    mapfile, printf -v, getopts), declared, unset or named in (( )). Any other mention, an echo of the word
    included, counts too: an over-match only keeps a template a hit."""
    for name in sources.used:
        named = 0
        for text, comments in sources.files.values():
            chars = list(text)
            for a, b in comments:
                chars[a:b] = " " * (b - a)
            text = unfold("".join(chars))  # he\<newline>re=x names here too
            for m in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])", text):
                if text[:m.start()].endswith("$") or re.search(r"\$\{[#!]?$", text[:m.start()]):
                    if re.match(r"(?::?[=?]|\[)", text[m.end():]):
                        return True  # ${NAME:=x}, ${NAME[...]}: assigns, or is an array
                    continue
                named += 1
        if named != 1:
            return True
    return False


def shadows(text: str, tree: Script, sources: Sources | None = None, comments: list | None = None) -> frozenset:
    """What in TREE, anywhere, may make the name mktemp run something other than mktemp: "function" (mktemp() { ...; },
    function mktemp), "alias" (alias mktemp=..., or an alias whose words only a run can tell), and "dynamic": an eval,
    an enable, a command whose name only a run can tell (it may be any of these), or a source or . this does not
    follow (a downstream review, security F1).

    With SOURCES (the repository and the script, Sources.of), a source is followed rather than taken for dynamic
    (cmux#41402 review): its file is read as TEXT is, recursively, each file once, and what it may do to
    mktemp is TREE's. It is followed when its target is a literal path under a variable bound to the script's
    folder, the sourced file's own folder ($(dirname "$0") or "${BASH_SOURCE[0]}", in a cd ... && pwd or not, with
    ../ after it) or the repository's top ($(git rev-parse --show-toplevel), the repository a run is in), or under
    "$(dirname "${BASH_SOURCE[0]}")" itself, and names a file inside the repository. The variable must be bound
    once, alone on a line at column 0 outside every compound command, before the source in the order a run reads
    the files, and named nowhere else in any file read but as $NAME or ${NAME} (_rebound). A binding in a sourced
    file counts only when every run makes it: the file sourced unconditionally (_unconditional) all the way up, and
    no return before it; any other binds in a child scope a later source never reads (upstream #4558 review,
    F1). Any other target, a file that does not parse, or one past MAX_SOURCE_DEPTH, is dynamic, as without
    SOURCES."""
    if sources is None:
        return _shadows(text, tree, None, comments)
    if sources.file not in sources.files:
        sources.files[sources.file] = (text, list(comments or []))
    out = set(_shadows(text, tree, sources, comments or []))
    if sources.depth == 0 and _rebound(sources):
        out.add("dynamic")
    return frozenset(out)


def _path_named(text: str, word: Word, value: str) -> bool:
    """Whether WORD, a command's name, names a file by a path whatever a run makes of its parts: all in one pair of
    double quotes with no "$@" or "${a[@]}" in them (so no split), with a / of its own. Bash runs such a name as a file,
    never a function, alias or builtin of that name."""
    return bool(re.fullmatch(r'"[^"`\\@*]*"', text[word.start:word.end])) and "/" in value.replace("\0", "")


def _shadows(text: str, tree: Script, sources: Sources | None, comments: list | None) -> frozenset:
    """shadows() of TREE's own commands: a substitution's ($( ), `, <( ), >( )) run in a subshell of their own, so
    what they define or eval is theirs (tree_exempt() reads each with its own)."""
    out: set = set()
    marks = _outer(text, tree, comments or []) if sources is not None else []
    scope = None  # the bindings this file returns to its caller with, once a return may have ended it early
    try:
        for cmd in tree.commands:
            scope = _shadow(text, cmd, sources, marks, scope, out)
    finally:
        if scope is not None:
            sources.bound = scope
    return frozenset(out)


def _shadow(text: str, cmd: Command, sources: Sources | None, marks: list, scope: dict | None, out: set):
    """_shadows() of one of a file's commands, into OUT. A variable is bound (Sources.bound) only by what every run
    that reaches the end of the file makes: a source that may not run (_unconditional), or any after a return in a
    sourced file, binds in a child scope its caller never sees (SCOPE, the caller's, once set). Returns SCOPE."""
    lead = cmd.words or cmd.data
    if len(lead) >= 2 and name(text, lead[0]) == "function" and name(text, lead[1]) == "mktemp":
        out.add("function")
    if len(cmd.words) == 1 and name(text, cmd.words[0]) == "mktemp" and \
            re.match(BLANKS + r"\(", text[cmd.words[0].end:]):
        out.add("function")  # mktemp () { ...; }: the parser keeps the name as a command of its own
    if sources is not None:
        bound = _binding(text, cmd, marks)
        folder = bound and _folder(bound[1], sources)
        if folder:
            sources.bound.setdefault(bound[0], folder)
    run = resolve(text, cmd)
    if run.words is UNRESOLVED:
        return scope  # a reserved word this reads nothing through, or a wrapper's unknown option: no builtin runs
    if run.words and "\0" in run.values[0]:
        if not _path_named(text, run.words[0], run.values[0]):
            out.add("dynamic")
    elif run.words:
        what = run.values[0]
        if what in ("source", ".") and sources is not None and len(run.words) >= 2 and not run.through:
            path = _target(text, run.words[1], sources)
            outer = sources.bound
            if path and not _unconditional(text, cmd, run, marks):
                sources.bound = dict(outer)
            try:
                got = _sourced(path, sources) if path else None
            finally:
                sources.bound = outer
            out |= {"dynamic"} if got is None else got
        elif what in DYNAMIC:
            out.add("dynamic")
        elif what == "return" and sources is not None and sources.depth and scope is None:
            scope = sources.bound
            sources.bound = dict(scope)
        elif what == "alias" and any(v.startswith("mktemp=") or "\0" in v for v in run.values[1:]):
            out.add("alias")
    return scope


def shadowed_anywhere(text: str, tree: Script) -> bool:
    """Whether anything in TREE, or in any substitution at any depth inside it, may shadow mktemp (shadows() of each
    scope): the bash oracle runs every bare mktemp as written then."""
    if shadows(text, tree):
        return True
    for cmd in commands(tree):
        words = cmd.words + cmd.data + [r.target for r in cmd.redirects] + [r.body for r in cmd.redirects if r.body]
        if any(shadows(text, sub.script) for w in words for sub in subs(w.parts)):
            return True
    return False


def trusted(run: Resolved, shadow: frozenset) -> bool:
    """Whether RUN, a command named mktemp, runs the real mktemp whatever SHADOW (shadows()) holds: by its path, or
    exec'd by a wrapper (EXECS); command skips a function and an alias, never what code this cannot read may do."""
    if not shadow or "/" in run.values[0]:
        return True
    if any(b in EXECS for b in run.through):
        return True
    return "command" in run.through and shadow <= {"function", "alias"}


def tree_exempt(text: str, tree: Script, sources: Sources | None = None, comments: list | None = None) -> set[int]:
    """exempt() of TEXT, already parsed into TREE. A mktemp whose name something in TREE may redefine exempts nothing
    (shadows(), which follows a source with SOURCES)."""
    out: set[int] = set()

    def walk(script: Script, shadow: frozenset):
        for cmd in script.commands:
            for w in template_words(text, cmd, shadow):
                span = set(range(w.start, w.end))
                for sub in subs(w.parts):
                    span -= set(range(sub.start, sub.end))
                out.update(span)
            words = cmd.words + cmd.data + [r.target for r in cmd.redirects] + [r.body for r in cmd.redirects if r.body]
            for w in words:
                for sub in subs(w.parts):  # a subshell: what its parent may do to mktemp, and what it may itself
                    walk(sub.script, shadow | shadows(text, sub.script))

    walk(tree, shadows(text, tree, sources, comments))
    return out


def scan_text(text: str) -> str:
    """TEXT with each exempt character (exempt()) a space, so a scan's match can neither start nor run through one;
    the offsets of the rest are unchanged."""
    skip = exempt(text)
    if not skip:
        return text
    return "".join(" " if k in skip and c != "\n" else c for k, c in enumerate(text))


SHELL_SUFFIXES = (".sh", ".bash", ".zsh", ".ksh")
SHELLS = {"sh", "bash", "zsh", "ksh", "dash", "mksh", "ash"}


def shebang(text: str) -> str | None:
    """What TEXT's #! line runs: "shell", "other", "unresolved" (unwrap() cannot tell what it runs, so a sweep reports
    it and reads the file whole, never line by line unnoticed), or None with no #! line. The line is read both ways a
    kernel reads it: Linux passes all after the interpreter as one argument, macOS splits it at blanks; env -S splits
    its string as env does (split_string). Shell in either reading is shell; "other" only when both resolve to a
    program that is no shell."""
    if not text.startswith("#!"):
        return None
    line = text.split("\n", 1)[0][2:].strip()
    head = line.split(None, 1)
    kinds = set()
    for argv in (head, line.split()):
        run = unwrap(argv) if argv else None
        if not run or "\0" in run[0]:
            kinds.add("unresolved")
        elif not any(c.isspace() for c in run[0]):  # a name with a blank in it runs nothing (env "bash -e" on Linux)
            kinds.add("shell" if run[0].rsplit("/", 1)[-1] in SHELLS else "other")
    return "shell" if "shell" in kinds else "unresolved" if "unresolved" in kinds or not kinds else "other"
RUN_BLOCK = re.compile(r"(\s*)(?:-\s+)?run:\s*\|[-+0-9]*\s*(?:#.*)?$")


def scan_file(path: str, text: str, root: str | None = None) -> list[str]:
    """Each line of TEXT (split at \\n) as a noclobber scan reads it: comments dropped and template words blanked.
    A shell file (by suffix or #!), and each `run: |` block of a YAML file, is parsed whole, so a here-document, a
    line continuation or a quote across lines is read in its context: a here-document's # is no comment, and its
    substitutions run. Any other text is read line by line. A shell block that does not parse whole keeps its raw
    text, every # and template included, never a line-by-line guess (a downstream review at
    cd22cde4, F2): unparsed() names it, and a sweep reports it as unresolved. A #! line that shebang() cannot
    resolve is read as shell, and a sweep reports it besides. With ROOT, the repository PATH is in (relative to it, or
    absolute), a shell file's source of a file in it is followed (shadows()); a YAML run: block's never is."""
    lines = text.split("\n")
    out: list = [None] * len(lines)
    for a, b in shell_blocks(path, text):
        whole = root is not None and (a, b) == (0, len(lines)) and not path.endswith((".yml", ".yaml"))
        got = scan_block(lines[a:b], Sources.of(root, path) if whole else None)
        out[a:b] = lines[a:b] if got is None else got
    return [scan_text(code(line)) if got is None else got for line, got in zip(lines, out)]


def shell_blocks(path: str, text: str) -> list[tuple[int, int]]:
    """The (first, end) line ranges of TEXT that are shell: the whole of a shell file (by suffix or #!), or each
    `run: |` block of a YAML file."""
    lines = text.split("\n")
    if path.endswith(SHELL_SUFFIXES) or shebang(text) in ("shell", "unresolved"):
        return [(0, len(lines))]
    if path.endswith((".yml", ".yaml")):
        return run_blocks(lines)
    return []


def unparsed(path: str, text: str) -> list[int]:
    """The first line (1-based) of each shell block of TEXT (shell_blocks) that this parser cannot read: a sweep
    reports each as unresolved, since what it runs is unknown, and scan_file() scans its raw text."""
    lines = text.split("\n")
    return [a + 1 + next((k for k, line in enumerate(lines[a:b]) if line.strip()), 0)
            for a, b in shell_blocks(path, text) if scan_block(lines[a:b]) is None]


# A step shell: whose run: text is no POSIX shell's. Any other (bash, sh, a path, `/usr/bin/env bash {0}`, an
# expression, an unknown) is read as shell: a wrong guess here could only let a write through (as polling_scan).
NOT_POSIX_SHELLS = {"python", "python3", "pwsh", "powershell", "cmd", "node", "ruby", "perl", "deno", "bun"}


def posix_shell(value: str) -> bool:
    """False only for a step `shell:` VALUE that is clearly no POSIX shell (pwsh, python, ...), with its path and
    options; env with options or assignments may run any word, so it stays shell."""
    words = value.split("#", 1)[0].strip().strip("'\"").split()
    if words and words[0].rsplit("/", 1)[-1] == "env":
        words = words[1:]
        if any(w.startswith("-") or "=" in w for w in words):
            return True
    words = [w for w in words if not w.startswith("-")]
    return not words or words[0].rsplit("/", 1)[-1] not in NOT_POSIX_SHELLS


def _step_keys(lines: list[str], k: int, col: int) -> list[str]:
    """The keys (each line from its key on) of the YAML mapping whose key at column COL is on line K: the lines at
    COL up to the list item (`- `) that starts it, and down to the next item or a line left of COL. A line further
    right is a value's (a block scalar's, a nested mapping's), never the mapping's own."""
    def at(j: int) -> tuple[int, bool]:
        line = lines[j]
        ind = len(line) - len(line.lstrip(" "))
        m = re.match(r"-\s+", line[ind:])
        return (ind + m.end(), True) if m else (ind, False)

    out = [lines[k][col:]]
    for step in ((1,) if at(k)[1] else (-1, 1)):  # a key on the item's own line starts the mapping
        j = k + step
        while 0 <= j < len(lines):
            if lines[j].strip() and not lines[j].lstrip().startswith("#"):
                ind, item = at(j)
                if ind < col or (item and ind == col and step > 0):
                    break
                if ind == col:
                    out.append(lines[j][col:])
                    if item:
                        break
            j += step
    return out


def run_blocks(lines: list[str]) -> list[tuple[int, int]]:
    """The (first, end) line ranges of each `run: |` block scalar in a YAML file's LINES that a POSIX shell runs: a
    step whose own `shell:` is clearly no POSIX shell (posix_shell()) is skipped (cmux#41809: six pwsh steps read as
    bash); `defaults:` never skips one, as polling_scan reads a workflow."""
    out, k = [], 0
    while k < len(lines):
        m = RUN_BLOCK.match(lines[k])
        k += 1
        if not m:
            continue
        # The block holds the lines right of its key, not of the `- ` before it: a key after it on the item's
        # column (`shell:`, `env:`) is the step's, never the script's.
        col, j = lines[k - 1].index("run:"), k
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip(" ")) > col):
            j += 1
        shells = [key.split(":", 1)[1] for key in _step_keys(lines, k - 1, col)
                  if re.match(r"""(?:shell|'shell'|"shell")\s*:""", key)]
        if not shells or posix_shell(shells[0]):
            out.append((k, j))
        k = j
    return out


def scan_block(lines: list[str], sources: Sources | None = None) -> list[str] | None:
    """LINES read as one script (their common indent removed): each line's scan text; None when it does not parse.
    SOURCES, when given, follows its sources (shadows())."""
    indent = min((len(line) - len(line.lstrip(" ")) for line in lines if line.strip()), default=0)
    text = "\n".join(line[indent:] for line in lines)
    found: list = []
    try:
        tree = parse(text, found)
    except Unparsed:
        return None
    skip = tree_exempt(text, tree, sources, found) if MAY_MKTEMP.search(text) else set()
    for a, b in found:
        skip.update(range(a, b))
    blanked = "".join(" " if k in skip and c != "\n" else c for k, c in enumerate(text))
    return [" " * indent + line if line else line for line in blanked.split("\n")]


# The review fixtures of the misses, each a line a lint must flag.
MISSES = (
    # 1. The whole line was exempt when it had XXXXXX (a downstream review, F2).
    'd=$(mktemp -d ".../safe.XXXXXX"); printf secret > /tmp/out.$$',
    # 2. A regex took a redirection's target for mktemp's argument (a downstream review, F1).
    "d=$(mktemp -d) > /tmp/out.$$.XXXXXX",
    # 3. Token masking. An inner template's span shifted the outer one's (cmux#41306 F1,
    #    upstream #4346 F1); a whole template word exempted a substitution inside it (cmux#41306 F2);
    #    XXXXXX only inside a substitution made the word a template, masked whole (a downstream review).
    'mktemp "$(mktemp /tmp/$USER.XXXXXX).XXXXXX"; echo > /tmp/out.$$',
    'mktemp "$(mktemp /tmp/a.XXXXXX).XXXXXX" > /tmp/out.$$',
    'mktemp "/tmp/$(printf secret > /tmp/out.$$)x.XXXXXX"',
    'mktemp "$(printf /tmp/a.XXXXXX)$(printf secret > /tmp/out.$$)"',
    # The outer word holds a template only inside its substitution, so it is no template; the write is on the outer
    # mktemp (cmux#41306, block at 1f84d085).
    'mktemp "$(mktemp /tmp/a.XXXXXX)" > /tmp/out.$$',
    # 4. A comment was cut at any whitespace-led #, quoted or not (upstream #4346, F2).
    "printf '%s' 'foo # bar' > /tmp/out.$$",
    # 5. The parse tree's own misses (cmux#41306 review at 7e60a832, F1: an array's words read as a
    #    command; a downstream review at 0ea8b97f, F1: a process substitution in ${ } read as text).
    #    F2 there, a here-document read line by line, is in FILES.
    "paths=(mktemp ';' /tmp/out.$$.XXXXXX); printf secret > \"${paths[2]}\"",
    "mktemp ${TMPDIR:-<(printf secret > /tmp/out.$$)}/x.XXXXXX",
    # 6. The parser kept quoting state bash does not (upstream #4368 review at 3aa1ae3e, F1): in a
    #    double-quoted ${ }, single quotes are literal, so the $( ) in them runs. F2 there, a here-document's
    #    continued line, is in FILES.
    "mktemp \"/tmp/${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX\"",
    # 7. A quoted ] in a subscript ended the ${ }'s name early, so # read as its operator and the single quotes as
    #    quoting: the $( ) bash runs was hidden in the template word (upstream #4380 review, F1;
    #    upstream #4441 review, F5).
    "declare -A a; mktemp \"${a[\"]#\"]-'$(printf secret > /tmp/out.$$)'}/x.XXXXXX\"",
    # 8. An expanded option was read as no option, so mktemp "$opts" was never a dry run: opts=-u is (upstream #4441
    #    review, F3). Only a run can tell what "$opts" is, so its template is not exempt.
    'opts=-u; f=$(mktemp "$opts" /tmp/$USER.XXXXXX); : > "$f"',
    "opts=--dry-run; f=$(mktemp $opts /tmp/$USER.XXXXXX); : > \"$f\"",
)


# A # that is a comment, and one that is not (in quotes, escaped, inside a word, ${#x}).
COMMENTS = (
    ('echo "a # b" > /tmp/out.$$', True),
    ("echo a\\ #b > /tmp/out.$$", True),
    ("echo a#b > /tmp/out.$$", True),
    ('n=${#x}; echo > /tmp/out.$$', True),
    ("d=$(mktemp -d /tmp/$USER.XXXXXX) # then: echo > /tmp/out.$$", False),
    ("echo ok # cp a /tmp/out.$$", False),
    ("# printf s > /tmp/out.$$", False),
)


# Words the tree does not model as argv (an array's elements, a case's subject and patterns, an arithmetic command,
# a here-document's body), and a mktemp out of command position: none exempts anything. A mktemp in command position
# inside a case item, a function or after (( )) still does.
NOT_COMMANDS = (
    ("paths+=(mktemp /tmp/out.$$.XXXXXX)", True),
    ("paths=( mktemp /tmp/out.$$.XXXXXX )", True),
    ("paths=(\n  mktemp\n  /tmp/out.$$.XXXXXX\n)", True),
    ("declare -a p=(mktemp /tmp/out.$$.XXXXXX)", True),
    ("local -a p=(mktemp /tmp/out.$$.XXXXXX)", True),
    ("readonly -a p=(mktemp /tmp/out.$$.XXXXXX)", True),
    ("declare -a p; p=(mktemp /tmp/out.$$.XXXXXX)", True),
    ("p=(a $(mktemp /tmp/$USER.XXXXXX) b)", False),
    ("typeset -A m; m[k]=$(mktemp /tmp/$USER.XXXXXX)", False),
    ("case $x in (mktemp) echo /tmp/out.$$.XXXXXX ;; esac", True),
    ("case mktemp in /tmp/out.$$.XXXXXX) : ;; esac", True),
    ("case $x in a|b) mktemp /tmp/$USER.XXXXXX ;; *) printf s > /tmp/out.$$ ;; esac", True),
    ("case $x in a) mktemp /tmp/out.$$.XXXXXX ;; esac", False),
    ("(( mktemp /tmp/out.$$.XXXXXX ))", True),
    ("(( n = 1 )) && mktemp /tmp/out.$$.XXXXXX", False),
    ("(( $(mktemp /tmp/$USER.XXXXXX) ))", False),
    ("x=$(( $(mktemp /tmp/$USER.XXXXXX) )); echo > /tmp/out.$$", True),
    ("x=mktemp /tmp/out.$$.XXXXXX", True),
    ("echo mktemp /tmp/out.$$.XXXXXX", True),
    ("for f in mktemp /tmp/out.$$.XXXXXX; do :; done", True),
    ("cat <<EOF\nmktemp /tmp/out.$$.XXXXXX\nEOF", True),
    ("f() (mktemp /tmp/$USER.XXXXXX)", False),
    ("f() { mktemp /tmp/$USER.XXXXXX; }", False),
    ("f() { (mktemp /tmp/$USER.XXXXXX); }", False),
    # After a reserved word a command starts again; a [[ test's words, groups and regexes are data.
    ('[[ "$a" =~ ^(x|y)$ ]] && mktemp /tmp/$USER.XXXXXX', False),
    ("[[ mktemp == /tmp/out.$$.XXXXXX ]]", True),
    ("[[ $(printf s > /tmp/out.$$) ]]", True),
    ("if (( n )); then mktemp /tmp/$USER.XXXXXX; fi", False),
    ('while (($#)); do case "$1" in -a) d=$(mktemp -d /tmp/$USER.XXXXXX);; esac; shift; done', False),
    ("for ((i = 0; i < 3; i++)); do printf s > /tmp/out.$$; done", True),
    ("if ! (mktemp /tmp/$USER.XXXXXX); then exit 1; fi", False),
)
# A substitution inside an expansion is a command too: $( ), backticks, <( ) and >( ) in ${ }.
EXPANSIONS = (
    ("mktemp ${TMPDIR:-a>(printf s > /tmp/out.$$)}/x.XXXXXX", True),
    ("mktemp ${TMPDIR:-${HOME:-$(printf s > /tmp/out.$$)}}/x.XXXXXX", True),
    ("mktemp ${TMPDIR:-`printf s > /tmp/out.$$`}/x.XXXXXX", True),
    ("x=${y:-<(printf s > /tmp/out.$$)}", True),
    ("mktemp ${TMPDIR:-/tmp/$USER}/x.XXXXXX", False),
    ("mktemp ${TMPDIR:-$(mktemp -d /tmp/$USER.XXXXXX)}/x.XXXXXX", False),
)
# Arrays, case, [[ ]] and (( )) are data, never argv, but every substitution inside them is a command: each form x
# each substitution that form reads x an unsafe write, a safe template, a template and then a write, and a template
# with an unsafe redirection.
DATA_SUBS = {
    "array": (("$(", '"$(', "`", "<(", ">("), ("a=({})", "a=(x {} y)", "a+=({})", "declare -a a=({})",
                                             "local -a a=({})", "a=(\n  {}\n)", "f() { local -a a=({}); }")),
    "case subject": (("$(", '"$(', "`"), ("case {} in x) : ;; esac",)),
    "case pattern": (("$(", '"$(', "`"), ("case $v in {}) : ;; esac", "case $v in (x|{}) : ;; esac")),
    "[[ ]]": (("$(", '"$(', "`"), ("[[ -n {} ]]", "[[ $v == {} ]]", "[[ $v =~ {} ]]", "[[ -n {} ]] && :",
                                   "if [[ -n {} ]]; then :; fi")),
    "(( ))": (("$(", "`"), ("(( {} ))", "(( n = {} + 1 ))", "x=$(( {} ))",
                            "for (( i = {}; i < 3; i++ )); do :; done", "while (( {} )); do :; done")),
}
DATA_INNERS = (("printf x > /tmp/o.$$", True), ("mktemp /tmp/$USER.XXXXXX", False),
               ("mktemp /tmp/$USER.XXXXXX; printf x > /tmp/o.$$", True), ("mktemp /tmp/$USER.XXXXXX > /tmp/o.$$", True))


def _data_subs() -> list[tuple[str, bool]]:
    out = []
    for forms, shapes in DATA_SUBS.values():
        for form in forms:
            for inner, unsafe in DATA_INNERS:
                sub = _wrap(inner, form) if form in ("`", '"$(') else form + inner + ")"
                out += [(shape.replace("{}", sub), unsafe) for shape in shapes]
    return out


# A case pattern's ) inside a substitution never closes it (a downstream security review at
# 731335fd): a pattern with and without its ( prefix, a nested case, and each substitution form, holding an unsafe
# write or only a safe name.
CASE_IN_SUBS = ('mktemp "$(case x in x) echo > /tmp/out.$$;; esac)x.XXXXXX"',)


def _case_in_subs() -> list[tuple[str, bool]]:
    out = [(line, True) for line in CASE_IN_SUBS]
    for form in ("$(", '"$(', "`", "<("):
        for pattern in ("x)", "(x)"):
            for nested in (False, True):
                for body, unsafe in (("echo > /tmp/out.$$", True), ("echo $USER", False)):
                    inner = "case x in " + pattern + " " + body + ";; esac"
                    if nested:
                        inner = "case y in " + pattern.replace("x", "y") + " " + inner + ";; esac"
                    if form == "<(":
                        line = "mktemp <(" + inner + ")/x.XXXXXX"
                    elif form == '"$(':
                        line = 'mktemp /tmp/"$(' + inner + ')"x.XXXXXX'
                    else:
                        line = 'mktemp "/tmp/' + _wrap(inner, form) + 'x.XXXXXX"'
                    out.append((line, unsafe))
    return out


# Quoting and line state as bash keeps it: single quotes in a ${ } are literal inside double quotes or a here-document,
# so a substitution in them runs, and quote outside them, where it is text (flagged as any name outside a template is).
QUOTE_STATE = (
    # upstream #4346 review: F1, a template's span also erased the command nested in it; F2, the raw
    # word was compared with "mktemp", so a quoted mktemp was no mktemp. Words are read after quote removal, and each
    # substitution is a command of its own.
    ('mktemp "/tmp/a.$(echo hi > /tmp/out.$$).XXXXXX"', True),
    ('"mktemp" /tmp/$USER.XXXXXX', False),
    ("'mktemp' -d /tmp/$USER.XXXXXX", False),
    ('m"k"temp /tmp/$USER.XXXXXX', False),
    ("\\mktemp /tmp/$USER.XXXXXX", False),
    ('d=$("mktemp" -d /tmp/$USER.XXXXXX)', False),
    ("mktemp \"/tmp/${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", True),
    ("mktemp \"/tmp/${a:-${b:-'$(printf secret > /tmp/out.$$)'}}.XXXXXX\"", True),
    ("x=\"${y:-'`printf secret > /tmp/out.$$`'}\"", True),
    ("x=\"${y:-'<(printf secret > /tmp/out.$$)'}\"", True),
    ("mktemp /tmp/${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX", False),
    ("x=${y:-'$(printf secret > /tmp/out.$$)'}", True),
    ("cat <<EOF\n${x:-'$(printf secret > /tmp/out.$$)'}\nEOF", True),
    ("cat <<'EOF'\n${x:-'$(printf secret > /tmp/out.$$)'}\nEOF", True),
    ("mktemp \"/tmp/${x:-'$USER'}.XXXXXX\"", False),
    # a downstream review at c6948ffc, F2: in double quotes, the single quotes of a pattern (#, ##, %,
    # %%, /, //, ^, ,) still quote it, so the $( ) in them never runs; those of -, =, ? and + are literal. Bash decides
    # each through bash_writes().
    ("mktemp \"/tmp/${x#'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x##'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x%'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x%%'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x/'$(printf secret > /tmp/out.$$)'/b}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x//a/'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x^'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x#${y:-'$(printf secret > /tmp/out.$$)'}}.XXXXXX\"", False),
    ("mktemp \"/tmp/${x#'a'$(printf secret > /tmp/out.$$)}.XXXXXX\"", True),
    ("mktemp \"/tmp/${x:='$(printf secret > /tmp/out.$$)'}.XXXXXX\"", True),
    ("mktemp \"/tmp/${x:+'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", True),
    ("x=1; mktemp \"/tmp/${x:+'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", True),
    ("mktemp \"/tmp/${#x}${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", True),
)


# A mktemp behind a command wrapper and its options is still mktemp (upstream #4368 review at
# 3aa1ae3e, wrapper F1): its template is safe, and a write beside it is not. Where a wrapper's option takes the word
# "mktemp" as its argument, the command is the next word, and an option the unwrapping does not know exempts nothing.
WRAPPERS_SAFE = ("time -p", "env", "env -i", "env -i PATH=/usr/bin:/bin", "env -u HOME", "env -uHOME",
                 "env --unset=HOME", "env -C /", "env --chdir=/", "env --", "env X=1 Y=2", "/usr/bin/env -i",
                 "nice", "nice -n 5", "nice -n5", "nice -5", "nice --adjustment=5", "nohup", "command", "command -p",
                 "exec", "exec -a name", "exec -c", "exec -cl", "timeout 5", "timeout -s KILL 5",
                 "timeout --kill-after=1 5", "timeout --preserve-status 5s", "stdbuf -oL", "stdbuf -o L",
                 "stdbuf --output=L -eL", "setsid", "setsid -f", "time -p env -i nice -n 1 timeout 5",
                 # upstream #4382 review at cc43afa6, F3: GNU env's whole option table.
                 "env --default-signal=PIPE", "env --default-signal", "env --ignore-signal=INT", "env --block-signal",
                 "env -a name", "env -aname", "env --argv0=name", "env --list-signal-handling", "env -v", "env -0i",
                 "timeout -v 5", "timeout --signal=KILL 5", "timeout --foreground -k 1 5",
                 # env reads its NAME=value words after quote removal (ASSIGNMENT_WORDS; upstream #4382
                 # review at 311cf8e9, F1).
                 'env -i "X"=1', 'env X_"Y"=1', "env X\\_Y=1", "env $'X'=1", 'env -- "X"=1', 'env "$V"=1')
WRAPPERS_UNSAFE = ("env -u mktemp", "env -C mktemp", "timeout mktemp", "nice -n mktemp", "exec -a mktemp",
                   "command -v mktemp", "env --bogus mktemp", "stdbuf -o mktemp", "timeout -s mktemp 5",
                   "env -a mktemp", "nice --bogus mktemp", "timeout --bogus 5 mktemp",
                   "setsid --bogus mktemp", "time --bogus mktemp", "exec -z mktemp",
                   # NAME=value where bash runs it as the command's name (ASSIGNMENT_WORDS): after exec
                   # (a downstream review at 52412c22, F1), after a long option (F2), and quoted before
                   # the command (upstream #4382 review at 311cf8e9, F1). And env "$V", which may be
                   # NAME=value or the command.
                   "exec X=1 mktemp", 'time --portability "X"=1 mktemp', '"X"=1 mktemp', 'X_"Y"=1 mktemp',
                   "X\\_Y=1 mktemp", "$'X'=1 mktemp", 'env "$V" mktemp')
# A command inside env's -S string (upstream #4368 review at cfd7897e, F3): env splits it into words
# as it splits any -S string, ${NAME} expanded; a $ without braces, or a $( ), makes env refuse it. The template words
# inside it are exempt where they sit in the -S argument, and nothing else is.
ENV_SPLIT = (
    # a downstream review at 7948495f, F1, and cmux#41371 review, F1: a shell expansion
    # inside the -S string ($prefix, $vars, $N) may add words and quotes to what env splits; at or before the
    # command's name, what runs only a run can tell, so the command is unresolved and no template is exempt (True).
    # After the name (mktemp /tmp/$USER.XXXXXX) it changes only mktemp's arguments, as outside -S, and the template
    # is exempt (cmux#41336 review, F1). env's own ${NAME} is one word.
    ("prefix='/bin/sh -c \"'; suffix='\"'; env -S \"${prefix}/mktemp > /tmp/out.$$.XXXXXX${suffix}\"", True),
    ('env -S "mktemp /tmp/$USER.XXXXXX"', False),
    ("env -S 'mktemp /tmp/${USER}.XXXXXX'", False),
    ("env -S'mktemp /tmp/${USER}.XXXXXX'", False),
    ('env -iS"mktemp -d /tmp/$USER.XXXXXX"', False),
    ('env --split-string="mktemp /tmp/$USER.XXXXXX"', False),
    ('d=$(env -S "mktemp -d /tmp/$USER.XXXXXX")', False),
    ('env -S "nice -n 5 mktemp /tmp/$USER.XXXXXX"', False),
    ('env -S "nice -n $N mktemp /tmp/a.$$.XXXXXX"', True),
    ('env -S "$CMD /tmp/a.$$.XXXXXX"', True),
    ("env -S 'env -S \"mktemp /tmp/${USER}.XXXXXX\"'", False),
    ('env -S "mktemp /tmp/$USER.XXXXXX" > /tmp/out.$$', True),
    ('env -S "mktemp /tmp/$USER.XXXXXX /tmp/out.$$"', True),
    ("env -S 'mktemp /tmp/$USER.XXXXXX'", True),
    # cmux#41371 review, F1: an expansion inside -S can move word boundaries, so what runs (here touch, as
    # env -u's operand takes X alone) only a run can tell; the template is never exempt.
    ('vars="X touch"; env -S "env -u $vars mktemp /tmp/a.$$.XXXXXX"', True),
    # F2: env's own "X=1", quoted, is NAME=value to env; mktemp still runs with its template, which is safe.
    ('env -i "X=1" mktemp /tmp/a.$$.XXXXXX', False),
    ("env -i 'X=1' X2=2 mktemp /tmp/a.$$.XXXXXX", False),
    ("env -S 'mktemp \"/tmp/$(id -u).XXXXXX\"'", True),
    ('env -S "printf s > /tmp/out.$$"', True),
    # cmux#41336 review, F2: a file's mode is no proof mktemp made it; only the paths it made are.
    (": > /tmp/out.$$; chmod 600 /tmp/out.$$", True),
    ("mkdir /tmp/out.$$; chmod 700 /tmp/out.$$", True),
    ("f=$(mktemp -u /tmp/$USER.XXXXXX); : > \"$f\"", True),
    ("mktemp -du /tmp/$USER.XXXXXX", True),
    ("mktemp --dry-run /tmp/$USER.XXXXXX", True),
    ("mktemp -d /tmp/$USER.XXXXXX", False),
    ('env -S "mktemp" /tmp/$USER.XXXXXX', False),
    # upstream #4368 review at cfd7897e, F4: env -i and command -p find mktemp on the default PATH,
    # past the fake one; bash_writes() runs the fake by its own path, so nothing reaches the real temp folder.
    ("d=$(env -i mktemp -d)", False),
    ("env -i mktemp", False),
    ("command -p mktemp -d", False),
    # a downstream review at 52412c22, F4: mktemp by its path runs the fake too.
    ("/usr/bin/mktemp", False),
    ("d=$(env -i /usr/bin/mktemp -d)", False),
    # a downstream review, F1: a shell inside a shell runs, so bash checks it too.
    ("env -S \"bash -c 'printf x > /tmp/out.$$'\"", True),
    ("sh -c 'printf x > /tmp/out.$$'", True),
    # upstream #4380 review at 27a11d16, F2: bash's time runs -f, so the path is mktemp's argument
    # nowhere, and no template; GNU time runs mktemp.
    ("time -f F mktemp /tmp/$USER.XXXXXX", True),
    ("time -o out mktemp -d /tmp/$USER.XXXXXX", True),
    ("command time -f F mktemp /tmp/$USER.XXXXXX", False),
    ("/usr/bin/time -f F mktemp /tmp/$USER.XXXXXX", False),
    # upstream #4441 review, F4: GNU time is on the scratch PATH, so a row that runs it runs it, and one that writes is
    # seen.
    ("command time -o /tmp/out.$$ true", True),
    ("command time -o /tmp/out.$$ mktemp -d /tmp/$USER.XXXXXX", True),
)

# Where a NAME=value word sets NAME, as bash reads it: (text, the names it sets, "?" for one whose name only a run can
# tell). Each row is what bash did with it (upstream #4382 review at 311cf8e9, F1), and the
# sweep's test runs bash on each to keep it so: before the command, bash takes NAME=value only with its name
# unquoted, so "X"_Y=0 cmd runs a command named X_Y=0; env and the declaration builtins (DECLARES) read their
# words after quote removal, so env "X"_Y=0 cmd and export X_"Y"=0 set X_Y. After exec, NAME=value is the command.
ASSIGNMENT_WORDS = (
    ("X_TIMEOUT=0 cmd", ["X_TIMEOUT"]),
    ('"X_TIMEOUT"=0 cmd', []),
    ('X_"TIMEOUT"=0 cmd', []),
    ('"X"_Y=0 cmd', []),
    ("X\\_Y=0 cmd", []),
    ("$'X'=0 cmd", []),
    ('env "X_TIMEOUT"=0 cmd', ["X_TIMEOUT"]),
    ('env X_"TIMEOUT"=0 cmd', ["X_TIMEOUT"]),
    ('env "X"_Y=0 cmd', ["X_Y"]),
    ("env X\\_Y=0 cmd", ["X_Y"]),
    ("env $'X'=0 cmd", ["X"]),  # a $'...' string is decoded as bash decodes it (_ansi_c)
    ('env -u HOME -- "X_T"=0 cmd', ["X_T"]),
    ('export "X_TIMEOUT"=0; cmd', ["X_TIMEOUT"]),
    ('export X_"TIMEOUT"=0; cmd', ["X_TIMEOUT"]),
    ('export "X"_Y=0; cmd', ["X_Y"]),
    ("export X\\_Y=0; cmd", ["X_Y"]),
    ("export $'X'=0; cmd", ["X"]),
    ('declare -x "X_T"=0; cmd', ["X_T"]),
    ('f() { local -x "X_T"=0; cmd; }; f', ["X_T"]),
    ('readonly "X_T"=0; export X_T; cmd', ["X_T"]),
    ("exec X_T=0 cmd", []),
    ("time -p X_T=0 cmd", ["X_T"]),
    # upstream #4380 review at 27a11d16, F3: after exec's options too, NAME=value is the command.
    ("exec -a name X_T=0 cmd", []),
    ("exec -c X_T=0 cmd", []),
    ("exec -l X_T=0 cmd", []),
    ("exec -cl -a name X_T=0 cmd", []),
    # a downstream review, F1: exec -a name X_TIMEOUT=0 cmd runs a command named X_TIMEOUT=0.
    ("exec -a name X_TIMEOUT=0 cmd", []),
    # a downstream review at 4b4f59b6, F1: env's NAME=value words after its options.
    ('env -i PATH="$PATH" X_T=0 cmd', ["PATH", "X_T"]),
    ("env -- X_T=0 cmd", ["X_T"]),
    ("env -u HOME X_T=0 cmd", ["X_T"]),
    ("env -C / X_T=0 cmd", ["X_T"]),
    ("env -S 'X_T=0 cmd'", ["X_T"]),
    # cmux#41371 review, F2: env reads its quoted NAME=value words after quote removal.
    ('env -u HOME "X_T=1" cmd', ["X_T"]),
    # a downstream review, F2: -S's string attached to its option, short and long.
    ("env -SX_T=0 cmd", ["X_T"]),
    ("env -S'X_T=0 cmd'", ["X_T"]),
    ("env --split-string=X_T=0 cmd", ["X_T"]),
    ("env --split-string='X_T=0 cmd'", ["X_T"]),
    ("time X_T=0 cmd", ["X_T"]),
    ("command time -p env X_T=0 cmd", ["X_T"]),
    # upstream #4382 review, F1: a declaration's word after quote removal and escapes.
    ('export "X_TIMEOUT=0"; cmd', ["X_TIMEOUT"]),
    ("export X_TIMEOUT\\=0; cmd", ["X_TIMEOUT"]),
    ('"X_T=0" cmd', []),
    ("X_T\\=0 cmd", []),
    # F2: a function's body and a coprocess are commands like any other.
    ("function f { X_TIMEOUT=0 cmd; }; f", ["X_TIMEOUT"]),
    ("function f() { X_T=0 cmd; }; f", ["X_T"]),
    ("function f ( ) ( X_T=0 cmd ); f", ["X_T"]),
    ("coproc X_T=0 cmd 1>&2; wait", ["X_T"]),
    ("coproc { X_T=0 cmd 1>&2; }; wait", ["X_T"]),
    ("coproc NAME { X_T=0 cmd 1>&2; }; wait", ["X_T"]),
    # upstream #4441 review: a coprocess's NAME is never run, but its substitutions are; a quoted "coproc" is a command
    # named coproc (here a function), never the keyword.
    ('coproc "$(X_T=0 cmd 1>&2; echo N)" { true; }; wait', ["X_T"]),
    ("coproc $(X_T=0 cmd 1>&2; echo N) ( true ); wait", ["X_T"]),
    ('function coproc { cmd; }; "coproc" X_T=0 cmd', []),
    # upstream #4419 review, F1: export is a declaration only where bash runs it; after env or nice it is a program.
    ("env -S 'export X_T=0'; cmd", []),
    ("env export X_T=0; cmd", []),
    ("nice export X_T=0; cmd", []),
    ("command export X_T=0; cmd", ["X_T"]),
    ("builtin export X_T=0; cmd", ["X_T"]),
    # upstream #4419 review, F2: a quoted name after a word only a run can tell; env "$V" may be NAME=value or the
    # command.
    ('V=--; env "$V" X_"T"=0 cmd', ["V", "?"]),
)

# The command each text runs, as bash runs it (upstream #4380 review at 27a11d16, F2): bash's
# reserved word time takes -p and nothing else, so `time -f F cmd` runs a command named -f; only GNU time (command
# time, /usr/bin/time, a time after NAME=value, a quoted "time") takes -f and -o. And exec's NAME=value is the command
# (F3). The sweep runs bash on each row: `cmd` prints that it ran, and any other name is not found.
RUN_WORDS = (
    # upstream #4441 review: coproc is the keyword only unquoted and where a command starts.
    ('"coproc" cmd', "coproc"),
    ("\\coproc cmd", "coproc"),
    ("X=1 coproc cmd", "coproc"),
    ('coproc cmd; read -r line <&"${COPROC[0]}"; echo "$line"; wait', "cmd"),
    ("time cmd", "cmd"),
    # a downstream review: what exec -a and an attached env -S run.
    ("exec -a name X_TIMEOUT=0 cmd", "X_TIMEOUT=0"),
    ("env -SX_T=0 cmd", "cmd"),
    ("env --split-string=X_T=0 cmd", "cmd"),
    ("time -p cmd", "cmd"),
    ("time -- cmd", "cmd"),
    ("time -p -- cmd", "cmd"),
    ("time -f F cmd", "-f"),
    ("time -o out cmd", "-o"),
    ("time -p -f F cmd", "-f"),
    ("time --portability cmd", "--portability"),
    ("time time -f F cmd", "-f"),
    ("! time -f F cmd", "-f"),
    ("if time -f F cmd; then :; fi", "-f"),
    ("command time -f F cmd", "cmd"),
    ("/usr/bin/time -f F cmd", "cmd"),
    ("X=1 time -f F cmd", "cmd"),
    ('"time" -f F cmd', "cmd"),
    ("exec -a name X=1 cmd", "X=1"),
    ("exec -c X=1 cmd", "X=1"),
    ("exec -l X=1 cmd", "X=1"),
    # upstream #4434 review, F1: bash's time takes one unquoted -p and one unquoted --; the next word is the command.
    ("time -p -p cmd", "-p"),
    ('time "-p" cmd', "-p"),
    ("time '-p' cmd", "-p"),
    ("time \\-p cmd", "-p"),
    ('time -p "--" cmd', "--"),
    ('time "--" cmd', "--"),
    ("time -- -- cmd", "--"),
    ("time -- -p cmd", "-p"),
    ("time -p -- -p cmd", "-p"),
    # upstream #4490 review, F3: GNU time is a program, by its path or after command, so NAME=value after it is the
    # command.
    ("command time X_T=0 cmd", "X_T=0"),
    ("/usr/bin/time X_T=0 cmd", "X_T=0"),
    # upstream #4382 review, F1: before a command, a quoted or escaped = makes no assignment.
    ('"X_T=0" cmd', "X_T=0"),
    ("X_T\\=0 cmd", "X_T=0"),
)


# What may redefine the name mktemp before it runs (a downstream review, security F1): a function,
# an alias, and code this does not read (a sourced file, eval, enable, a command named by a variable). Each writes
# its secret where the template names when mktemp is it.
SHADOWS = {
    "function": 'mktemp() { printf secret > "$1"; }; ',
    "function, blank": 'mktemp () { printf secret > "$1"; }\n',
    "function keyword": 'function mktemp { printf secret > "$1"; }; ',
    # cmux#41482 review at 657379ab, security F1: a continued line between the name and ().
    "function, continued": 'mktemp \\\n() { printf secret > "$1"; }\n',
    "function, name continued": 'mk\\\ntemp() { printf secret > "$1"; }\n',
    "function keyword, continued": 'func\\\ntion mk\\\ntemp \\\n{ printf secret > "$1"; }\n',
    "alias": "shopt -s expand_aliases\nalias mktemp='printf secret >'\n",
    "source": "printf '%s\\n' 'mktemp() { printf secret > \"$1\"; }' > lib\n. ./lib\n",
    "source word": "printf '%s\\n' 'mktemp() { printf secret > \"$1\"; }' > lib; source ./lib; ",
    "eval": "eval 'mktemp() { printf secret > \"$1\"; }'; ",
    "enable": "enable -n echo; ",
    "variable": "printf '%s\\n' 'mktemp() { printf secret > \"$1\"; }' > lib; s=source; $s ./lib; ",
}


def shadow_rows() -> list[tuple[str, bool]]:
    """(text, whether it writes a guessable name or may): each shadow form before a bare mktemp (unsafe: the name may
    be anything), before command mktemp (safe after a function or alias, which command skips; unsafe after code this
    cannot read), and before mktemp by its path (safe)."""
    out = []
    for kind, shadow in SHADOWS.items():
        follows = kind.startswith(("function", "alias"))
        out += [(shadow + "mktemp /tmp/out.$$.XXXXXX", True),
                (shadow + "command mktemp /tmp/$USER.XXXXXX", not follows),
                (shadow + "/usr/bin/mktemp /tmp/$USER.XXXXXX", False)]
        if not kind.startswith("alias"):  # an alias is read as a line is: in $( ) it is defined too late to matter
            inner = shadow.rstrip("; \n")
            out += [("x=$(" + inner + "; :); mktemp /tmp/$USER.XXXXXX", False),
                    ("x=$(" + inner + "; mktemp /tmp/out.$$.XXXXXX)", True)]
    # A command named by a quoted path with a / in it runs a file, never a function or builtin of its name.
    out += [('d=/bin; "$d/true"; mktemp /tmp/$USER.XXXXXX', False),
            ('d=/bin; "${d}/true"; mktemp /tmp/$USER.XXXXXX', False),
            ('a=(eval "mktemp() { printf secret > \\"\\$1\\"; }"); "${a[@]}"; mktemp /tmp/out.$$.XXXXXX', True)]
    return out


def _wrappers() -> list[tuple[str, bool]]:
    out = []
    for w in WRAPPERS_SAFE:
        out += [(w + " mktemp /tmp/$USER.XXXXXX", False), ("d=$(" + w + " mktemp -d /tmp/$USER.XXXXXX)", False),
                (w + " mktemp /tmp/$USER.XXXXXX > /tmp/out.$$", True)]
    out += [(w + " /tmp/out.$$.XXXXXX", True) for w in WRAPPERS_UNSAFE]
    return out


# Each way a process stays while the command inside it runs, nested, the safe mktemp innermost: a sweep's test runs
# each under bash, reads the most processes it held (bash_writes' STATS peak, every process below the reaper, a setsid
# one included), and holds bash_processes() to at least that (upstream #4441 review, F1 and F2). Each stays well under
# MAX_BASH_PROCESSES, so its run is small.
ESTIMATE_DEPTH = 12
COPROC_FORMS = ("coproc { %s; wait; }", "{ coproc { %s; wait; }; wait; }", "! coproc { %s; wait; }; wait")


def estimate_rows() -> list[str]:
    inner = "mktemp /tmp/$USER.XXXXXX"
    out = []
    for forms in [(f,) for f in COPROC_FORMS] + [COPROC_FORMS]:
        line = inner
        for level in range(ESTIMATE_DEPTH):
            line = forms[level % len(forms)] % line
        out.append(line)
    out += ["timeout 5 " * 20 + inner, "setsid -w " * 8 + inner, "command " + "time " * 8 + inner,
            # a shell's -c string, and a name only a run can tell: the tree reads no wrapper in either
            "sh -c '" + "timeout 5 " * 15 + inner + "'", "t=timeout; " + "$t 5 " * 15 + inner]
    out += [shell + " '" + "timeout 5 " * 10 + inner + "'" for shell in SHELL_FORMS]
    out += ['sh -c "' + "timeout 5 " * 10 + inner + '"',
            # a -c script only a run can tell: never run, counted past MAX_BASH_PROCESSES (UNKNOWN_SCRIPT)
            "t=timeout; S=\"" + "$t 5 " * 15 + inner + "\"; bash -c \"$S\""]
    return out


# How bash takes the options before its -c script (upstream #4490 review, F1): an operand after -o, +o and --rcfile, the
# script after options that follow -c. Each form runs a -c script whose programs count.
SHELL_FORMS = ("bash -o errexit -c", "bash +o posix -c", "bash -eo pipefail -c", "bash --rcfile /dev/null -c",
               "bash --init-file /dev/null -c", "bash -c -e", "bash -e -c --", "sh -c",
               # an o or O anywhere in a group, and more than one: each takes a word (cmux#41745's F2, on upstream
               # #4558)
               "bash -cO extglob", "bash +O extglob -c", "bash -coo errexit nounset", "bash -Oc extglob",
               "bash -eO extglob -c")


# Text the parser must refuse, so it exempts nothing and its name is flagged: not shell bash reads (NOT_SHELL), or
# nested past MAX_DEPTH. (MAX_DEPTH levels of the same parse, and stay safe.)
NOT_SHELL = ("mktemp /tmp/a.$$.XXXXXX)", "(mktemp /tmp/a.$$.XXXXXX", 'mktemp "/tmp/a.$$.XXXXXX',
             "d=$(mktemp /tmp/a.$$.XXXXXX", "mktemp /tmp/a.$$.XXXXXX))")


def _deep(levels: int, write: str = "") -> str:
    line = "mktemp /tmp/$USER.XXXXXX" + write
    for _ in range(levels):
        line = "echo $(" + line + ")"
    return "d=" + line[len("echo "):] if levels else line


# A depth bash runs well inside MAX_BASH_PROCESSES and ORACLE_SECONDS: the twin of each tree-only depth fixture.
BASH_TWIN_DEPTH = 20
UNPARSED = NOT_SHELL + (_deep(MAX_DEPTH + 1), _deep(200), "x=${a:-" * 300 + "}" * 300 + " > /tmp/out.$$")


def _wrap(inner: str, form: str) -> str:
    if form == "`":
        return "`" + inner.replace("\\", "\\\\").replace("`", "\\`") + "`"
    return '"$(' + inner + ')"' if form == '"$(' else "$(" + inner + ")"


def corpus() -> list[tuple[str, bool]]:
    """(shell, whether it writes a guessable shared-temp name): nesting depth 0-3 x substitution form x the
    template's quoting x a plain or nested template x where the unsafe write sits (none: the line is safe), then
    COMMENTS, UNPARSED, NOT_COMMANDS, EXPANSIONS, DATA_SUBS, CASE_IN_SUBS, QUOTE_STATE and the WRAPPERS,
    MAX_DEPTH levels deep, and the MISSES. Whole files are in FILES."""
    out: dict[str, bool] = {}
    templates = {"bare": "/tmp/$USER.XXXXXX", "double": '"${TMPDIR:-/tmp}/$USER.XXXXXX"',
                 "single": "'/tmp/$USER.XXXXXX'"}
    for depth in range(4):
        for form in ("$(", '"$(', "`"):
            for quoting, template in templates.items():
                bad = '"/tmp/out.$$"' if quoting == "double" else "/tmp/out.$$"
                for nested in (False, True):
                    t = template
                    if nested:  # a template whose directory is another mktemp's output
                        t = '"' + _wrap("mktemp -d " + template, form).strip('"') + '/x.XXXXXX"'
                    shaped = bad[:-1] + '.XXXXXX"' if bad.endswith('"') else bad + ".XXXXXX"
                    inner_sub = _wrap("printf s > " + bad, form).strip('"')
                    places = {
                        None: ("mktemp " + t, ""),
                        "after": ("mktemp " + t, "; printf s > " + bad),
                        "on mktemp": ("mktemp " + t + " > " + bad, ""),
                        "fd on mktemp": ("mktemp " + t + " 2>>" + bad, ""),
                        "template-shaped target": ("mktemp " + t + " >" + shaped, ""),
                        "beside, same depth": ("mktemp " + t + " && cp a " + bad, ""),
                        "in the template": ('mktemp "/tmp/' + inner_sub + 'x.XXXXXX"', ""),
                        "here-document": ("mktemp " + t, "; cat <<'EOF' > " + bad + "\nbody\nEOF"),
                        "here-document body": ("mktemp " + t, "\ncat <<EOF\n" + inner_sub + "\nEOF"),
                        "in an expansion": ("mktemp ${TMPDIR:-" + inner_sub + "}/x.XXXXXX", ""),
                    }
                    for place, (core, tail) in places.items():
                        line = core
                        for _ in range(depth):
                            line = "echo " + _wrap(line, form)
                        if depth:
                            line = "d=" + line[len("echo "):]
                        out.setdefault(line + tail, place is not None)
    for line, unsafe in COMMENTS:
        out[line] = unsafe
    for line in UNPARSED:
        out[line] = True
    for line, unsafe in (NOT_COMMANDS + EXPANSIONS + tuple(_data_subs()) + tuple(_case_in_subs()) + QUOTE_STATE
                         + tuple(_wrappers()) + ENV_SPLIT):
        out[line] = unsafe
    out[_deep(MAX_DEPTH)] = False
    out[_deep(MAX_DEPTH, "; echo > /tmp/out.$$")] = True
    # _deep(200) is tree-only (TREE_ONLY); its bash-sized twin is run by bash too.
    out[_deep(BASH_TWIN_DEPTH)] = False
    out[_deep(BASH_TWIN_DEPTH, "; echo > /tmp/out.$$")] = True
    for line, unsafe in shadow_rows():
        out[line] = unsafe
    for line in MISSES:
        out[line] = True
    return sorted(out.items())


# Whole files (path, text, whether a line in it must be flagged), which a sweep reads through scan_file(): the
# here-document, continuation and multi-line quote cases a line-by-line read gets wrong. A sweep's test writes each
# into a scanned folder of a scratch repository and runs its hits() there.
FILES = (
    # a downstream review at 0ea8b97f, F2: line by line, this body line reads as a comment.
    ("scripts/heredoc-comment.sh", "#!/bin/sh\ncat <<EOF\n# $(printf secret > /tmp/out.$$)\nEOF\n", True),
    ("scripts/heredoc-tabs.sh", "cat <<-EOF\n\t# `printf secret > /tmp/out.$$`\n\tEOF\n", True),
    ("scripts/heredoc-quoted.sh", "cat <<'EOF' > \"$f\"\n# printf secret > /tmp/out.$$\nEOF\n", True),
    ("scripts/heredoc-then.sh", "cat <<EOF > \"$f\"\nhello\nEOF\nprintf s > /tmp/out.$$\n", True),
    ("scripts/heredoc-safe.sh", "d=$(mktemp -d /tmp/$USER.XXXXXX)\ncat <<EOF > \"$d/x\"\n# a comment-like line\nEOF\n",
     False),
    ("scripts/continued.sh", "d=$(mktemp -d \\\n  /tmp/$USER.XXXXXX)\n", False),
    ("scripts/continued-write.sh", "mktemp /tmp/$USER.XXXXXX \\\n  > /tmp/out.$$\n", True),
    ("scripts/quote-lines.sh", 'echo "one\n# two > /tmp/out.$$"\n', True),
    ("scripts/quote-template.sh", 'd=$(mktemp -d "${TMPDIR:-/tmp}/$USER\\\n.XXXXXX")\n', False),
    ("scripts/case.sh", "case $1 in\n  a) d=$(mktemp -d /tmp/$USER.XXXXXX) ;;\nesac\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n",
     True),
    ("scripts/case-safe.sh", "case $1 in\n  a) d=$(mktemp -d /tmp/$USER.XXXXXX) ;;\n  *) exit 1 ;;\nesac\n", False),
    ("scripts/array.sh", "SSH=(ssh -o BatchMode=yes)\npaths=(mktemp\n  /tmp/out.$$.XXXXXX)\n", True),
    ("scripts/array-safe.sh", "SSH=(ssh -o BatchMode=yes)\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n", False),
    ("scripts/shebang", "#!/usr/bin/env bash\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n", True),
    ("scripts/workflow.yml", "jobs:\n  a:\n    steps:\n      - run: |\n          cat <<EOF\n          # $(printf s > /tmp/out.$$)\n"
     "          EOF\n", True),
    # upstream #4368 review at 3aa1ae3e, F2: in an unquoted here-document, abc\ and EOF join into
    # one line, so the body goes on and bash runs the substitution; quoted, or with the backslash escaped, it ends.
    ("scripts/heredoc-continued.sh", "cat <<EOF\nabc\\\nEOF\n# $(printf secret > /tmp/out.$$)\nEOF\n", True),
    ("scripts/heredoc-continued-tabs.sh",
     "cat <<-EOF\n\tabc\\\n\tEOF\n\t# $(printf secret > /tmp/out.$$)\n\tEOF\n", True),
    ("scripts/heredoc-continued-quoted.sh", "cat <<'EOF'\nabc\\\nEOF\n# $(printf secret > /tmp/out.$$)\n", False),
    ("scripts/heredoc-continued-escaped.sh", "cat <<EOF\nabc\\\\\nEOF\n# $(printf secret > /tmp/out.$$)\n", False),
    # Wrapper review, F2: a #! line through env -S (or any wrapper) is still a shell's, so the file is read whole; one
    # the unwrapping cannot resolve is a hit of its own (shell_tree.shebang), never read line by line unnoticed.
    ("scripts/env-split", "#!/usr/bin/env -S bash -e\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n", True),
    ("scripts/env-split-assign", "#!/usr/bin/env -S LC_ALL=C bash\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n",
     True),
    ("scripts/env-split-safe", "#!/usr/bin/env -S bash -e\ncat <<EOF\nhello\nEOF\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n",
     False),
    ("scripts/shebang-unresolved", "#!/usr/bin/env --bogus bash\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n", True),
    # cmux#41336 review at c1c62c86, F2: env -S splits its string as env does, quotes included, so
    # 'bash' is bash; a string it cannot split (an open quote, a $ it would expand) leaves the #! line unresolved.
    ("scripts/env-split-quoted", "#!/usr/bin/env -S 'bash' -e\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n", True),
    ("scripts/env-split-dquoted", '#!/usr/bin/env -S "bash" -e\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n', True),
    ("scripts/env-split-open-quote", "#!/usr/bin/env -S 'bash -e\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n", True),
    ("scripts/env-split-expands", "#!/usr/bin/env -S ${SHELL} -e\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n", True),
    ("scripts/env-split-python", "#!/usr/bin/env -S 'python3' -u\nimport os\n", False),
    ("scripts/shebang-python", "#!/usr/bin/env python3\nimport os\n", False),
    # a downstream review at cd22cde4, F2: this parser does not read extglob, so the file does not
    # parse whole; read line by line, the here-document's body line was a comment, though bash runs it.
    ("scripts/extglob-heredoc.sh",
     "shopt -s extglob\ncase x in @(x|y)) :;; esac\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n", True),
    # A shell block this parser cannot read is reported unresolved, even with no temp name in it: what it runs is
    # unknown. The same text inside a workflow's run block.
    ("scripts/extglob-only.sh", "shopt -s extglob\ncase x in @(x|y)) :;; esac\n", True),
    ("scripts/extglob.yml", "jobs:\n  a:\n    steps:\n      - run: |\n          shopt -s extglob\n"
     "          case x in @(x|y)) :;; esac\n", True),
    ("scripts/workflow-safe.yml", "jobs:\n  a:\n    steps:\n      - run: |\n          d=$(mktemp -d \\\n"
     "            /tmp/$USER.XXXXXX)\n", False),
)


# The differential detector: what bash does with a fixture, beside what the tree reads in it. bash_writes() runs it
# in a scratch folder of its own; a sweep checks that every fixture bash writes a guessable name with is one the tree
# flags and the corpus calls unsafe. Real /tmp names are never touched: each /tmp in the text is moved into the folder.
# mktemp by its name or by any path (/usr/bin/mktemp: a downstream review at 52412c22, F4).
MKTEMP_WORD = re.compile(r"(?<![\w./-])(?:(?:/[\w.-]+)*/)?mktemp(?![\w.-])")
MKTEMP_PATH = re.compile(r"(?<![\w./-])(?:/[\w.-]+)*/mktemp(?![\w.-])")
TMP_PATH = re.compile(r"(?<![\w.])(?:/private)?/tmp(?![\w.-])")
MKTEMP = """#!/bin/sh
out=$(TMPDIR=%s %s "$@") || exit $?
[ -e "$out" ] && printf '%%s\\n' "$out" >> %s
printf '%%s\\n' "$out"
if [ -n "$SHELL_TREE_PEAK" ] && [ -d /proc/self ]; then
  %s -I -S -c 'import os, sys
kids = {}
for d in os.listdir("/proc"):
    try:
        kids.setdefault(int(open("/proc/" + d + "/stat").read().rsplit(")", 1)[1].split()[1]), []).append(int(d))
    except (OSError, ValueError, IndexError):
        continue
n, todo = 0, [int(sys.argv[1])]
while todo:
    for pid in kids.get(todo.pop(), []):
        n += pid != os.getpid()
        todo.append(pid)
print(n)' "$SHELL_TREE_ROOT" >> "$SHELL_TREE_PEAK"
fi
"""
# The most processes one bash run may hold at once. Bash keeps one live process per level of nested substitutions,
# so a fixture nested deeper than this is never run (the tree alone reads it): near a host's process limit, bash's
# fork retries and backs off for seconds, past any time budget. bash_verdicts() keeps the runs in flight under
# PROCESS_BUDGET together.
MAX_BASH_PROCESSES = 48
PROCESS_BUDGET = 64


# Runs bash (argv[3:]) in a session of its own, writes its pid to argv[2], and waits for it and every process it
# leaves: as the child subreaper (Linux), every orphan of the run is its child, a setsid one included, so it waits
# until none is left. Bash runs in a session and process group of its own, and the reaper also waits until that group
# is empty: where it is no subreaper (macOS), a process bash leaves in the background is init's child, never its own,
# and only the group still holds it (upstream #4647 review, F2). Past argv[1] seconds it kills the group and every
# process below it, and exits 124. It waits for SIGCHLD with sigtimedwait where the host has it, and else sleeps a few
# milliseconds between checks (macOS has no sigtimedwait: cmux#41809 review, F2). It writes "PID SUBREAPER" (1 or 0)
# to argv[2]. Where it is no subreaper, a process that leaves the group (setsid, job control) is out of its sight:
# with SHELL_TREE_NEEDS_SUBREAPER set it runs nothing and exits 126. It exits 0 when bash and every process it left
# are gone; any other status (a crash) is no answer (bash_writes()). It owns bash from the moment it starts it: an
# error anywhere after that, the pid write included, kills bash's group and every process below the reaper (what it
# adopted, a setsid one included) before it exits 1, since once it is gone they are init's and nothing holds them
# (cmux#41862 review, F1; upstream #4657 review, F2).
REAPER = r"""
import ctypes, os, signal, subprocess, sys, time
deadline = time.monotonic() + float(sys.argv[1])
try:
    subreaper = ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0  # PR_SET_CHILD_SUBREAPER
except (AttributeError, OSError):
    subreaper = False
if not subreaper and os.environ.get("SHELL_TREE_NEEDS_SUBREAPER"):
    os._exit(126)
wait = getattr(signal, "sigtimedwait", None)
if wait:
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGCHLD])


def below():
    kids = {}
    if os.path.isdir("/proc/self"):
        for d in os.listdir("/proc"):
            try:
                with open("/proc/" + d + "/stat") as f:
                    kids.setdefault(int(f.read().rsplit(")", 1)[1].split()[1]), []).append(int(d))
            except (OSError, ValueError, IndexError):
                continue
    else:
        ps = subprocess.run(["ps", "-Ao", "pid=,ppid="], stdin=subprocess.DEVNULL, capture_output=True, text=True,
                            timeout=10)
        for line in ps.stdout.split("\n"):
            if len(line.split()) == 2:
                kids.setdefault(int(line.split()[1]), []).append(int(line.split()[0]))
    out, todo = [], [os.getpid()]
    while todo:
        for pid in kids.get(todo.pop(), []):
            out.append(pid)
            todo.append(pid)
    return out


def reap(block):
    try:
        while os.waitpid(-1, 0 if block else os.WNOHANG)[0]:
            block = False
        return True
    except ChildProcessError:
        return False


# Whether a process (a zombie init has not reaped yet included) is left in bash's process group; True when the check
# itself fails, so a doubt is never read as empty.
def group():
    try:
        os.killpg(bash.pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


def kill_group():
    try:
        os.killpg(bash.pid, signal.SIGKILL)
    except OSError:
        pass


# Kill bash's group and every process below the reaper until it has no child left, then wait (5 s at most) for the
# group to empty. A below() that fails still kills the group and reaps what is left.
def kill_all():
    kill_group()
    while True:
        try:
            pids = below()
        except Exception:
            pids = []
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        kill_group()
        if not reap(True):
            break
    end = time.monotonic() + 5
    while group() and time.monotonic() < end:
        kill_group()
        time.sleep(0.01)


def run():
    with open(sys.argv[2], "w") as f:
        f.write("%d %d\n" % (bash.pid, subreaper))
    while True:
        kids = reap(False)
        if not kids and not group():
            os._exit(0)
        left = deadline - time.monotonic()
        if left <= 0:
            kill_all()
            os._exit(124)
        if kids and wait:
            wait([signal.SIGCHLD], min(left, 0.05))
        else:
            time.sleep(min(left, 0.005))


bash = subprocess.Popen(sys.argv[3:], start_new_session=True, env=dict(os.environ, SHELL_TREE_ROOT=str(os.getpid())))
try:
    run()
except BaseException:
    kill_all()
    os._exit(1)
"""
# How long past its own deadline the reaper may take to stop before its own group is killed.
REAPER_GRACE = 5


def below(root: int) -> list[tuple[int, str]]:
    """(pid, state) of every process below ROOT, from /proc (Linux) or ps: as the reaper reads them."""
    kids: dict[int, list] = {}
    if os.path.isdir("/proc/self"):
        for d in os.listdir("/proc"):
            try:
                with open("/proc/" + d + "/stat") as f:
                    fields = f.read().rsplit(")", 1)[1].split()
                kids.setdefault(int(fields[1]), []).append((int(d), fields[0]))
            except (OSError, ValueError, IndexError):
                continue
    else:
        ps = subprocess.run(["ps", "-Ao", "pid=,ppid=,state="], stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, timeout=10)
        for line in ps.stdout.split("\n"):
            if len(line.split()) == 3:
                pid, ppid, state = line.split()
                kids.setdefault(int(ppid), []).append((int(pid), state[0]))
    out, todo = [], [root]
    while todo:
        for pid, state in kids.get(todo.pop(), []):
            out.append((pid, state))
            todo.append(pid)
    return out


def kill_below(root: int, seconds: float = REAPER_GRACE) -> list[int]:
    """SIGKILL every process below ROOT, again as long as one is left (a fork between reads), for at most SECONDS; the
    pids of those still alive then (none, unless one cannot die). A zombie is dead: ROOT reaps it, or init once ROOT
    is gone."""
    end = time.monotonic() + seconds
    while True:
        live = [pid for pid, state in below(root) if state != "Z"]
        if not live or time.monotonic() >= end:
            return live
        for pid in live:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.01)


PID_LINE = re.compile(r"([1-9][0-9]*) ([01])\n?")


def read_pid(pidfile: str) -> tuple[int | None, bool | None]:
    """(bash's pid, whether the reaper is a child subreaper) from the reaper's PIDFILE: (None, None) when it is
    missing, or holds anything but the one line the reaper writes, "PID SUBREAPER" with SUBREAPER 1 or 0 (it never
    wrote it, died mid-write, or something else did). A pid read from other text would name a process to kill
    (stop_run()), so a doubt is no pid (cmux#41925 review, F1: `123 nope` and `123 0 extra` named pid 123)."""
    try:
        with open(pidfile) as f:
            got = PID_LINE.fullmatch(f.read())
    except (OSError, ValueError):
        return None, None
    if not got:
        return None, None
    return int(got[1]), got[2] == "1"


def stop_run(pidfile: str) -> None:
    """SIGKILL the bash run whose pid PIDFILE holds (none when it is empty or missing), what is below it, and its
    process group: what a reaper that failed left running."""
    pid, _ = read_pid(pidfile)
    if pid is None:
        return
    kill_below(pid)
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


class OracleUnavailable(RuntimeError):
    """Bash gave no answer for a row, and REASON says why: past its time (BashTimeout), out of processes (a fork
    failed, or it would hold more than MAX_BASH_PROCESSES at once), bash -n refuses it, or (SKIPPED) the host lacks a
    capability the row needs (needs(); a sweep's requires()). Falsy, so it is never read as "bash wrote" or as
    agreement. A differential check fails on one unless TREE_ONLY lists its row or it is SKIPPED (no_oracle();
    cmux#41336 review)."""

    def __init__(self, reason: str, text: str = "", skipped: bool = False):
        super().__init__(f"no answer from bash ({reason}): {text[:200]}")
        self.reason, self.text, self.skipped = reason, text, skipped

    def __bool__(self) -> bool:
        return False


class BashTimeout(OracleUnavailable):
    """A bash run past its time; its process group (PGID) is killed, and the message names the fixture."""

    def __init__(self, text: str, timeout: float, pgid: int):
        RuntimeError.__init__(self, f"bash ran past {timeout:g} s on this fixture, and its process group {pgid} was "
                              f"killed: {text}")
        self.reason, self.text, self.skipped = f"bash ran past its {timeout:g} s budget (ORACLE_SECONDS)", text, False
        self.pgid = pgid


# Words in TEXT that may start a process outside bash's process group, which only a child subreaper (Linux) sees:
# setsid, and job control (set -m, set -o monitor, a shell's own -i, -m or -o monitor), read in leaves_group()'s
# plain text. A set or eval with a word only a run can tell ($o, $(...), `...`, $'...'), or a shell with one among its
# options, may turn job control on too.
_SHELL_OPTIONS = (r"(?<![\w.-])(?:ba|da|z|k|mk|a)?sh"
                  r"(?:\s+(?:--[\w-]+|[-+][oO]\s+[^\s;|&-][^\s;|&]*|[-+][A-Za-z]+))*?\s+")
LEAVES_GROUP = re.compile(r"(?<![\w.-])setsid(?![\w.-])|\bset\b[^\n;|&]*(?:\s[-+][A-Za-z]*m|\bmonitor\b)|"
                          + _SHELL_OPTIONS + r"(?:[-+][A-Za-z]*[im][A-Za-z]*(?![\w-])|[-+]o\s+monitor\b|"
                          r"--login\b|--interactive\b)|"
                          r"\b(?:set|eval)\b[^\n;|&]*[$`]|" + _SHELL_OPTIONS + r"[-+]?[$`]")


def leaves_group(text: str) -> bool:
    """Whether TEXT may start a process outside bash's process group (LEAVES_GROUP), read as bash reads it: a
    continued line joined, and quotes and backslashes taken out, so set '-m', s'e't -m and set -o mon''itor are set -m
    and set -o monitor; an ANSI-C $'...' keeps its $ and is a word only a run can tell. A doubt is True: such a run is
    then never made where the reaper is no subreaper (upstream #4657 review, F1)."""
    return bool(LEAVES_GROUP.search(re.sub(r"[\"'\\]", "", text.replace("\\\n", ""))))


# The wrappers that stay as a process of their own around the command they run (timeout and GNU time wait for it;
# setsid forks when it leads its group), and bash's coproc keyword's subshell. env, nice, nohup, stdbuf and exec run
# the command in their own place.
FORKING = {"timeout", "time", "setsid", "coproc keyword"} | SHELLS
# A word in TEXT, wherever it sits (a quoted string a shell inside the shell runs included), that may name a process
# that stays: a FORKING wrapper, coproc, or a shell, which stays while the commands of its -c string run.
STAYS = re.compile(r"(?<![\w.-])(?:timeout|time|setsid|coproc|(?:ba|da|z|k|mk|a)?sh)(?![\w.-])")


class _UnknownScript(Exception):
    """A shell's -c script only a run can tell, or one that does not parse."""


def _holds(text: str, depth: int) -> tuple[int, int]:
    """(the processes TEXT's commands may hold around what they run, the words of commands only a run can tell), into
    each shell's -c script at any depth (bash_processes())."""
    tree = unknown = 0
    for cmd in commands(parse(text), strings=False):  # a shell's -c string is read below, expansions and all
        run = resolve(text, cmd)
        tree += sum(p in FORKING for p in run.through) + _coproc_named(text, cmd)
        if run.words is UNRESOLVED or run.words and "\0" in run.values[0]:
            unknown += len(cmd.words)
            continue
        if run.words and run.values[0].rsplit("/", 1)[-1] in SHELLS:
            tree += 1
            inner = shell_string(run.values)
            if inner == UNKNOWN_SCRIPT or inner is not None and depth >= MAX_DEPTH:
                raise _UnknownScript
            if inner is not None:
                try:
                    more = _holds(inner, depth + 1)
                except Unparsed:
                    raise _UnknownScript from None
                tree, unknown = tree + more[0], unknown + more[1]
    return tree, unknown


def bash_processes(text: str) -> int:
    """An upper bound on the processes bash holds at once running TEXT with no loop that forks in the background:
    bash and the fake mktemp with its substitution, one per (, backtick pair, | and &, and one per process that may
    stay around the command it runs: each wrapper that stays a process, each coprocess and each shell, with what a
    shell's -c string runs, as programs() reads them (cmux#41371 review, F3 and of the vendored copy F2;
    upstream #4441 review, F1: ! coproc, { coproc ...; } and coproc { coproc ...; } each hold a subshell), or, when
    more, each word STAYS finds anywhere in TEXT (upstream #4441 review, F2). And every word of a command whose name
    only a run can tell ($t 5 $t 5 cmd, with t=timeout, holds one per $t), or that unwrap() cannot resolve, may be one.
    A -c script only a run can tell, or one that does not parse, counts past MAX_BASH_PROCESSES (UNKNOWN_SCRIPT;
    upstream #4490 review)."""
    textual = len(STAYS.findall(text))
    try:
        tree, unknown = _holds(text, 0)
    except _UnknownScript:
        return MAX_BASH_PROCESSES + 1
    except Unparsed:
        tree, unknown = textual, 0
    return 4 + text.count("(") + text.count("`") // 2 + text.count("|") + text.count("&") + max(tree, textual) + \
        unknown


# Where a command's NAME=value word may stand, and each quoting of it (cmux#41371 review of the vendored
# copy, F1: env "X=1" mktemp was flagged, since the quoted-name rule of shell assignment syntax was applied to env, which
# gets its words after quote removal). env_rows() is every prefix with every quoting, before a command `cmd`; the
# sweep runs each with bash and holds the tree to what bash runs and sets. An ANSI-C $'...' string is decoded as bash
# decodes it (_ansi_c): env $'X_T=1' cmd sets X_T, and $'X_T=1' cmd runs a command named X_T=1.
ENV_PREFIXES = ("", "env", "env --", "env -u HOME", "nice env", "timeout 5 env", "command env", "env X_A=0",
                "exec env", "time env", "nice -n 1 env -u HOME --")
ENV_QUOTINGS = ("X_T=1", '"X_T=1"', "'X_T=1'", '"X_T"=1', 'X_"T"=1', "'X_T'=1", "X\\_T=1", "X_T\\=1", "X_T='1'",
                '"X_"T=1', "$'X_T=1'")


def env_rows() -> list[str]:
    """Each ENV_PREFIXES with each ENV_QUOTINGS, before the command cmd."""
    return [f"{p} {q} cmd".strip() for p in ENV_PREFIXES for q in ENV_QUOTINGS]


# The wrapper steps a command may be read through, and wrapper_chains() of them (cmux#41371 review of the
# vendored copy, F2: bash_processes() left out wrappers that stay a process, so six nested `timeout 5` were estimated
# at 4 and held 8). The sweep runs each chain with bash and holds bash_processes() to at least the most processes the
# run held at once.
WRAPPER_STEPS = ("timeout 5", "timeout -k 1 5", "env", "env X_T=1", "env -u HOME", "nice", "nice -n 1", "stdbuf -oL")


def wrapper_chains(seed: int = 41371) -> list[str]:
    """Wrapper chains before a mktemp: every pair of the first four WRAPPER_STEPS, seeded random chains of 3 to 12
    steps, and six nested `timeout 5`; each one alone, inside a substitution, and run again by a nested bash -c."""
    import random
    rnd = random.Random(seed)
    chains = [f"{a} {b}" for a in WRAPPER_STEPS[:4] for b in WRAPPER_STEPS[:4]]
    chains += [" ".join(rnd.choice(WRAPPER_STEPS) for _ in range(n)) for n in (3, 4, 6, 8, 12) for _ in range(3)]
    chains.append(" ".join(["timeout 5"] * 6))
    out = []
    for chain in chains:
        line = chain + " mktemp /tmp/$USER.XXXXXX"
        out += [line, f"x=$({line})", f"{chain} bash -c '{line}'"]
    return out


def bash_writes(text: str, timeout: float = 10, stats: dict | None = None) -> bool | None:
    """Whether bash, running TEXT in a scratch folder (each /tmp in it moved there; PATH a folder of its own, whose
    mktemp makes its names there and logs them; TMPDIR the scratch temp folder), creates a file or folder
    no mktemp made; None when bash -n refuses TEXT. A TEXT that would hold more than MAX_BASH_PROCESSES at once is
    never run, and raises OracleUnavailable: no answer, never None, which would agree with the tree's Unparsed
    (cmux#41336 review at 911fed64, F1; cmux dac38efa). Bash reads
    no stdin (it is /dev/null). TMPDIR is the scratch temp folder, the script's own included, so a mktemp that is not
    the fake makes its name there and "$TMPDIR/x" is a scratch path, never / (a downstream review,
    F1); a ${TMPDIR:-...} default does not run. Bash runs under REAPER,
    which waits for every process the run leaves; past TIMEOUT it kills each one, a setsid one included
    (a downstream review at 52412c22, F3), and BashTimeout names TEXT. STATS, when given, gets "runs"
    (0 or 1) and "peak": the most processes bash's session held when a mktemp ran (on Linux)."""
    if stats is not None:
        stats.update(runs=0, peak=0)
    need = bash_processes(text)
    if need > MAX_BASH_PROCESSES:
        raise OracleUnavailable(f"needs {need} processes at once, past MAX_BASH_PROCESSES ({MAX_BASH_PROCESSES})", text)
    bash = shutil.which("bash")
    if not bash:
        raise OracleUnavailable("no bash on this host", text)
    try:
        refused = subprocess.run([bash, "-O", "extglob", "-n"], input=text, text=True, capture_output=True,
                                 timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        raise BashTimeout(text, timeout, 0) from None
    if refused < 0:  # killed by a signal: no answer, never "bash -n refuses it"
        raise OracleUnavailable(f"bash -n was killed by signal {-refused}", text)
    if refused:
        return None
    root = tempfile.mkdtemp(prefix="shell-tree-")
    try:
        tmp, bindir, work = (os.path.join(root, d) for d in ("t", "bin", "work"))
        for d in (tmp, bindir, work):
            os.mkdir(d)
        log = os.path.join(root, "made")
        with open(os.path.join(bindir, "mktemp"), "w") as f:
            f.write(MKTEMP % (tmp, shutil.which("mktemp"), log, shlex.quote(sys.executable)))
        os.chmod(os.path.join(bindir, "mktemp"), 0o700)
        # bash and sh too, so a fixture that runs a shell inside a shell runs (a downstream review,
        # F1): env -S "bash -c '...'" failed before it ran, so the differential check never saw it.
        # And time: a fixture that runs GNU time runs it, never a time that is not found (upstream #4441 review, F4).
        for tool in ("cat", "cp", "mkdir", "touch", "tee", "env", "nice", "nohup", "timeout", "stdbuf", "setsid",
                     "time", "bash", "sh"):
            # A host without one (macOS has no setsid, timeout or stdbuf) runs a fixture that calls it as bash does
            # there: command not found (a downstream review at 7948495f, F2).
            if shutil.which(tool):
                os.symlink(shutil.which(tool), os.path.join(bindir, tool))
        open(os.path.join(work, "a"), "w").close()
        # Each mktemp is the fake by its own path, so env -i and command -p (the default PATH) never reach the real
        # one, which would make its name in the real temp folder (upstream #4368 at cfd7897e, F4).
        # A text where something may redefine the name mktemp (shadows(): a function, an alias, a sourced file) keeps
        # each bare mktemp as it is, so bash runs what that makes of it; the fake is first on PATH all the same. Only
        # a path is the fake by path there, and env -i or command -p, which would reach the real one, is refused.
        try:
            shadowed = shadowed_anywhere(text, parse(text))
        except Unparsed:
            shadowed = False
        fake = MKTEMP_PATH if shadowed else MKTEMP_WORD
        script = fake.sub(os.path.join(bindir, "mktemp"), TMP_PATH.sub(tmp, text))
        if shadowed and re.search(r"\benv\b|\bcommand\s+-\w*p", script):
            raise ValueError("a shadowed mktemp with env or command -p could reach the real one: " + script)
        if TMP_PATH.search(script.replace(root, "")) or "umask" in script:
            raise ValueError("a /tmp path or a umask is left in the script: " + script)
        errors = os.path.join(root, "errors")
        with open(os.path.join(root, "script"), "w") as f:
            # bash's own messages go to a file, so a fork that failed is told from an answer (cmux#41336 review)
            f.write(f"exec 2>>'{errors}'\n" + script)
        env = {"PATH": bindir, "HOME": root, "USER": "u", "LC_ALL": "C", "TMPDIR": tmp}
        if leaves_group(text):
            env["SHELL_TREE_NEEDS_SUBREAPER"] = "1"  # the reaper refuses to run it where it cannot see such a process
        peak_log = os.path.join(root, "peak")
        if stats is not None:
            env["SHELL_TREE_PEAK"] = peak_log
        # The reaper waits for every process the run leaves, process substitutions and setsid ones included, and
        # past TIMEOUT kills them all. Its own group is killed if it outlives that by REAPER_GRACE.
        pidfile = os.path.join(root, "pid")
        run = subprocess.Popen([sys.executable, "-I", "-S", "-c", REAPER, str(timeout), pidfile, bash, "--noprofile",
                                "--norc", os.path.join(root, "script")], cwd=work, env=env,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True, umask=0o022)
        if stats is not None:
            stats["runs"] = 1
        try:
            code = run.wait(timeout=timeout + REAPER_GRACE)
        except subprocess.TimeoutExpired:
            # The reaper outlived its own deadline. What it holds is killed first: once it is gone, its children (a
            # setsid one included, in a session of its own) would be init's and out of reach (upstream #4441 review,
            # F6).
            kill_below(run.pid)
            os.killpg(run.pid, signal.SIGKILL)
            try:
                run.wait(timeout=REAPER_GRACE)
            except subprocess.TimeoutExpired:
                pass  # it cannot die (uninterruptible): BashTimeout names the fixture all the same
            code = 124
        pid, _ = read_pid(pidfile)
        if code == 126:
            raise OracleUnavailable("the run may leave bash's process group (setsid, job control), and this host's "
                                    "reaper is no child subreaper to see such a process", text, skipped=True)
        if code == 124:
            if pid is None:
                # Its pid was never written: nothing is known of the run but what the reaper held, killed above
                # (cmux#41862 review, F2: this read crashed on a missing file).
                stop_run(pidfile)
                raise OracleUnavailable("the reaper ran past its time and wrote no pid", text)
            raise BashTimeout(text, timeout, pid)
        if code == 0 and pid is None:
            raise OracleUnavailable("the reaper exited 0 but wrote no pid: whether bash ran cannot be told", text)
        if code != 0:
            # The reaper failed (it raised, or was killed): bash and what it left may still run, and the scratch
            # folder holds no answer. Stop them, and answer nothing: a crash is never a verdict (cmux#41809 review,
            # F2: macOS has no signal.sigtimedwait, and its exit status 1 was read as "bash wrote nothing").
            stop_run(pidfile)
            raise OracleUnavailable(f"the reaper exited {code}, not 0 or 124: it gave no answer", text)
        if os.path.exists(errors):
            with open(errors, errors="replace") as f:
                if re.search(r"\bfork: ", f.read()):
                    raise OracleUnavailable("a fork failed: bash ran out of processes", text)
        if stats is not None and os.path.exists(peak_log):
            with open(peak_log) as f:
                stats["peak"] = max((int(n) for n in f.read().split()), default=0)
        # A name is mktemp's only when the fake logged it, and the fake logs a name only once it exists (mktemp -u
        # makes none). A file's mode is never evidence: `: > /tmp/out.$$; chmod 600 /tmp/out.$$` is a guessable name
        # (cmux#41336 review, F2). Every mktemp word runs the fake by its path (MKTEMP_WORD).
        made = []
        if os.path.exists(log):
            with open(log) as f:
                made = f.read().split()
        for dirpath, dirs, files in os.walk(tmp):
            for entry in dirs + files:
                p = os.path.join(dirpath, entry)
                mode = os.lstat(p).st_mode & 0o777
                if any(p == m or p.startswith(m + "/") for m in made):
                    continue
                return True
        return False
    finally:
        shutil.rmtree(root, ignore_errors=True)


# The bash oracle's budget for one row: its wall time (ORACLE_SECONDS) and the processes it may hold at once
# (MAX_BASH_PROCESSES). Its answer is True or False, or it raises OracleUnavailable naming why there is none.
ORACLE_SECONDS = 10


# The rows bash is never asked about, each with its reason; every other row must get an oracle answer. A depth
# fixture past MAX_BASH_PROCESSES has a bash-sized twin (BASH_TWIN_DEPTH) in the corpus.
TREE_ONLY = {
    _deep(200): "200 nested substitutions hold 200 processes at once, past MAX_BASH_PROCESSES; near a host's limit "
                "bash's fork backs off past any time budget (cmux#41336 review). Its twin is _deep(BASH_TWIN_DEPTH)",
    **{line: "not shell: bash -n refuses it, and the tree must refuse it too (UNPARSED)" for line in NOT_SHELL},
}


# Each capability (CAPABILITIES) with the text that may need it, for a row the tree cannot parse: needs() names none
# there, so the oracle reads the words, and a host without one skips the row rather than run it.
CAPABILITY_WORDS = {
    "setsid": re.compile(r"(?<![\w.-])setsid(?![\w.-])"),
    "timeout": re.compile(r"(?<![\w.-])timeout(?![\w.-])"),
    "stdbuf": re.compile(r"(?<![\w.-])stdbuf(?![\w.-])"),
    "gnu-time": re.compile(r"(?<![\w.-])time(?![\w.-])"),
    "env-split": re.compile(r"(?<![\w.-])env(?![\w.-]).*(?:\s-\w*S|--split-string|--sp)"),
    "coproc": re.compile(r"(?<![\w.-])coproc(?![\w.-])"),
}


def oracle_needs(text: str) -> list[str]:
    """needs(TEXT), or, when TEXT does not parse, each capability whose words (CAPABILITY_WORDS) it holds: a row the
    tree cannot read never runs without what it may need (a run without setsid is "command not found", a verdict
    on a different script)."""
    try:
        programs(text)
    except Unparsed:
        # A continued line is one line to bash, so `env \` with -S on the next is env -S (cmux#41925 review, F2).
        joined = text.replace("\\\n", "")
        return [c for c, words in CAPABILITY_WORDS.items() if words.search(joined)]
    return needs(text)


def oracle(text: str, timeout: float = ORACLE_SECONDS, missing=None) -> bool:
    """bash_writes(TEXT) within the row's budget: True or False, else raises OracleUnavailable with why there is none.
    MISSING, when given, maps a capability (oracle_needs()) to why this host lacks it, or None: a row that needs one
    it lacks is never run, and its OracleUnavailable is SKIPPED. Any other error of the run (a ValueError for a
    shadowed mktemp with env -i, an OSError, a bug) is this row's OracleUnavailable, named by its type and message,
    never a crash of every row and never a verdict (cmux#41862 review, F1)."""
    try:
        for capability in oracle_needs(text) if missing else ():
            why = missing(capability)
            if why:
                raise OracleUnavailable(f"needs {capability}: {why}", text, skipped=True)
        wrote = bash_writes(text, timeout=timeout)  # past MAX_BASH_PROCESSES it raises OracleUnavailable, never runs
    except OracleUnavailable:
        raise
    except Exception as error:
        raise OracleUnavailable(f"the oracle raised {type(error).__name__}: {error}", text) from error
    if wrote is None:
        raise OracleUnavailable("bash -n refuses it", text)
    if not isinstance(wrote, bool):
        raise OracleUnavailable(f"the oracle answered {wrote!r}, not True or False", text)
    return wrote


def no_oracle(texts: list[str], verdicts: list) -> list[str]:
    """Each of TEXTS whose verdict is OracleUnavailable, not SKIPPED and not in TREE_ONLY, with why: a differential row
    with no oracle answer is a failure, never agreement and never a quiet skip."""
    return [f"{text[:120]!r}: no answer from bash ({v.reason}). Make it fit the budget, or list it in TREE_ONLY "
            "with its reason and add a bash-sized twin" for text, v in zip(texts, verdicts)
            if isinstance(v, OracleUnavailable) and not v.skipped and text not in TREE_ONLY]


def bash_verdicts(texts: list[str], timeout: float = ORACLE_SECONDS, missing=None) -> list:
    """oracle() of each of TEXTS: True, False, or the OracleUnavailable it raised. Several bash runs go at a time, with
    the processes they may hold together (bash_processes) kept under PROCESS_BUDGET."""
    room = threading.Condition()
    free = [PROCESS_BUDGET]

    def one(text: str):
        try:
            cost = min(bash_processes(text), MAX_BASH_PROCESSES)
        except Exception:  # oracle() names the row's error; its cost is the most a row may hold
            cost = MAX_BASH_PROCESSES
        with room:
            room.wait_for(lambda: free[0] >= cost)
            free[0] -= cost
        try:
            return oracle(text, timeout, missing)
        except OracleUnavailable as unavailable:
            return unavailable
        finally:
            with room:
                free[0] += cost
                room.notify_all()

    with ThreadPoolExecutor(max_workers=min(16, (os.cpu_count() or 1) * 2)) as pool:
        return list(pool.map(one, texts))


if __name__ == "__main__":
    if sys.argv[1:] == ["--corpus"]:
        json.dump(corpus(), sys.stdout)
    elif sys.argv[1:] == ["--files"]:  # [[path, text], ...] -> [scan_file(path, text), ...]
        json.dump([scan_file(p, t) for p, t in json.load(sys.stdin)], sys.stdout)
    elif sys.argv[1:] == ["--unparsed"]:  # [[path, text], ...] -> [unparsed(path, text), ...]
        json.dump([unparsed(p, t) for p, t in json.load(sys.stdin)], sys.stdout)
    elif sys.argv[1:] == ["--file-corpus"]:
        json.dump(FILES, sys.stdout)
    elif sys.argv[1:] == ["--bash"]:  # [text, ...] -> [true, false or {"no_oracle": reason}, ...]
        json.dump([v if isinstance(v, bool) else {"no_oracle": v.reason}
                   for v in bash_verdicts(json.load(sys.stdin))], sys.stdout)
    elif sys.argv[1:] == ["--tree-only"]:
        json.dump(TREE_ONLY, sys.stdout)
    elif sys.argv[1:] == ["--no-oracle"]:  # [text, ...] -> no_oracle() of their verdicts
        texts = json.load(sys.stdin)
        json.dump(no_oracle(texts, bash_verdicts(texts)), sys.stdout)
    else:
        json.dump([scan_text(code(t)) for t in json.load(sys.stdin)], sys.stdout)
