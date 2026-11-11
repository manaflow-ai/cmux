"""A small shell parser for lints: shell text becomes a tree of commands, so a lint asks what a word is, never what
text sits near it.

parse(text) returns a Script: its Commands, each with argv Words and Redirects (a here-document's body included).
A Word is a list of parts: Lit (literal text, quoted or not), Param ($x, ${x...}), Arith ($(( ))) and Sub (a
command substitution, $( ) or backticks, or a process substitution <( ) or >( )), whose script is parsed the same
way, to any depth, inside ${ } too. Every node keeps its start and end offset in the text parse() was given,
backticks inside backticks included. An array's words, a case subject and its patterns, [[ ]] and (( )) are data,
never argv, though each substitution in them is a script. Text this parser cannot read through (an unclosed quote
or substitution, an unbalanced parenthesis, nesting deeper than MAX_DEPTH) raises Unparsed. A mktemp counts only in
command position.

The noclobber lints use it through code(), which drops comments where the shell does, and scan_text(): the text
with only the literal part of each mktemp template word blanked out. A template word is an argument of a command
named mktemp whose own literal text has XXXXXX. Each command substitution inside that word stays in and is walked like
any other script, so a template there exempts only itself; a redirection's target is never a template, wherever it
is. scan_file() reads a shell file or a workflow's run block whole, so a here-document keeps its context. MISSES
holds every review fixture, corpus() the shapes they missed, FILES whole files, and bash_writes() the differential
check: what bash does with a fixture, beside what the tree reads in it.

The source is teamleaderleo/leo-workspace tools/shell_tree.py: change it there, and only there. manaflow-ai/cmux tests/,
manaflow-ai/cmux-platform test/node/ and manaflow-ai/cmuxterm-hq tests/ vendor it byte for byte, each with a
shell_tree.pin beside it naming the leo-workspace commit it was copied from and its SHA-256; each repo's sweep checks
its copy against that pin, and leo-workspace's VendoredCopies test checks each copy against this file at that commit.

Run as a script it reads a JSON list of strings on stdin and prints the list of their scan_text(code(...))
(cmux-platform's TypeScript sweep runs it so); --corpus, --file-corpus, --files, --unparsed, --bash, --no-oracle
and --tree-only print corpus(), FILES, each file's scan_file(), each file's unparsed(), each text's oracle() (true,
false or {"no_oracle": reason}), no_oracle() of the texts and TREE_ONLY as JSON.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

REDIRECTS = ("&>>", "&>", "<<<", "<<-", "<<", "<>", "<&", ">&", ">>", ">|", "<", ">")
WORD_END = " \t\n;&|()<>"
SPECIAL = "\\'\"$`"
SPECIAL_PARAMS = "$?#@*!-0123456789"
# A ${ }'s name, after an optional # (length) or ! (indirection), with its subscript: the operator follows it.
PARAM_HEAD = re.compile(r"[#!]?(?:[A-Za-z_]\w*|\d+|[@*#?$!-])(?:\[[^\]]*\])?")
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=")
MAX_DEPTH = 32  # substitutions and expansions inside one another; deeper text is Unparsed, never a RecursionError
# Reserved words after which a command starts again: a ( there is a subshell, a (( arithmetic, a case or [[ itself.
START_WORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "time", "coproc"}
# Command wrappers: each runs the command after its options, so unwrap() reads through them. Per wrapper: its options
# that take no argument, those that take one (-n 5, -n5, --adjustment=5), its long options whose argument is optional
# (only as --opt=ARG), and how many operands come before the command (timeout's DURATION). A long option may be cut
# to any unique prefix, as getopt reads it. env's NAME=value words are skipped, and its -S string is split into words.
# An option that is in none of these makes unwrap() UNRESOLVED: what runs cannot be told.
WRAPPERS = {
    "time": ({"-p", "-a", "-v", "-q", "--portability", "--append", "--verbose", "--quiet"},
             {"-f", "-o", "--format", "--output"}, set(), 0),
    # GNU env's whole option table (teamleaderleo/leo-workspace#4382 review at cc43afa6, F3).
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


@dataclass
class Script:
    commands: list


class _Parser:
    def __init__(self, s: str, origin: list[int], comments: list, level: list[int]):
        self.s, self.n, self.o = s, len(s), origin  # o[i]: the offset in parse()'s text of s[i]; o[n] the end
        # Shared with the parsers of nested backticks: (start, end) of each comment; [how deep the parse is].
        self.comments, self.level = comments, level

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
        commands, cmd, depth, pending, texts, last_end = [], Command(), 0, [], [], -1

        def end():
            nonlocal cmd
            if cmd.words or cmd.redirects or cmd.data:
                commands.append(cmd)
            cmd = Command()
            texts.clear()

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
                if texts == ["for"] and s.startswith("((", i):  # for (( ; ; )): arithmetic, no argv
                    got, i = self.nested(self.arith, i, 2)
                    cmd.data.append(Word(got.start, got.end, [got]))
                    continue
                if start:
                    end()
                elif len(texts) == 2 and texts[0] == "coproc":
                    cmd.words.clear()  # coproc NAME ( ... ): NAME names the coprocess; the subshell runs
                    end()
                elif texts:  # after a word only a function's () may follow
                    j = i + 1
                    while j < n and s[j] in " \t":
                        j += 1
                    if j >= n or s[j] != ")":
                        raise Unparsed(s)
                    if texts[0] == "function" and len(texts) == 2:
                        cmd.words.clear()  # function NAME (): NAME is a name, never a command
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
            if len(texts) == 2 and texts[0] in ("function", "coproc") and not cmd.redirects and \
                    s[i:j] in ("{", "(") and len(cmd.words) == 2:
                # function NAME { ...; } and coproc NAME { ...; }: NAME is a name, never a command; the compound
                # command after it is read as any other (teamleaderleo/leo-workspace#4382 review, F2).
                cmd.words.clear()
                end()
            texts.append(s[i:j])
            cmd.words.append(w)
            i = last_end = j

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
        return Word(self.o[start], self.o[i], parts), i

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
        inner = _Parser("".join(body), origin, self.comments, self.level)
        script, _ = self.nested(inner.script, 0, None)
        return Sub(self.o[i], self.o[j + 1], "`", script), j + 1


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


def commands(script: Script):
    """Every command in SCRIPT and in every substitution and here-document inside it, at any depth."""
    for cmd in script.commands:
        yield cmd
        words = cmd.words + cmd.data + [r.target for r in cmd.redirects] + [r.body for r in cmd.redirects if r.body]
        for w in words:
            for sub in subs(w.parts):
                yield from commands(sub.script)


def literal(text: str, word: Word) -> str:
    """WORD's literal text: its Lit parts, quotes included, never what an expansion or substitution holds."""
    return "".join(text[p.start:p.end] for p in word.parts if isinstance(p, Lit))


