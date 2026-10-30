#!/usr/bin/env python3
"""Task ids in code comments: find them, and strip them from tracked files.

A task id (`p04-input-053`, `cp/p10-stability-083/084`) names the plan item a change came from. It belongs in the
commit message, where `git log` and `git blame` find it, not in a code comment, where it says nothing to a reader
without the plan and goes stale when the code moves on. guardrails.py's `task-id-comment` rule refuses new ones
(local pre-push tier); this file is that rule's one definition of an id and of a comment.

  scripts/cmux-next/task_ids.py --strip [PATH...]   # rewrite the comments of tracked files (default: every one)
  scripts/cmux-next/task_ids.py --check [PATH...]   # list the comment lines that still hold an id; exit 1 if any

Only comments change: string literals, identifiers, docstrings and data files keep their ids. A comment keeps its
meaning: a parenthetical that only names ids goes, an id in a longer parenthetical or at the start of a comment is
cut with its separator, and a comment line left empty goes. An id this cannot cut without changing the sentence
(`the flip is p02-threads-021`) stays and is listed by --check, for a person to reword.
"""
from __future__ import annotations

import argparse
import difflib
import io
import re
import subprocess
import sys
import tokenize
from pathlib import Path


ID = r"p[01][0-9]-[a-z]+(?:-[a-z]+)*-[0-9]{3}[a-z]?"
H = r"[ \t]"  # a space inside one comment line; LIST and the parentheticals may also span the lines of a comment
# An id as a comment names it: optionally backticked, a `cp/` branch prefix, `/084` siblings, a `(fixer)` suffix.
# Never part of a path or a longer word (`plans/p01-process.md`, `p04-input-053.json`, `foo_p04-input-053`).
ID_TOKEN = (r"(?<![\w/.-])`?(?:cp/)?" + ID + r"(?:/[0-9]{3}[a-z]?)*`?(?![\w/-]|\.\w)"
            r"(?:" + H + r"*\((?:fixer|review)\))?")
ID_RE = re.compile(ID_TOKEN)
# Bare sibling numbers after an id: `(p02-threads-130, 146)`, `(p15-oracle-027, 033 to 044, 188)`, `(p10-stability-172, -055)`.
SIBLING = (r"(?:" + H + r"*(?:,|\band\b|\bto\b)?" + H + r"*-?" + H + r"*(?<=[\s,-])[0-9]{3}[a-z]?\b(?![-\w])"
           r"(?=" + H + r"*(?:[,;)\]]|\band\b|\bto\b|$)))")
# Words that only lead to or join ids: a parenthetical made of them and ids says nothing without the plan.
FILLER = (r"(?:tasks?|chrome-parity|fixer|the|review(?:" + H + r"+\d+)?|of|see|merged" + H + r"+into|and|or|from|"
          r"after|by|for|finding|items?|follow-?up|part|plus|also|via|per|round" + H + r"+\d+|rule" + H + r"+\d+|"
          r"landed" + H + r"+in|cf\.|e\.g\.|section" + H + r"+[0-9A-Z]+|done" + H + r"+check" + H + r"+\w+)")
ONE = ID_TOKEN + SIBLING + "*"
LIST = ONE + r"(?:\s*(?:,|/|\+|&|;|\band\b|\bor\b)\s*" + ONE + r")*"
LEADIN = r"(?:" + FILLER + r"\s+)*"  # may end a line: `(remote_shim_choosers.h, task\n// p01-process-228)`

ONLY_IDS_PAREN = re.compile(H + r"?\((?:\s|[,;:/+&.-]|\b" + FILLER + r"\b|" + ONE + r")*\)")
ONLY_IDS_BRACKET = re.compile(H + r"?\[(?:\s|[,;:/+&.-]|\b" + FILLER + r"\b|" + ONE + r")*\]")
# Inside a parenthetical that says more: `(x, p08-startup-031)`, `(chrome-parity p03-rendering-100, x)`.
PAREN_TAIL = re.compile(H + r"*[,;]\s*" + LEADIN + LIST + r"(?=\s*[)\]])")
PAREN_HEAD = re.compile(r"(?<=[(\[])" + H + r"*" + LEADIN + LIST + r"(?:" + H + r"*[,;:]" + H + r"*|" + H +
                        r"+(?:of|in)" + H + r"+)")
