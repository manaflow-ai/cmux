"""The one invocation detector for a workflow `run:` block: which programs a bash script really runs.

invocations(run) lexes the script the way bash does for the three things that decide it: quoting, operators and
heredocs. A word keeps whether any part of it was quoted, and only an UNQUOTED operator counts, so
`echo ";" python3 x` runs echo (one command) and `printf '%s\\n' '<<' EOF` opens no heredoc. A heredoc body is
skipped up to its terminator: an exact `EOF` line for `<<`, a line with only leading TABS stripped for `<<-`;
several heredocs on one line (`cat <<A <<B`) take their bodies in order. Comments, redirections and their targets
are not words. A script the lexer cannot finish (an unterminated quote) runs nothing from that point on, so a
reader built on this fails closed (the job is named, not exempted). Command substitution inside double quotes is
not entered. tests/test_shell_invocations.py runs each fixture in real bash and compares.
"""
from __future__ import annotations

import re
from typing import NamedTuple

# Longest first: the first operator in this list that matches at a position is the one read there.
_OPERATORS = ("<<<", "<<-", "<<", "<&", "<>", "<", ">>", "&>>", "&>", ">&", ">|", ">", "&&", "&", "||", "|&", "|",
              ";;&", ";;", ";&", ";", "(", ")")
_REDIRECTS = {"<<<", "<<-", "<<", "<&", "<>", "<", ">>", "&>>", "&>", ">&", ">|", ">"}
_HEREDOCS = {"<<", "<<-"}
# Words a simple command may start with before the program it runs. Keywords only count unquoted; the others are
# commands that run what follows.
_KEYWORDS = {"if", "elif", "while", "until", "!", "then", "else", "do", "{", "}"}
_PREFIX_COMMANDS = {"exec", "time", "command", "env", "nohup"}
_SHELLS = {"bash", "sh", "zsh"}
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_SPACE = " \t"
_DOUBLE_ESCAPES = '"\\$`'


class Token(NamedTuple):
    kind: str  # "word", "op" or "nl"
    text: str
    quoted: bool = False  # a word with any quoted or escaped part
    start: int = 0
    end: int = 0


def _skip_heredoc_bodies(text: str, index: int, pending: list[tuple[str, bool]]) -> int:
    """The index after the bodies of every pending heredoc, read in order from the line starting at `index`."""
    for delimiter, strip_tabs in pending:
        while index < len(text):
            newline = text.find("\n", index)
            line = text[index:] if newline < 0 else text[index:newline]
            index = len(text) if newline < 0 else newline + 1
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                break
    return index


def lex(text: str) -> list[Token] | None:
    """The script's tokens; None would mean unlexable, so the tokens before the failure are returned instead."""
    tokens: list[Token] = []
    pending: list[tuple[str, bool]] = []
    expect_delimiter: bool | None = None  # set to the <<- flag after a heredoc operator, until its word arrives
    buf: list[str] = []
    quoted = False
    in_word = False
    word_start = 0
    i = 0

    def end_word(at: int) -> None:
        nonlocal buf, quoted, in_word, expect_delimiter
        if not in_word:
            return
        word = "".join(buf)
        if expect_delimiter is not None:
            pending.append((word, expect_delimiter))
            expect_delimiter = None
        tokens.append(Token("word", word, quoted, word_start, at))
        buf, quoted, in_word = [], False, False

    while i < len(text):
        c = text[i]
        if c == "\\":
            if text[i + 1:i + 2] == "\n":
                i += 2
                continue
            if i + 1 >= len(text):
                break
            if not in_word:
                in_word, word_start = True, i
            buf.append(text[i + 1])
            quoted = True
            i += 2
        elif c == "'":
            close = text.find("'", i + 1)
            if close < 0:
                return tokens
            if not in_word:
                in_word, word_start = True, i
            buf.append(text[i + 1:close])
            quoted = True
            i = close + 1
        elif c == '"':
            if not in_word:
                in_word, word_start = True, i
            quoted = True
            i += 1
            while True:
                if i >= len(text):
                    return tokens
                if text[i] == '"':
                    i += 1
                    break
                if text[i] == "\\" and i + 1 < len(text):
                    if text[i + 1] in _DOUBLE_ESCAPES:
                        buf.append(text[i + 1])
                        i += 2
                        continue
                    if text[i + 1] == "\n":
                        i += 2
                        continue
                buf.append(text[i])
                i += 1
        elif c == "#" and not in_word:
            newline = text.find("\n", i)
            i = len(text) if newline < 0 else newline
        elif c in _SPACE:
            end_word(i)
            i += 1
        elif c == "\n":
            end_word(i)
            tokens.append(Token("nl", "\n", False, i, i + 1))
            i += 1
            if pending:
                i = _skip_heredoc_bodies(text, i, pending)
                pending.clear()
        elif c == "$" and text[i + 1:i + 2] == "(":
            end_word(i)
            tokens.append(Token("op", "(", False, i, i + 2))
            i += 2
        elif c in ";&|()<>":
            end_word(i)
            operator = next(op for op in _OPERATORS if text.startswith(op, i))
            if operator in _HEREDOCS:
                expect_delimiter = operator == "<<-"
            tokens.append(Token("op", operator, False, i, i + len(operator)))
            i += len(operator)
        else:
            if not in_word:
                in_word, word_start = True, i
            buf.append(c)
            i += 1
    end_word(len(text))
    return tokens


def commands(run: str) -> list[list[Token]]:
    """Each simple command's words: operators that end a command split it, redirections and their targets drop out."""
    found: list[list[Token]] = []
    words: list[Token] = []
    skip_target = False
    previous: Token | None = None
    for token in lex(run) or []:
        if token.kind == "word":
            if skip_target:
                skip_target = False
            else:
                words.append(token)
        elif token.kind == "op" and token.text in _REDIRECTS:
            # `2>/dev/null`: the file descriptor number written against the operator is no word.
            if words and words[-1] is previous and previous.end == token.start and not previous.quoted \
                    and previous.text.isdigit():
                words.pop()
            skip_target = True
        else:
            skip_target = False
            if words:
                found.append(words)
            words = []
        previous = token
    if words:
        found.append(words)
    return found


def invocations(run: str) -> list[list[str]]:
    """The one invocation detector: each simple command a `run:` block runs, as its words (the program first, a
    leading `./` dropped). Only a command's program counts as run, so text that only names a script runs nothing:
    comments, echo and printf arguments, quoted strings and heredoc bodies (see the module text). Env assignments,
    unquoted keywords (`if`, `then`, `!`, `{`), `exec`/`time`/`env`-style prefixes and a shell's options before its
    script are skipped; `;`, `&&`, `||`, `|`, `&`, newlines, parentheses and `$(` start a new command."""
    programs = []
    for words in commands(run):
        start = 0
        while start < len(words) and (
                _ASSIGNMENT.match(words[start].text)
                or (words[start].text in _KEYWORDS and not words[start].quoted)
                or words[start].text in _PREFIX_COMMANDS):
            start += 1
        if start < len(words) and words[start].text in _SHELLS:
            start += 1
            while start < len(words) and words[start].text.startswith("-"):
                start += 1
        if start < len(words):
            programs.append([words[start].text.removeprefix("./"), *(w.text for w in words[start + 1:])])
    return programs
