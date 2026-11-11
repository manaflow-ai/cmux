"""A small shell parser for lints: shell text becomes a tree of commands, so a lint asks what a word is, never what
text sits near it.

parse(text) returns a Script: its Commands, each with argv Words and Redirects (a here-document's body included).
A Word is a list of parts: Lit (literal text, quoted or not), Param ($x, ${x...}), Arith ($(( ))) and Sub (a
command substitution, $( ) or backticks, or a process substitution <( ) or >( )), whose script is parsed the same
way, to any depth. Every node keeps its start and end offset in the text parse() was given, backticks inside
backticks included. Text this parser cannot read through (an unclosed quote or substitution, an unbalanced
parenthesis, nesting deeper than MAX_DEPTH) raises Unparsed, and so does a shape it does not model as commands:
an array (NAME=( ), declare -a), case, an arithmetic command (( )). A mktemp counts only in command position.

The noclobber lints use it through code(), which drops comments where the shell does, and scan_text(): the text
with only the literal part of each mktemp template word blanked out. A template word is an argument of a command
named mktemp whose own literal text has XXXXXX. Each command substitution inside that word stays in and is walked like
any other script, so a template there exempts only itself; a redirection's target is never a template, wherever it
is. Three exemptions before this one each let a guessable name through, and so did a comment cut at any #; MISSES
holds their review fixtures, and corpus() the shapes they missed, generated across nesting depth, substitution form,
quoting and where the unsafe write sits.

This file is the same, byte for byte, in manaflow-ai/cmux tests/, manaflow-ai/cmux-platform test/node/,
manaflow-ai/cmuxterm-hq tests/ and teamleaderleo/leo-workspace tools/; each repo's noclobber sweep pins its SHA-256.
Change it in all four at once. Run as a script it reads a JSON list of strings on stdin and prints the list of their
scan_text(code(...)) (cmux-platform's TypeScript sweep runs it so); with --corpus it prints corpus() as JSON.
"""
from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field

REDIRECTS = ("&>>", "&>", "<<<", "<<-", "<<", "<>", "<&", ">&", ">>", ">|", "<", ">")
WORD_END = " \t\n;&|()<>"
SPECIAL = "\\'\"$`"
SPECIAL_PARAMS = "$?#@*!-0123456789"
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*(?:\[[^\]]*\])?\+?=")
MAX_DEPTH = 32  # substitutions and expansions inside one another; deeper text is Unparsed, never a RecursionError
# Reserved words after which a command starts again: a ( there is a subshell, a (( arithmetic, a case or [[ itself.
START_WORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "time"}
# Words before a command's name that are not its name.
PREFIX_WORDS = {"!", "{", "}", "if", "then", "else", "elif", "do", "while", "until", "time", "command", "env", "exec"}


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
                elif texts:  # after a word only a function's () may follow
                    j = i + 1
                    while j < n and s[j] in " \t":
                        j += 1
                    if j >= n or s[j] != ")":
                        raise Unparsed(s)
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
            start = i
            while i < n:
                e = s.find("\n", i)
                e = n if e < 0 else e
                line = s[i:e]
                if (line.lstrip("\t") if r.op == "<<-" else line) == delim:
                    body_end, i = i, min(e + 1, n)
                    break
                i = min(e + 1, n)
            else:
                body_end = n  # unterminated: the text ends inside the body
            if re.search(r"[\"'\\]", raw):
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
            elif c in "$`":
                got, i = self.dollar(i) if c == "$" else self.backtick(i)
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

    def dollar(self, i: int):
        if self.s.startswith(("$(", "${"), i):
            return self.nested(self.expansion, i)
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

    def expansion(self, i: int):
        s, n = self.s, self.n
        if s.startswith("$((", i):
            return self.arith(i, 3)
        if s.startswith("$(", i):
            script, j = self.script(i + 2, ")")
            return Sub(self.o[i], self.o[j], "$(", script), j
        if s.startswith("${", i):
            parts, j = [], i + 2
            while j < n and s[j] != "}":
                got, j = self.piece(j, "}")
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