PAREN_MID = re.compile(H + r"*[,;]" + H + r"*" + LEADIN + LIST + r"(?=" + H + r"*[,;])")
# At the start of a comment line: `p07-memory-082: the engine ...`, `p06-scheduler-346 (rule 9): one case ...`.
LEAD = re.compile(r"^(?:" + FILLER + H + r"+)*" + LIST + r"(?:" + H + r"*\((?:fixer|review|rule" + H + r"+\d+)\))?"
                  r"(?:" + H + r"*[:.,;]+" + H + r"*|" + H + r"+-+" + H + r"+|" + H + r"*$)", re.M)
# At the end of a line, after a separator: `..., p04-input-079.`, `... - p04-input-079`.
TAIL = re.compile(r"(?:" + H + r"*[,;]|" + H + r"+-+)" + H + r"*" + LEADIN + LIST + r"(?=" + H + r"*\.?" + H +
                  r"*$)", re.M)

C_LIKE = {".swift", ".rs", ".ts", ".tsx", ".js", ".mjs", ".cjs", ".h", ".c", ".cc", ".cpp", ".m", ".mm", ".go",
          ".kt", ".java"}
NESTING = {".swift", ".rs"}
HASH = {".py", ".sh", ".bash", ".zsh", ".toml", ".yml", ".yaml"}
SKIP_DIRS = ("vendor/", "ghostty/", "tests/oracle/corpus/", ".github/")
# This tool and its tests show ids in their comments on purpose.
SELF = ("scripts/cmux-next/task_ids.py",)
# Files whose bytes, comments included, are an input of a hash the repo records or checks at run time: the shim's ABI
# identity is the sha256 of the whole header (gen-chromium-host-wire.py `Header.sha256`, `CEFShimABI.bundledIdentity`).
# Their comments change only together with a regeneration of what pins the hash.
HASHED = ("Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h",)


# ---------------------------------------------------------------- comment spans

def c_like_comments(text: str, ext: str) -> list[tuple[int, int]]:
    """(start, end) offsets of TEXT's comments, `//` and `/* */`, outside string and character literals."""
    spans, i, n = [], 0, len(text)
    swift, rust = ext == ".swift", ext == ".rs"
    js = ext in {".ts", ".tsx", ".js", ".mjs", ".cjs"}

    def skip_string(i: int, quote: str, raw_hashes: int = 0) -> int:
        """Offset after the string literal that opens at I with QUOTE (`"`, `\"\"\"`, `'`, `` ` ``)."""
        close = quote + "#" * raw_hashes
        while i < n:
            if text.startswith(close, i):
                return i + len(close)
            c = text[i]
            if c == "\\" and raw_hashes == 0:
                if swift and text.startswith("\\(", i):
                    i = skip_interpolation(i + 2, ")")
                    continue
                i += 2
                continue
            if js and quote == "`" and text.startswith("${", i):
                i = skip_interpolation(i + 2, "}")
                continue
            if c == "\n" and len(quote) == 1 and quote != "`" and not rust:
                return i  # an unterminated one-line literal: stop at the line end
            i += 1
        return n

    def skip_interpolation(i: int, close: str) -> int:
        depth = 1
        opener = "(" if close == ")" else "{"
        while i < n and depth:
            c = text[i]
            if c == '"' or (js and c in "'`"):
                i = skip_string(i + 1, c)
                continue
            if c == "/" and regex_start(text, i):
                i = skip_regex(text, i)
                continue
            if c == opener:
                depth += 1
            elif c == close:
                depth -= 1
            i += 1
        return i

    while i < n:
        c = text[i]
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            spans.append((i, end))
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if ext in NESTING and text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            spans.append((i, j))
            i = j
        elif swift and c == "#" and re.match(r"#+\"", text[i:i + 8]):
            hashes = len(re.match(r"#+", text[i:]).group(0))
            start = i + hashes
            quote = '"""' if text.startswith('"""', start) else '"'
            i = skip_string(start + len(quote), quote, hashes)
        elif rust and c == "r" and re.match(r"r#*\"", text[i:i + 8]) and raw_prefix_ok(text, i):
            hashes = len(re.match(r"r(#*)", text[i:]).group(1))
            if hashes:
                i = skip_string(i + 1 + hashes + 1, '"', hashes)
            else:  # r"..." has no escapes: it ends at the next quote
                end = text.find('"', i + 2)
                i = n if end < 0 else end + 1
        elif c == '"':
            quote = '"""' if text.startswith('"""', i) else '"'
            i = skip_string(i + len(quote), quote)
        elif c == "'" and rust:
            if text.startswith("\\", i + 1):
                close = text.find("'", i + 2)
                i = close + 1 if close > 0 else i + 1
            elif i + 2 < n and text[i + 2] == "'":
                i += 3
            else:
                i += 1  # a lifetime
        elif js and c in "'`":
            i = skip_string(i + 1, c)
        elif c == "'" and not swift and not js:  # a C character literal: '"', '\'', 'a'
            m = re.match(r"'(?:\\.[^'\n]{0,8}|[^'\\\n])'", text[i:i + 12])
            i += m.end() if m else 1
        elif (js or swift) and c == "/" and regex_start(text, i):
            i = skip_regex(text, i)
        elif swift and text.startswith("#/", i):
            end = text.find("/#", i + 2)
            i = n if end < 0 else end + 2
        else:
            i += 1
    return spans