def name(text: str, word: Word) -> str:
    """WORD's value when it is all literal (quotes and escapes removed), else ""."""
    if any(not isinstance(p, Lit) for p in word.parts):
        return ""
    return re.sub(r"[\"'\\]", "", literal(text, word))


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
    time`, /usr/bin/time, `X=1 time`, a quoted "time") is GNU time, with its options (teamleaderleo/leo-workspace#4380
    review at 27a11d16, F2). It takes one -p and one --, each unquoted: `time -p -p cmd` and `time "-p" cmd` run the
    command -p (#4434 review, F1). BARE holds the indexes of ARGV words with no quoting (all of them when None).
    THROUGH gets the name of each wrapper read through, in order. A reserved word this reads nothing through
    (UNMODELED) where a command starts makes it UNRESOLVED."""
    argv, k, assigns = list(argv), 0, "shell"
    origin: list = [(i, None) for i in range(len(argv))]
    first = True  # no NAME=value and no wrapper yet: a bare time here is the reserved word

    def unquoted(j: int) -> bool:  # an ARGV word with no quoting, as it is (no word of an -S string)
        return origin[j][1] is None and (bare is None or origin[j][0] in bare)

    def named(j: int) -> bool:  # an ARGV word NAMES holds, as it is (no word of an -S string)
        return origin[j][1] is None and origin[j][0] in names

    def split_at(at: int, off: int) -> bool:
        """Put the words of argv[at][off:] (an -S string) in its place, after argv[at]; False when env refuses it, or
        when a part of it only a run can tell ("\0": a shell expansion, $prefix) may add words or quotes to what env
        splits (manaflow-ai/cmuxterm-hq#9393 review at 7948495f, F1). env's own ${NAME} is no such part: env puts its
        value in one word."""
        if "\0" in argv[at][off:]:
            return False
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
        if assigns == "shell" and (argv[k] in KEYWORDS or ASSIGNMENT.match(argv[k]) and not named(k)) or \
                assigns == "env" and "=" in argv[k]:
            if argv[k] not in KEYWORDS:
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
                # Its own name: NAMES is the caller's (manaflow-ai/cmuxterm-hq#9393 review at 52412c22, F2).
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
        # bash's time keyword takes NAME=value after it as it does before a command; env reads its own after --, too.
        # exec's NAME=value is the command's name (manaflow-ai/cmuxterm-hq#9393 review at 52412c22, F1).
        assigns = "shell" if base == "time" else "env" if base == "env" else None
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
    value whose name has "\0" in it is NAME=value with a name only a run can tell (env $'X'=1)."""
    words: list | None
    values: list
    assigned: list
    unknown: list = field(default_factory=list)


def _value(text: str, word: Word) -> tuple[str, list[tuple[int, int]]]:
    """WORD's value with its quotes removed, "\0" for each part only a run can tell (an expansion, a substitution, an
    ANSI-C $'...'), and per character the (start, end) range of TEXT it comes from."""
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
                e = k + 2
                while e < p.end and text[e] != "'":
                    e += 2 if text[e] == "\\" else 1
                out.append("\0")
                spans.append((k, min(e + 1, p.end)))
                k = e + 1
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
    included, each a Word at the characters it sits on (teamleaderleo/leo-workspace#4368 review at cfd7897e, F3)."""
    words, values = cmd.words, [_value(text, w) for w in cmd.words]
    argv = [value for value, _ in values]
    # A quoted "X"=1 is a command's name (or an -S string), never an assignment, whatever its value.
    names = frozenset(i for i, w in enumerate(words) if not ASSIGNMENT.match(text, w.start))
    bare = frozenset(i for i, w in enumerate(words) if text[w.start:w.end] == argv[i])
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
        return Resolved(run, [], got)
    found = [at(i, spans) for i, spans in where]
    unknown = []
    # A declaration builtin is bash's only in bash's own command position, or after command or builtin; after env,
    # nice or any other program it is a program named export (#4419 review, F1).
    if run[0] in DECLARES and all(b in ("command", "builtin") for b in through):
        for word, value in zip(found[1:], run[1:]):
            if value.startswith(("-", "+")) and "=" not in value:
                continue  # an option: export -n, declare -x, declare +x
            if "=" in value:
                got.append((word, value))
            elif "\0" in value:
                unknown.append(word)
    return Resolved(found, run, got, unknown)


def runs(text: str) -> str | None:
    """The name of the command TEXT's first command runs (resolve()): None when it runs nothing, "?" when that
    cannot be told."""
    run = resolve(text, next(commands(parse(text))))
    return "?" if run.words is UNRESOLVED else run.values[0] if run.words else None


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


def template_words(text: str, cmd: Command) -> list[Word]:
    """CMD's mktemp template words: an argument of a command named mktemp (after its wrappers, resolve()) whose own
    literal text has XXXXXX; inside an env -S string, the characters of the word env makes."""
    run = resolve(text, cmd)
    if not run.words or run.values[0].rsplit("/", 1)[-1] != "mktemp":
        return []
    return [w for w in run.words[1:] if "XXXXXX" in literal(text, w)]


def exempt(text: str) -> set[int]:
    """The offsets of TEXT a noclobber scan leaves out: each mktemp template word, less every substitution in it.
    None when TEXT does not parse."""
    if "mktemp" not in text:
        return set()
    try:
        tree = parse(text)
    except Unparsed:
        return set()
    return tree_exempt(text, tree)


def tree_exempt(text: str, tree: Script) -> set[int]:
    """exempt() of TEXT, already parsed into TREE."""
    out: set[int] = set()
    for cmd in commands(tree):
        for w in template_words(text, cmd):
            span = set(range(w.start, w.end))
            for sub in subs(w.parts):
                span -= set(range(sub.start, sub.end))
            out |= span
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


def scan_file(path: str, text: str) -> list[str]:
    """Each line of TEXT (split at \\n) as a noclobber scan reads it: comments dropped and template words blanked.
    A shell file (by suffix or #!), and each `run: |` block of a YAML file, is parsed whole, so a here-document, a
    line continuation or a quote across lines is read in its context: a here-document's # is no comment, and its
    substitutions run. Any other text is read line by line. A shell block that does not parse whole keeps its raw
    text, every # and template included, never a line-by-line guess (manaflow-ai/cmux-platform#1271 review at
    cd22cde4, F2): unparsed() names it, and a sweep reports it as unresolved. A #! line that shebang() cannot
    resolve is read as shell, and a sweep reports it besides."""
    lines = text.split("\n")
    out: list = [None] * len(lines)
    for a, b in shell_blocks(path, text):
        got = scan_block(lines[a:b])
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


def run_blocks(lines: list[str]) -> list[tuple[int, int]]:
    """The (first, end) line ranges of each `run: |` block scalar in a YAML file's LINES."""
    out, k = [], 0
    while k < len(lines):
        m = RUN_BLOCK.match(lines[k])
        k += 1
        if not m:
            continue
        base, j = len(m.group(1)), k
        while j < len(lines) and (not lines[j].strip() or len(lines[j]) - len(lines[j].lstrip(" ")) > base):
            j += 1
        out.append((k, j))
        k = j
    return out


def scan_block(lines: list[str]) -> list[str] | None:
    """LINES read as one script (their common indent removed): each line's scan text; None when it does not parse."""
    indent = min((len(line) - len(line.lstrip(" ")) for line in lines if line.strip()), default=0)
    text = "\n".join(line[indent:] for line in lines)
    found: list = []
    try:
        tree = parse(text, found)
    except Unparsed:
        return None
    skip = tree_exempt(text, tree) if "mktemp" in text else set()
    for a, b in found:
        skip.update(range(a, b))
    blanked = "".join(" " if k in skip and c != "\n" else c for k, c in enumerate(text))
    return [" " * indent + line if line else line for line in blanked.split("\n")]


# The review fixtures of the misses, each a line a lint must flag.
MISSES = (
    # 1. The whole line was exempt when it had XXXXXX (manaflow-ai/cmux-platform#1262, F2).
    'd=$(mktemp -d ".../safe.XXXXXX"); printf secret > /tmp/out.$$',
    # 2. A regex took a redirection's target for mktemp's argument (manaflow-ai/cmux-platform#1265, F1).
    "d=$(mktemp -d) > /tmp/out.$$.XXXXXX",
    # 3. Token masking. An inner template's span shifted the outer one's (manaflow-ai/cmux#41306 F1,
    #    teamleaderleo/leo-workspace#4346 F1); a whole template word exempted a substitution inside it (cmux#41306 F2);
    #    XXXXXX only inside a substitution made the word a template, masked whole (manaflow-ai/cmuxterm-hq#9338).
    'mktemp "$(mktemp /tmp/$USER.XXXXXX).XXXXXX"; echo > /tmp/out.$$',
    'mktemp "$(mktemp /tmp/a.XXXXXX).XXXXXX" > /tmp/out.$$',
    'mktemp "/tmp/$(printf secret > /tmp/out.$$)x.XXXXXX"',
    'mktemp "$(printf /tmp/a.XXXXXX)$(printf secret > /tmp/out.$$)"',
    # The outer word holds a template only inside its substitution, so it is no template; the write is on the outer
    # mktemp (manaflow-ai/cmux#41306, block at 1f84d085).
    'mktemp "$(mktemp /tmp/a.XXXXXX)" > /tmp/out.$$',
    # 4. A comment was cut at any whitespace-led #, quoted or not (teamleaderleo/leo-workspace#4346, F2).
    "printf '%s' 'foo # bar' > /tmp/out.$$",
    # 5. The parse tree's own misses (manaflow-ai/cmux#41306 review at 7e60a832, F1: an array's words read as a
    #    command; manaflow-ai/cmuxterm-hq#9338 review at 0ea8b97f, F1: a process substitution in ${ } read as text).
    #    F2 there, a here-document read line by line, is in FILES.
    "paths=(mktemp ';' /tmp/out.$$.XXXXXX); printf secret > \"${paths[2]}\"",
    "mktemp ${TMPDIR:-<(printf secret > /tmp/out.$$)}/x.XXXXXX",
    # 6. The parser kept quoting state bash does not (teamleaderleo/leo-workspace#4368 review at 3aa1ae3e, F1): in a
    #    double-quoted ${ }, single quotes are literal, so the $( ) in them runs. F2 there, a here-document's
    #    continued line, is in FILES.
    "mktemp \"/tmp/${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX\"",
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


# A case pattern's ) inside a substitution never closes it (security review of manaflow-ai/cmuxterm-hq#9338 at
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
    ("mktemp \"/tmp/${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX\"", True),
    ("mktemp \"/tmp/${a:-${b:-'$(printf secret > /tmp/out.$$)'}}.XXXXXX\"", True),
    ("x=\"${y:-'`printf secret > /tmp/out.$$`'}\"", True),
    ("x=\"${y:-'<(printf secret > /tmp/out.$$)'}\"", True),
    ("mktemp /tmp/${x:-'$(printf secret > /tmp/out.$$)'}.XXXXXX", False),
    ("x=${y:-'$(printf secret > /tmp/out.$$)'}", True),
    ("cat <<EOF\n${x:-'$(printf secret > /tmp/out.$$)'}\nEOF", True),
    ("cat <<'EOF'\n${x:-'$(printf secret > /tmp/out.$$)'}\nEOF", True),
    ("mktemp \"/tmp/${x:-'$USER'}.XXXXXX\"", False),
    # manaflow-ai/cmuxterm-hq#9393 review at c6948ffc, F2: in double quotes, the single quotes of a pattern (#, ##, %,
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


# A mktemp behind a command wrapper and its options is still mktemp (teamleaderleo/leo-workspace#4368 review at
# 3aa1ae3e, wrapper F1): its template is safe, and a write beside it is not. Where a wrapper's option takes the word
# "mktemp" as its argument, the command is the next word, and an option the unwrapping does not know exempts nothing.
WRAPPERS_SAFE = ("time -p", "env", "env -i", "env -i PATH=/usr/bin:/bin", "env -u HOME", "env -uHOME",
                 "env --unset=HOME", "env -C /", "env --chdir=/", "env --", "env X=1 Y=2", "/usr/bin/env -i",
                 "nice", "nice -n 5", "nice -n5", "nice -5", "nice --adjustment=5", "nohup", "command", "command -p",
                 "exec", "exec -a name", "exec -c", "exec -cl", "timeout 5", "timeout -s KILL 5",
                 "timeout --kill-after=1 5", "timeout --preserve-status 5s", "stdbuf -oL", "stdbuf -o L",
                 "stdbuf --output=L -eL", "setsid", "setsid -f", "time -p env -i nice -n 1 timeout 5",
                 # teamleaderleo/leo-workspace#4382 review at cc43afa6, F3: GNU env's whole option table.
                 "env --default-signal=PIPE", "env --default-signal", "env --ignore-signal=INT", "env --block-signal",
                 "env -a name", "env -aname", "env --argv0=name", "env --list-signal-handling", "env -v", "env -0i",
                 "timeout -v 5", "timeout --signal=KILL 5", "timeout --foreground -k 1 5",
                 # env reads its NAME=value words after quote removal (ASSIGNMENT_WORDS; teamleaderleo/leo-workspace#4382
                 # review at 311cf8e9, F1).
                 'env -i "X"=1', 'env X_"Y"=1', "env X\\_Y=1", "env $'X'=1", 'env -- "X"=1', 'env "$V"=1')
WRAPPERS_UNSAFE = ("env -u mktemp", "env -C mktemp", "timeout mktemp", "nice -n mktemp", "exec -a mktemp",
                   "command -v mktemp", "env --bogus mktemp", "stdbuf -o mktemp", "timeout -s mktemp 5",
                   "env -a mktemp", "nice --bogus mktemp", "timeout --bogus 5 mktemp",
                   "setsid --bogus mktemp", "time --bogus mktemp", "exec -z mktemp",
                   # NAME=value where bash runs it as the command's name (ASSIGNMENT_WORDS): after exec
                   # (manaflow-ai/cmuxterm-hq#9393 review at 52412c22, F1), after a long option (F2), and quoted before
                   # the command (teamleaderleo/leo-workspace#4382 review at 311cf8e9, F1). And env "$V", which may be
                   # NAME=value or the command.
                   "exec X=1 mktemp", 'time --portability "X"=1 mktemp', '"X"=1 mktemp', 'X_"Y"=1 mktemp',
                   "X\\_Y=1 mktemp", "$'X'=1 mktemp", 'env "$V" mktemp')
# A command inside env's -S string (teamleaderleo/leo-workspace#4368 review at cfd7897e, F3): env splits it into words
# as it splits any -S string, ${NAME} expanded; a $ without braces, or a $( ), makes env refuse it. The template words
# inside it are exempt where they sit in the -S argument, and nothing else is.
ENV_SPLIT = (
    # manaflow-ai/cmuxterm-hq#9393 review at 7948495f, F1: a shell expansion inside the -S string ($USER, $prefix) may
    # add words and quotes to what env splits, so the command is unresolved and no template is exempt (each row
    # here with one is True; so is an -S string inside one, whose ${NAME} the outer env fills before the inner one
    # splits it). env's own ${NAME} is one word: 'mktemp /tmp/${USER}.XXXXXX' stays exempt.
    ("prefix='/bin/sh -c \"'; suffix='\"'; env -S \"${prefix}/mktemp > /tmp/out.$$.XXXXXX${suffix}\"", True),
    ('env -S "mktemp /tmp/$USER.XXXXXX"', True),
    ("env -S 'mktemp /tmp/${USER}.XXXXXX'", False),
    ("env -S'mktemp /tmp/${USER}.XXXXXX'", False),
    ('env -iS"mktemp -d /tmp/$USER.XXXXXX"', True),
    ('env --split-string="mktemp /tmp/$USER.XXXXXX"', True),
    ('d=$(env -S "mktemp -d /tmp/$USER.XXXXXX")', True),
    ('env -S "nice -n 5 mktemp /tmp/$USER.XXXXXX"', True),
    ("env -S 'env -S \"mktemp /tmp/${USER}.XXXXXX\"'", True),
    ('env -S "mktemp /tmp/$USER.XXXXXX" > /tmp/out.$$', True),
    ('env -S "mktemp /tmp/$USER.XXXXXX /tmp/out.$$"', True),
    ("env -S 'mktemp /tmp/$USER.XXXXXX'", True),
    ("env -S 'mktemp \"/tmp/$(id -u).XXXXXX\"'", True),
    ('env -S "printf s > /tmp/out.$$"', True),
    ('env -S "mktemp" /tmp/$USER.XXXXXX', False),
    # teamleaderleo/leo-workspace#4368 review at cfd7897e, F4: env -i and command -p find mktemp on the default PATH,
    # past the fake one; bash_writes() runs the fake by its own path, so nothing reaches the real temp folder.
    ("d=$(env -i mktemp -d)", False),
    ("env -i mktemp", False),
    ("command -p mktemp -d", False),
    # manaflow-ai/cmuxterm-hq#9393 review at 52412c22, F4: mktemp by its path runs the fake too.
    ("/usr/bin/mktemp", False),
    ("d=$(env -i /usr/bin/mktemp -d)", False),
    # manaflow-ai/cmux-platform#1274 review, F1: a shell inside a shell runs, so bash checks it too.
    ("env -S \"bash -c 'printf x > /tmp/out.$$'\"", True),
    ("sh -c 'printf x > /tmp/out.$$'", True),
    # teamleaderleo/leo-workspace#4380 review at 27a11d16, F2: bash's time runs -f, so the path is mktemp's argument
    # nowhere, and no template; GNU time runs mktemp.
    ("time -f F mktemp /tmp/$USER.XXXXXX", True),
    ("time -o out mktemp -d /tmp/$USER.XXXXXX", True),
    ("command time -f F mktemp /tmp/$USER.XXXXXX", False),
    ("/usr/bin/time -f F mktemp /tmp/$USER.XXXXXX", False),
)

# Where a NAME=value word sets NAME, as bash reads it: (text, the names it sets, "?" for one whose name only a run can
# tell). Each row is what bash did with it (teamleaderleo/leo-workspace#4382 review at 311cf8e9, F1), and the
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
    ("env $'X'=0 cmd", ["?"]),
    ('env -u HOME -- "X_T"=0 cmd', ["X_T"]),
    ('export "X_TIMEOUT"=0; cmd', ["X_TIMEOUT"]),
    ('export X_"TIMEOUT"=0; cmd', ["X_TIMEOUT"]),
    ('export "X"_Y=0; cmd', ["X_Y"]),
    ("export X\\_Y=0; cmd", ["X_Y"]),
    ("export $'X'=0; cmd", ["?"]),
    ('declare -x "X_T"=0; cmd', ["X_T"]),
    ('f() { local -x "X_T"=0; cmd; }; f', ["X_T"]),
    ('readonly "X_T"=0; export X_T; cmd', ["X_T"]),
    ("exec X_T=0 cmd", []),
    ("time -p X_T=0 cmd", ["X_T"]),
    # teamleaderleo/leo-workspace#4380 review at 27a11d16, F3: after exec's options too, NAME=value is the command.
    ("exec -a name X_T=0 cmd", []),
    ("exec -c X_T=0 cmd", []),
    ("exec -l X_T=0 cmd", []),
    ("exec -cl -a name X_T=0 cmd", []),
    # manaflow-ai/cmuxterm-hq#9375 review, F1: exec -a name X_TIMEOUT=0 cmd runs a command named X_TIMEOUT=0.
    ("exec -a name X_TIMEOUT=0 cmd", []),
    # manaflow-ai/cmuxterm-hq#9370 review at 4b4f59b6, F1: env's NAME=value words after its options.
    ('env -i PATH="$PATH" X_T=0 cmd', ["PATH", "X_T"]),
    ("env -- X_T=0 cmd", ["X_T"]),
    ("env -u HOME X_T=0 cmd", ["X_T"]),
    ("env -C / X_T=0 cmd", ["X_T"]),
    ("env -S 'X_T=0 cmd'", ["X_T"]),
    # manaflow-ai/cmuxterm-hq#9375 review, F2: -S's string attached to its option, short and long.
    ("env -SX_T=0 cmd", ["X_T"]),
    ("env -S'X_T=0 cmd'", ["X_T"]),
    ("env --split-string=X_T=0 cmd", ["X_T"]),
    ("env --split-string='X_T=0 cmd'", ["X_T"]),
    ("time X_T=0 cmd", ["X_T"]),
    ("command time -p env X_T=0 cmd", ["X_T"]),
    # teamleaderleo/leo-workspace#4382 review, F1: a declaration's word after quote removal and escapes.
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
    # #4419 review, F1: export is a declaration only where bash runs it; after env or nice it is a program.
    ("env -S 'export X_T=0'; cmd", []),
    ("env export X_T=0; cmd", []),
    ("nice export X_T=0; cmd", []),
    ("command export X_T=0; cmd", ["X_T"]),
    ("builtin export X_T=0; cmd", ["X_T"]),
    # #4419 review, F2: a quoted name after a word only a run can tell; env "$V" may be NAME=value or the command.
    ('V=--; env "$V" X_"T"=0 cmd', ["V", "?"]),
)

# The command each text runs, as bash runs it (teamleaderleo/leo-workspace#4380 review at 27a11d16, F2): bash's
# reserved word time takes -p and nothing else, so `time -f F cmd` runs a command named -f; only GNU time (command
# time, /usr/bin/time, a time after NAME=value, a quoted "time") takes -f and -o. And exec's NAME=value is the command
# (F3). The sweep runs bash on each row: `cmd` prints that it ran, and any other name is not found.
RUN_WORDS = (
    ("time cmd", "cmd"),
    # manaflow-ai/cmuxterm-hq#9375 review: what exec -a and an attached env -S run.
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
    # #4434 review, F1: bash's time takes one unquoted -p and one unquoted --; the next word is the command.
    ("time -p -p cmd", "-p"),
    ('time "-p" cmd', "-p"),
    ("time '-p' cmd", "-p"),
    ("time \\-p cmd", "-p"),
    ('time -p "--" cmd', "--"),
    ('time "--" cmd', "--"),
    ("time -- -- cmd", "--"),
    ("time -- -p cmd", "-p"),
    ("time -p -- -p cmd", "-p"),
    # teamleaderleo/leo-workspace#4382 review, F1: before a command, a quoted or escaped = makes no assignment.
    ('"X_T=0" cmd', "X_T=0"),
    ("X_T\\=0 cmd", "X_T=0"),
)


def _wrappers() -> list[tuple[str, bool]]:
    out = []
    for w in WRAPPERS_SAFE:
        out += [(w + " mktemp /tmp/$USER.XXXXXX", False), ("d=$(" + w + " mktemp -d /tmp/$USER.XXXXXX)", False),
                (w + " mktemp /tmp/$USER.XXXXXX > /tmp/out.$$", True)]
    out += [(w + " /tmp/out.$$.XXXXXX", True) for w in WRAPPERS_UNSAFE]
    return out


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
    for line in MISSES:
        out[line] = True
    return sorted(out.items())


# Whole files (path, text, whether a line in it must be flagged), which a sweep reads through scan_file(): the
# here-document, continuation and multi-line quote cases a line-by-line read gets wrong. A sweep's test writes each
# into a scanned folder of a scratch repository and runs its hits() there.
FILES = (
    # manaflow-ai/cmuxterm-hq#9338 review at 0ea8b97f, F2: line by line, this body line reads as a comment.
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
    # teamleaderleo/leo-workspace#4368 review at 3aa1ae3e, F2: in an unquoted here-document, abc\ and EOF join into
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
    # manaflow-ai/cmux#41336 review at c1c62c86, F2: env -S splits its string as env does, quotes included, so
    # 'bash' is bash; a string it cannot split (an open quote, a $ it would expand) leaves the #! line unresolved.
    ("scripts/env-split-quoted", "#!/usr/bin/env -S 'bash' -e\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n", True),
    ("scripts/env-split-dquoted", '#!/usr/bin/env -S "bash" -e\ncat <<EOF\n# $(printf s > /tmp/out.$$)\nEOF\n', True),
    ("scripts/env-split-open-quote", "#!/usr/bin/env -S 'bash -e\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n", True),
    ("scripts/env-split-expands", "#!/usr/bin/env -S ${SHELL} -e\nd=$(mktemp -d /tmp/$USER.XXXXXX)\n", True),
    ("scripts/env-split-python", "#!/usr/bin/env -S 'python3' -u\nimport os\n", False),
    ("scripts/shebang-python", "#!/usr/bin/env python3\nimport os\n", False),
    # manaflow-ai/cmux-platform#1271 review at cd22cde4, F2: this parser does not read extglob, so the file does not
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
# mktemp by its name or by any path (/usr/bin/mktemp: manaflow-ai/cmuxterm-hq#9393 review at 52412c22, F4).
MKTEMP_WORD = re.compile(r"(?<![\w./-])(?:(?:/[\w.-]+)*/)?mktemp(?![\w.-])")
TMP_PATH = re.compile(r"(?<![\w.])(?:/private)?/tmp(?![\w.-])")
MKTEMP = """#!/bin/sh
out=$(TMPDIR=%s %s "$@") || exit $?
printf '%%s\\n' "$out" >> %s
printf '%%s\\n' "$out"
if [ -n "$SHELL_TREE_PEAK" ] && read -r me < /proc/$$/stat; then
  me=${me##*) }; set -- $me; session=$4; n=0
  for f in /proc/[0-9]*/stat; do
    read -r line < "$f" 2>/dev/null || continue
    line=${line##*) }; set -- $line
    [ "$4" = "$session" ] && n=$((n + 1))
  done
  printf '%%s\\n' "$n" >> "$SHELL_TREE_PEAK"
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
# until none is left. Past argv[1] seconds it kills every process below it, and exits 124. Elsewhere it kills bash's
# process group and what /proc or ps shows below it.
REAPER = r"""
import ctypes, os, signal, subprocess, sys, time
deadline = time.monotonic() + float(sys.argv[1])
try:
    ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
except (AttributeError, OSError):
    pass
signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGCHLD])
bash = subprocess.Popen(sys.argv[3:], start_new_session=True)
with open(sys.argv[2], "w") as f:
    f.write(str(bash.pid))


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


while reap(False):
    left = deadline - time.monotonic()
    if left <= 0:
        try:
            os.killpg(bash.pid, signal.SIGKILL)
        except OSError:
            pass
        while True:
            for pid in below():
                try:
                    os.kill(pid, signal.SIGKILL)
                except OSError:
                    pass
            if not reap(True):
                os._exit(124)
    signal.sigtimedwait([signal.SIGCHLD], min(left, 0.05))
os._exit(0)
"""
# How long past its own deadline the reaper may take to stop before its own group is killed.
REAPER_GRACE = 5


class BashTimeout(RuntimeError):
    """A bash run past its time; its process group (PGID) is killed, and the message names the fixture."""

    def __init__(self, text: str, timeout: float, pgid: int):
        super().__init__(f"bash ran past {timeout:g} s on this fixture, and its process group {pgid} was killed: "
                         f"{text}")
        self.pgid = pgid


def bash_processes(text: str) -> int:
    """An upper bound on the processes bash holds at once running TEXT with no loop that forks in the background:
    bash and the fake mktemp with its substitution, and one per (, backtick pair, | and &."""
    return 4 + text.count("(") + text.count("`") // 2 + text.count("|") + text.count("&")