def template_words(text: str, cmd: Command) -> list[Word]:
    """CMD's mktemp template words: an argument of a command named mktemp whose literal text has XXXXXX."""
    words, k = cmd.words, 0
    while k < len(words) and (name(text, words[k]) in PREFIX_WORDS or
                              (ASSIGNMENT.match(text, words[k].start) or (None,))[0] is not None):
        k += 1
    if k >= len(words) or name(text, words[k]).rsplit("/", 1)[-1] != "mktemp":
        return []
    return [w for w in words[k + 1:] if "XXXXXX" in literal(text, w)]


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
SHEBANG = re.compile(r"#!\s*\S*(?:/|env\s+)(?:ba|z|k|da)?sh\b")
RUN_BLOCK = re.compile(r"(\s*)(?:-\s+)?run:\s*\|[-+0-9]*\s*(?:#.*)?$")


def scan_file(path: str, text: str) -> list[str]:
    """Each line of TEXT (split at \\n) as a noclobber scan reads it: comments dropped and template words blanked.
    A shell file (by suffix or #!), and each `run: |` block of a YAML file, is parsed whole, so a here-document, a
    line continuation or a quote across lines is read in its context: a here-document's # is no comment, and its
    substitutions run. Any other text, and a script that does not parse whole, is read line by line."""
    lines = text.split("\n")
    if path.endswith(SHELL_SUFFIXES) or SHEBANG.match(text):
        blocks = [(0, len(lines))]
    elif path.endswith((".yml", ".yaml")):
        blocks = run_blocks(lines)
    else:
        blocks = []
    out: list = [None] * len(lines)
    for a, b in blocks:
        got = scan_block(lines[a:b])
        if got is not None:
            out[a:b] = got
    return [scan_text(code(line)) if got is None else got for line, got in zip(lines, out)]


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


# Text the parser must refuse, so it exempts nothing and its name is flagged: not shell bash reads (NOT_SHELL), or
# nested past MAX_DEPTH. (MAX_DEPTH levels of the same parse, and stay safe.)
NOT_SHELL = ("mktemp /tmp/a.$$.XXXXXX)", "(mktemp /tmp/a.$$.XXXXXX", 'mktemp "/tmp/a.$$.XXXXXX',
             "d=$(mktemp /tmp/a.$$.XXXXXX", "mktemp /tmp/a.$$.XXXXXX))")


def _deep(levels: int, write: str = "") -> str:
    line = "mktemp /tmp/$USER.XXXXXX" + write
    for _ in range(levels):
        line = "echo $(" + line + ")"
    return "d=" + line[len("echo "):] if levels else line


UNPARSED = NOT_SHELL + (_deep(MAX_DEPTH + 1), _deep(200), "x=${a:-" * 300 + "}" * 300 + " > /tmp/out.$$")


def _wrap(inner: str, form: str) -> str:
    if form == "`":
        return "`" + inner.replace("\\", "\\\\").replace("`", "\\`") + "`"
    return '"$(' + inner + ')"' if form == '"$(' else "$(" + inner + ")"


def corpus() -> list[tuple[str, bool]]:
    """(shell, whether it writes a guessable shared-temp name): nesting depth 0-3 x substitution form x the
    template's quoting x a plain or nested template x where the unsafe write sits (none: the line is safe), then
    COMMENTS, UNPARSED, NOT_COMMANDS, EXPANSIONS, DATA_SUBS and CASE_IN_SUBS, MAX_DEPTH levels deep, and the
    MISSES. Whole files are in FILES."""
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
    for line, unsafe in NOT_COMMANDS + EXPANSIONS + tuple(_data_subs()) + tuple(_case_in_subs()):
        out[line] = unsafe
    out[_deep(MAX_DEPTH)] = False
    out[_deep(MAX_DEPTH, "; echo > /tmp/out.$$")] = True
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
    ("scripts/workflow-safe.yml", "jobs:\n  a:\n    steps:\n      - run: |\n          d=$(mktemp -d \\\n"
     "            /tmp/$USER.XXXXXX)\n", False),
)


if __name__ == "__main__":
    if sys.argv[1:] == ["--corpus"]:
        json.dump(corpus(), sys.stdout)
    elif sys.argv[1:] == ["--files"]:  # [[path, text], ...] -> [scan_file(path, text), ...]
        json.dump([scan_file(p, t) for p, t in json.load(sys.stdin)], sys.stdout)
    elif sys.argv[1:] == ["--file-corpus"]:
        json.dump(FILES, sys.stdout)
    else:
        json.dump([scan_text(code(t)) for t in json.load(sys.stdin)], sys.stdout)