def raw_prefix_ok(text: str, i: int) -> bool:
    """Whether the `r` at I starts a Rust raw string (`r"`, `br#"`, `cr"`), not the end of an identifier."""
    j = i - 1 if i > 0 and text[i - 1] in "bc" else i
    return j == 0 or not (text[j - 1].isalnum() or text[j - 1] == "_")


REGEX_BEFORE = set("(,=:[!&|?{};+-*%<>~^")
REGEX_WORDS = {"return", "typeof", "case", "of", "in", "delete", "void", "throw", "new", "yield", "await", "try"}


def regex_start(text: str, i: int) -> bool:
    """Whether the `/` at I opens a regex literal (TypeScript, Swift): what comes before it cannot end an operand,
    and the literal closes on its line. Else it is a division."""
    j = i - 1
    while j >= 0 and text[j] in " \t":
        j -= 1
    if j >= 0 and text[j] != "\n":
        word = re.search(r"[A-Za-z_$][\w$]*$", text[max(0, j - 12):j + 1])
        if not (text[j] in REGEX_BEFORE or (word and word.group(0) in REGEX_WORDS)):
            return False
    if text[i + 1:i + 2] in (" ", "\t", "\n", ""):
        return False  # `/ ` is an operator
    return skip_regex(text, i) is not None and skip_regex(text, i) > i


def skip_regex(text: str, i: int) -> int | None:
    """Offset after the regex literal that opens at I (escapes and `[...]` classes skipped), or None when it does not
    close on its line."""
    j, in_class = i + 1, False
    while j < len(text) and text[j] != "\n":
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == "[":
            in_class = True
        elif c == "]":
            in_class = False
        elif c == "/" and not in_class:
            return j + 1
        j += 1
    return None