def bash_writes(text: str, timeout: float = 10, stats: dict | None = None) -> bool | None:
    """Whether bash, running TEXT in a scratch folder (each /tmp in it moved there; PATH a folder of its own, whose
    mktemp makes its names there and logs them; TMPDIR the scratch temp folder), creates a file or folder
    no mktemp made; None when bash -n refuses TEXT or it would hold more than MAX_BASH_PROCESSES at once. Bash reads
    no stdin (it is /dev/null). TMPDIR is the scratch temp folder, the script's own included, so a mktemp that is not
    the fake makes its name there and "$TMPDIR/x" is a scratch path, never / (manaflow-ai/cmux-platform#1286 review,
    F1); a ${TMPDIR:-...} default does not run. Bash runs under REAPER,
    which waits for every process the run leaves; past TIMEOUT it kills each one, a setsid one included
    (manaflow-ai/cmuxterm-hq#9393 review at 52412c22, F3), and BashTimeout names TEXT. STATS, when given, gets "runs"
    (0 or 1) and "peak": the most processes bash's session held when a mktemp ran (on Linux)."""
    if stats is not None:
        stats.update(runs=0, peak=0)
    if bash_processes(text) > MAX_BASH_PROCESSES:
        return None
    bash = shutil.which("bash")
    try:
        if subprocess.run([bash, "-O", "extglob", "-n"], input=text, text=True, capture_output=True,
                          timeout=timeout).returncode:
            return None
    except subprocess.TimeoutExpired:
        raise BashTimeout(text, timeout, 0) from None
    root = tempfile.mkdtemp(prefix="shell-tree-")
    try:
        tmp, bindir, work = (os.path.join(root, d) for d in ("t", "bin", "work"))
        for d in (tmp, bindir, work):
            os.mkdir(d)
        log = os.path.join(root, "made")
        with open(os.path.join(bindir, "mktemp"), "w") as f:
            f.write(MKTEMP % (tmp, shutil.which("mktemp"), log))
        os.chmod(os.path.join(bindir, "mktemp"), 0o700)
        # bash and sh too, so a fixture that runs a shell inside a shell runs (manaflow-ai/cmux-platform#1274 review,
        # F1): env -S "bash -c '...'" failed before it ran, so the differential check never saw it.
        for tool in ("cat", "cp", "mkdir", "touch", "tee", "env", "nice", "nohup", "timeout", "stdbuf", "setsid",
                     "bash", "sh"):
            # A host without one (macOS has no setsid, timeout or stdbuf) runs a fixture that calls it as bash does
            # there: command not found (manaflow-ai/cmuxterm-hq#9393 review at 7948495f, F2).
            if shutil.which(tool):
                os.symlink(shutil.which(tool), os.path.join(bindir, tool))
        open(os.path.join(work, "a"), "w").close()
        # Each mktemp is the fake by its own path, so env -i and command -p (the default PATH) never reach the real
        # one, which would make its name in the real temp folder (teamleaderleo/leo-workspace#4368 at cfd7897e, F4).
        script = MKTEMP_WORD.sub(os.path.join(bindir, "mktemp"), TMP_PATH.sub(tmp, text))
        if TMP_PATH.search(script.replace(root, "")) or "umask" in script:
            raise ValueError("a /tmp path or a umask is left in the script: " + script)
        with open(os.path.join(root, "script"), "w") as f:
            f.write(script)
        env = {"PATH": bindir, "HOME": root, "USER": "u", "LC_ALL": "C", "TMPDIR": tmp}
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
            os.killpg(run.pid, signal.SIGKILL)
            run.wait()
            code = 124
        if code == 124:
            with open(pidfile) as f:
                raise BashTimeout(text, timeout, int(f.read() or 0)) from None
        if stats is not None and os.path.exists(peak_log):
            with open(peak_log) as f:
                stats["peak"] = max((int(n) for n in f.read().split()), default=0)
        # A name is mktemp's when the fake logged it, or when its mode is the 0600 file or 0700 folder mktemp makes:
        # under env -i, the real mktemp runs from the default PATH. Under umask 022 nothing else makes those modes.
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
                if mode == (0o700 if entry in dirs else 0o600) and "XXXXXX" not in entry:
                    continue
                return True
        return False
    finally:
        shutil.rmtree(root, ignore_errors=True)