def hash_comments(text: str, ext: str) -> list[tuple[int, int]]:
    """(start, end) offsets of `#` comments: Python's from its tokenizer; in shell, TOML and YAML only whole-line
    ones (a trailing `#` may be inside a word, a quote or a parameter expansion), outside a shell heredoc's body and
    a TOML multi-line string."""
    if ext == ".py":
        starts = [0]
        for line in text.splitlines(keepends=True):
            starts.append(starts[-1] + len(line))
        spans = []
        try:
            for tok in tokenize.generate_tokens(io.StringIO(text).readline):
                if tok.type == tokenize.COMMENT:
                    (row, col), (erow, ecol) = tok.start, tok.end
                    spans.append((starts[row - 1] + col, starts[erow - 1] + ecol))
        except (tokenize.TokenError, IndentationError, SyntaxError):
            return []
        return spans
    spans, offset, heredoc, toml_quote = [], 0, None, None
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\n")
        if heredoc is not None:  # inside a heredoc: only its terminator ends it
            if body.strip() == heredoc:
                heredoc = None
            offset += len(line)
            continue
        if toml_quote is not None:
            if toml_quote in body:
                toml_quote = None
            offset += len(line)
            continue
        if ext in (".sh", ".bash", ".zsh"):
            opened = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", body)
            if opened and not body.lstrip().startswith("#"):
                heredoc = opened.group(2)
        elif ext == ".toml":
            for quote in ('"""', "'''"):
                if body.count(quote) % 2 == 1:
                    toml_quote = quote
        m = re.match(r"\s*#", line)
        if m and not line.startswith("#!"):
            body = line.rstrip("\n")
            spans.append((offset + m.end() - 1, offset + len(body)))
        offset += len(line)
    return spans


def comment_spans(path: str, text: str) -> list[tuple[int, int]]:
    ext = Path(path).suffix
    if ext in C_LIKE:
        return c_like_comments(text, ext)
    if ext in HASH:
        return hash_comments(text, ext)
    return []


# ---------------------------------------------------------------- rewriting

CUT = "\x00"


def _cut(m: re.Match) -> str:
    """A cut keeps the comment's line breaks, so every line stays where it was (rewrite() drops emptied ones)."""
    return CUT + "\n" * m.group(0).count("\n")


# Brackets a cut left with nothing in them; `foo()` in a comment is code and never matches (no cut inside).
EMPTIED_PAREN = re.compile(r"[ \t]?\((?:\s|" + CUT + r")*" + CUT + r"(?:\s|" + CUT + r")*\)")


def _only_ids(m: re.Match) -> str:
    return _cut(m) if ID_RE.search(m.group(0)) else m.group(0)


def _tidy(text: str) -> str:
    """Join the text around each cut: no space before closing punctuation, after an opening bracket or at a line
    end; one space between words."""
    while CUT in text:
        at = text.index(CUT)
        left, right = text[:at], text[at + 1:]
        left_stripped = left.rstrip(" \t")
        right_stripped = right.lstrip(" \t")
        if (not right_stripped or right_stripped[0] in ".,;:)]!?\n" or not left_stripped
                or left_stripped[-1] in "([\n"):
            sep = ""
        else:
            sep = " "
        if not left_stripped or left_stripped.endswith("\n"):
            left_stripped = left  # keep a line's own indentation
        text = left_stripped + sep + right_stripped
    return text


def _lead(m: re.Match) -> str:
    return "\x04" + "\n" * m.group(0).count("\n")


def rewrite_text(body: str) -> str:
    """BODY (the text of a comment, its lines' markers removed, joined with newlines) with its ids cut where the
    sentence survives the cut. The line count stays the same."""
    if not ID_RE.search(body):
        return body
    text = body
    for _ in range(3):  # a nested or repeated form clears in a second pass
        before = text
        text = ONLY_IDS_PAREN.sub(_only_ids, text)
        text = ONLY_IDS_BRACKET.sub(_only_ids, text)
        text = PAREN_TAIL.sub(_cut, text)
        text = PAREN_MID.sub(_cut, text)
        text = PAREN_HEAD.sub(_cut, text)
        text = EMPTIED_PAREN.sub(lambda m: "\n" * m.group(0).count("\n"), text)
        text = _tidy(text)
        text = LEAD.sub(_lead, text)
        text = TAIL.sub(_cut, text)
        text = EMPTIED_PAREN.sub(lambda m: "\n" * m.group(0).count("\n"), text)
        text = _tidy(text)
        if text == before:
            break
    # A cut id that started a sentence: its next word starts the sentence now.
    out, lines = [], text.split("\n")
    for k, line in enumerate(lines):
        if "\x04" in line:
            at = line.index("\x04")
            rest = line[at + 1:]
            starts = k == 0 or not out[-1].strip() or out[-1].rstrip().endswith((".", ":", "!", "?"))
            if starts and capitalizable(rest):
                rest = rest[0].upper() + rest[1:]
            line = line[:at] + rest
        out.append(line)
    return "\n".join(out)


# Names written in lower case even at a sentence start.
LOWERCASE_NAMES = {"cmux", "libghostty", "ghostty", "git", "npm", "bun", "cargo", "macos", "ios", "iframe", "xcodebuild",
                   "launchd", "dyld", "malloc", "pthread", "zsh", "bash", "rustc", "swiftc", "vite", "vp"}


def capitalizable(rest: str) -> bool:
    """Whether REST starts with a plain lower-case word that may take a capital at a sentence start: not code
    (`name(`, `a.b`, `a_b`, camelCase) and not a name written in lower case."""
    m = re.match(r"([a-z]+)\b(?![`(._:'-])", rest)
    return bool(m) and not re.match(r"[a-z]+[A-Z]", rest) and m.group(1) not in LOWERCASE_NAMES


LINE_MARK = re.compile(r"^(\s*)(//[/!]?|#+)( ?)")  # `//`, `///`, Rust's `//!`, `#`
BLOCK_MARK = re.compile(r"^(\s*\*(?!/)[ \t]?|\s*)")


def _groups(path: str, text: str):
    """The comments of TEXT as groups of (start, end) spans: a run of line comments on consecutive lines with the
    same marker and indentation (one paragraph), or one block comment."""
    spans = comment_spans(path, text)
    groups: list[list[tuple[int, int]]] = []
    for a, b in spans:
        chunk = text[a:b]
        line_start = text.rfind("\n", 0, a) + 1
        own_line = not text[line_start:a].strip()
        marker = LINE_MARK.match(chunk)
        kind = (marker.group(2), a - line_start) if marker and not chunk.startswith("/*") else None
        if (groups and kind and own_line and groups[-1][-1][2] == kind
                and text.count("\n", groups[-1][-1][1], a) == 1 and not text[groups[-1][-1][1]:a].strip()):
            groups[-1].append((a, b, kind))
        else:
            groups.append([(a, b, kind if own_line else ("code", kind))])
    return groups


def pull_up_punctuation(bodies: list[str], new: list[str]) -> None:
    """A line whose body now starts with the punctuation that followed a cut id (`).`, `,`, `);`): it goes up to
    the end of the line above, and a closing bracket takes the place of a comma or semicolon left there."""
    for k in range(len(new)):
        m = re.match(r"([ \t]*)([)\]]*[.,;:]?)(?:[ \t]+|$)", new[k])
        if not (m and m.group(2)) or re.match(r"[ \t]*[)\].,;:]", bodies[k]):
            continue
        j = k - 1
        while j >= 0 and not new[j].strip():
            j -= 1
        mark = m.group(2)
        closers = re.match(r"[)\]]*", mark).group(0)
        if j >= 0 and closers:
            new[j] = new[j].rstrip().rstrip(",;").rstrip() + mark
        elif j >= 0 and not new[j].rstrip().endswith((".", ",", ";", ":")):
            new[j] = new[j].rstrip() + mark
        rest = new[k][m.end():]
        if mark.endswith(".") and capitalizable(rest):
            rest = rest[0].upper() + rest[1:]
        new[k] = (m.group(1) + rest) if rest.strip() else ""


def reopen_parens(bodies: list[str], new: list[str]) -> None:
    """A cut that took the head of a parenthetical opened at a line's end: the "(" goes down to its words."""
    for k in range(len(new) - 1):
        if new[k] != bodies[k] and new[k].rstrip().endswith("(") and not bodies[k].rstrip().endswith("("):
            j = k + 1
            while j < len(new) and not new[j].strip():
                j += 1
            if j < len(new):
                new[k] = new[k].rstrip()[:-1].rstrip()
                lead = re.match(r"[ \t]*", new[j]).group(0)
                new[j] = lead + "(" + new[j][len(lead):]