# The bash oracle's budget for one row: its wall time (ORACLE_SECONDS) and the processes it may hold at once
# (MAX_BASH_PROCESSES). Its answer is True or False, or NoOracle naming why there is none; never an exception.
ORACLE_SECONDS = 10


@dataclass(frozen=True)
class NoOracle:
    """Bash gave no answer for a row, and why: bash -n refuses it, it needs more than MAX_BASH_PROCESSES at once, or
    it ran past its time. Falsy, so it is never read as "bash wrote". A differential check fails on it unless the row
    is in TREE_ONLY (no_oracle())."""
    reason: str

    def __bool__(self) -> bool:
        return False


# The rows bash is never asked about, each with its reason; every other row must get an oracle answer. A depth
# fixture past MAX_BASH_PROCESSES has a bash-sized twin (BASH_TWIN_DEPTH) in the corpus.
TREE_ONLY = {
    _deep(200): "200 nested substitutions hold 200 processes at once, past MAX_BASH_PROCESSES; near a host's limit "
                "bash's fork backs off past any time budget (cmux#41336 review). Its twin is _deep(BASH_TWIN_DEPTH)",
    **{line: "not shell: bash -n refuses it, and the tree must refuse it too (UNPARSED)" for line in NOT_SHELL},
}


def oracle(text: str, timeout: float = ORACLE_SECONDS) -> bool | NoOracle:
    """bash_writes(TEXT) within the row's budget: True or False, or NoOracle with the reason it has no answer."""
    need = bash_processes(text)
    if need > MAX_BASH_PROCESSES:
        return NoOracle(f"needs {need} processes at once, past MAX_BASH_PROCESSES ({MAX_BASH_PROCESSES})")
    try:
        wrote = bash_writes(text, timeout=timeout)
    except BashTimeout:
        return NoOracle(f"bash ran past its {timeout:g} s budget (ORACLE_SECONDS)")
    return NoOracle("bash -n refuses it") if wrote is None else wrote


def no_oracle(texts: list[str], verdicts: list[bool | NoOracle]) -> list[str]:
    """Each of TEXTS whose verdict is NoOracle and which TREE_ONLY does not list, with why: a differential row with no
    oracle answer is a failure, never a skip."""
    return [f"{text[:120]!r}: no answer from bash ({v.reason}). Make it fit the budget, or list it in TREE_ONLY "
            "with its reason and add a bash-sized twin" for text, v in zip(texts, verdicts)
            if isinstance(v, NoOracle) and text not in TREE_ONLY]


def bash_verdicts(texts: list[str], timeout: float = ORACLE_SECONDS) -> list[bool | NoOracle]:
    """oracle() of each of TEXTS, several bash runs at a time, with the processes they may hold together
    (bash_processes) kept under PROCESS_BUDGET."""
    room = threading.Condition()
    free = [PROCESS_BUDGET]

    def one(text: str) -> bool | NoOracle:
        cost = min(bash_processes(text), MAX_BASH_PROCESSES)
        with room:
            room.wait_for(lambda: free[0] >= cost)
            free[0] -= cost
        try:
            return oracle(text, timeout)
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