def keep_indent(bodies: list[str], new: list[str]) -> None:
    """A changed line keeps the indentation it had: a cut that spans a line break takes the next line's leading
    blanks with it, and a continuation line of a Markdown list item that lost its indent ends the item (rustdoc
    and clippy's doc_lazy_continuation read it as a new paragraph)."""
    for k, (old, body) in enumerate(zip(bodies, new)):
        if body == old or not body.strip():
            continue
        lead = re.match(r"[ \t]*", old).group(0)
        new[k] = lead + body.lstrip(" \t")


def _drop(text: str, a: int, b: int) -> tuple[int, int, str]:
    """The edit that removes the comment TEXT[A:B]: its line when the line holds nothing else, else the comment and
    the space before it."""
    line_start = text.rfind("\n", 0, a) + 1
    if not text[line_start:a].strip():
        return line_start, (b + 1 if text[b:b + 1] == "\n" else b), ""
    return a - (len(text[line_start:a]) - len(text[line_start:a].rstrip())), b, ""


GENERATED_FILE = re.compile(r"@generated|\bgenerated (?:by|from)\b|\bdo not edit\b|\bautogenerated\b", re.I)
GENERATED_BEGIN = re.compile(r"\bBEGIN\b.*\b(?:generated|do not edit)\b", re.I)
GENERATED_END = re.compile(r"\bEND\b")


def generated_ranges(text: str) -> list[tuple[int, int]]:
    """Offsets a generator owns: the whole text when its first lines say it is generated, else each
    `BEGIN <tool>: generated ...` to `END` block. Its comments change only by changing the generator's input."""
    if any(GENERATED_FILE.search(line) and not GENERATED_BEGIN.search(line) for line in text.split("\n", 8)[:8]):
        return [(0, len(text))]  # a generated file's header (a BEGIN line opens only its block)
    out, start, offset = [], None, 0
    for line in text.split("\n"):
        if start is None and GENERATED_BEGIN.search(line):
            start = offset
        elif start is not None and GENERATED_END.search(line):
            out.append((start, offset + len(line)))
            start = None
        offset += len(line) + 1
    if start is not None:
        out.append((start, len(text)))
    return out


def rewrite(path: str, text: str) -> tuple[str, list[int]]:
    """(TEXT with its comments' ids cut, 1-based lines that still hold an id in a comment). A generated file or
    block keeps its comments, and its ids are not listed."""
    owned = generated_ranges(text)
    groups = [g for g in _groups(path, text) if not any(a <= g[0][0] < b for a, b in owned)]
    edits: list[tuple[int, int, str]] = []  # (start, end, replacement) in TEXT, ascending
    for group in groups:
        if not any(ID_RE.search(text[a:b]) for a, b, _ in group):
            continue
        heads, bodies = [], []
        if text.startswith("/*", group[0][0]):  # one block comment: its lines
            a, b, _ = group[0]
            chunk = text[a:b]
            opener = re.match(r"/\*\*?[ \t]?", chunk).group(0)
            closer = "*/" if chunk.endswith("*/") else ""
            inner = chunk[len(opener):len(chunk) - len(closer)]
            lines = inner.split("\n")
            for k, line in enumerate(lines):
                head = opener if k == 0 else BLOCK_MARK.match(line).group(0)
                heads.append(head)
                bodies.append(line if k == 0 else line[len(head) - 0:])
            new = rewrite_text("\n".join(bodies)).split("\n")
            pull_up_punctuation(bodies, new)
            reopen_parens(bodies, new)
            keep_indent(bodies, new)
            kept = []
            for k, (head, old, body) in enumerate(zip(heads, bodies, new)):
                if body != old and not body.strip() and old.strip() and 0 < k < len(new) - 1:
                    continue  # an inner line that held only ids
                trail = re.search(r"[ \t]*$", old).group(0) if k == len(new) - 1 else ""
                kept.append((head if k else "") + (body.rstrip() + trail if body != old else old))
            if not "".join(new).strip():  # the comment held only ids
                edits.append(_drop(text, a, b))
                continue
            edits.append((a, b, opener + "\n".join(kept) + closer))
            continue
        for a, b, _ in group:
            chunk = text[a:b]
            m = LINE_MARK.match(chunk)
            heads.append(m.group(0))
            bodies.append(chunk[m.end():])
        new = rewrite_text("\n".join(bodies)).split("\n")
        assert len(new) == len(bodies), path
        pull_up_punctuation(bodies, new)
        reopen_parens(bodies, new)
        keep_indent(bodies, new)
        for (a, b, kind), head, old, body in zip(group, heads, bodies, new):
            if body == old:
                continue
            if body.strip() or not old.strip():
                edits.append((a, b, head + body.rstrip()))
                continue
            edits.append(_drop(text, a, b))  # the comment held only ids
    out, last = [], 0
    for a, b, r in sorted(edits):
        out.append(text[last:a])
        out.append(r)
        last = b
    out.append(text[last:])
    result = "".join(out)
    if result != text and not only_comment_text_changed(path, text, result):
        result = text  # the lexer misread this file: leave it whole, and --check lists its ids
    remaining = []
    owned = generated_ranges(result)
    for a, b in comment_spans(path, result):
        if ID_RE.search(result[a:b]) and not any(x <= a < y for x, y in owned):
            first = result.count("\n", 0, a) + 1
            for k, line in enumerate(result[a:b].split("\n")):
                if ID_RE.search(line):
                    remaining.append(first + k)
    return result, remaining


def only_comment_text_changed(path: str, old: str, new: str) -> bool:
    """A line-level check of a rewrite, independent of the lexer: every changed line was a comment-only line, or
    keeps the code before its comment marker. A lexer that took code for a comment (a string or a regex literal it
    did not see) fails it."""
    hash_marks = Path(path).suffix in HASH
    marker = re.compile(r"#" if hash_marks else r"//|/\*|^\s*\*")
    old_lines, new_lines = old.split("\n"), new.split("\n")
    matcher = difflib.SequenceMatcher(a=old_lines, b=new_lines, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        news = new_lines[j1:j2]
        for line in old_lines[i1:i2]:
            stripped = line.strip()
            if stripped.startswith(("#",) if hash_marks else ("//", "/*", "*")):
                continue
            mark = marker.search(line)
            if not mark or not any(n.rstrip() == line[:mark.start()].rstrip() or n.startswith(line[:mark.end()])
                                   for n in news):
                return False
        for line in news:
            mark = marker.search(line)
            if not (line.strip().startswith(("#",) if hash_marks else ("//", "/*", "*")) or mark
                    or any(o.startswith(line.rstrip()) for o in old_lines[i1:i2])):
                return False
    return True


# ---------------------------------------------------------------- files

def tracked(repo: Path, paths: list[str]) -> list[str]:
    out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", "--", *paths], capture_output=True, check=True)
    files = [p for p in out.stdout.decode().split("\0") if p]
    return [p for p in files if Path(p).suffix in C_LIKE | HASH and not p.startswith(SKIP_DIRS) and p not in SELF + HASHED
            and not p.endswith((".min.js", ".bundle.js"))
            and "/vendor/" not in p and "/Vendor/" not in p]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--strip", action="store_true")
    mode.add_argument("--check", action="store_true")
    parser.add_argument("--repo", default=".")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv)
    repo = Path(subprocess.run(["git", "-C", args.repo, "rev-parse", "--show-toplevel"], capture_output=True,
                               text=True, check=True).stdout.strip())
    changed = left_total = 0
    for rel in tracked(repo, args.paths):
        path = repo / rel
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if not ID_RE.search(text):
            continue
        new, left = rewrite(rel, text)
        if args.strip and new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
        for number in left:
            print(f"{rel}:{number}: {new.split(chr(10))[number - 1].strip()}")
        left_total += len(left)
    if args.strip:
        print(f"task_ids: rewrote {changed} files; {left_total} comment lines still hold an id (listed above)",
              file=sys.stderr)
    return 1 if args.check and left_total else 0


if __name__ == "__main__":
    sys.exit(main())
