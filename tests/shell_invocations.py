"""Which programs a bash `run:` block runs, as a three-valued answer a caller must interpret.

A caller asks one of two questions and the two fail closed in opposite directions, so there is no default:

- must_run(run): the commands bash really runs and whose program is certain. Use it where a script CREDITS a step
  ("this step runs the signer / creates the keychain"): a command this detector cannot be sure of is not run.
- may_run(run): every command that might run, certain or not. Use it where a script is BLAMED ("is this file
  guarded / run"): a command it cannot be sure of is assumed to run. An Invocation with `any_program` may run
  programs the words do not name (eval, xargs, `bash -c`, a function, an unlexable tail), so a may_run caller asking
  "might PROGRAM run" uses may_run_program(), which counts those.
- may_run_nested(run): may_run's commands plus the ones inside each that runs others (eval text, `bash -c` text,
  the argv tails of xargs, find -exec, sudo ...), with [] for executable content it cannot read (a heredoc into a
  shell, eval of a variable, a sourced file). Use it where a script is blamed for what a command may do
  (tests/test_ci_release_publish_tag_gate.py: "may this publish"), and count [] as yes.
- gh_api_request(args): the method and endpoint `gh api` sends, read the way gh reads its flags.
- first_operand(args, options): where a tool's subcommand is, read with its option grammar, so an option's value is
  never taken for a subcommand.

What an expansion's body runs (`${..}`, `$((..))`, an array subscript, an unquoted heredoc body) is read by the
shared parser tests/shell_tree.py, to any depth; a body it cannot read stops the lexer, so what follows may run
anything.

An Invocation is `certain` only when nothing in or before the simple command is beyond this lexer: a command or
process substitution (`$(..)`, backticks, `<(..)`), an arithmetic or parameter expansion in its program word, a
program that runs its arguments (eval, source, xargs, find, `bash -c` ...), a function or alias defined anywhere in
the script, or a script the lexer could not finish (an unterminated quote or substitution). A wrapper (env, nice,
nohup, timeout, sudo, command, exec ...) and a shell given a script are read through one table of which operand
runs (_WRAPPERS, _shell_script): an option it does not model, or a mode that does not run the first operand as a
script (`bash -n`, `-s`, `-i`, `-o NAME`, `--rcfile`, `command -v`), leaves the command uncertain. Commands
inside a substitution, and those in an unquoted heredoc body's `$(..)`, are reported uncertain, as are those a
parameter or arithmetic expansion holds (`${X:-$(..)}`, `${X/$(..)/}`, `$(( $(..) ))`).

`certain` also means bash reaches the command whenever the script runs to its end (`set -e` semantics): control flow
is read, and a command it may skip is uncertain (cmux#40784 F1: `false && sign` credited the signer). Only the
commands of the top-level sequence, and of `{ }` groups and `( )` subshells in it, are reached: the left side of `&&`
and `||` (the right side is not), and the first `if`'s condition (its `then`, `elif` and `else` parts are not).
`while`, `until`, `for`, `select` and `case` parts, a function body, everything after the first `exit`, `return` or
`exec PROGRAM`, and everything after a keyword this cannot pair (a `fi` with no `if`) are not reached. tests/
test_shell_invocations.py runs each fixture in real bash and checks must_run is a subset of what ran and may_run a
superset.

Lexing keeps quoting: a word remembers whether any part was quoted or escaped, and only an unquoted operator splits
commands, opens a heredoc or redirects. Words are read the way bash reads them (#41768 review): a prefix assignment is
an unquoted NAME, NAME[SUBSCRIPT], += or = (`"X=1" cmd` and `X\\=1 cmd` run the program `X=1`), and a keyword is one
only before it (`X=1 if cmd` runs `if`); env takes any word holding `=`. A `case` subject and its patterns (after `in`,
`;;`, `;&`, `;;&`, a leading `(` and each `|`) are no commands, and a pattern's `)` does not close a `$(..)`. An
arithmetic command `(( .. ))` (also a `for (( .. ))` header) and a conditional `[[ .. ]]` are expressions: their
operators split nothing and their words run nothing (only their substitutions, reported nested). `coproc`, and a program
word bash expands (a brace expansion, a glob), may run a program the words do not name. A heredoc terminator is an exact
line for `<<`, leading tabs stripped for `<<-`; several heredocs on one line take their bodies in order.
"""
from __future__ import annotations

import re
from typing import NamedTuple

import shell_tree  # the shared parser (tests/shell_tree.py): what an expansion's body runs is read from its tree

# Longest first: the first operator in this list that matches at a position is the one read there.
_OPERATORS = ("<<<", "<<-", "<<", "<&", "<>", "<", ">>", "&>>", "&>", ">&", ">|", ">", "&&", "&", "||", "|&", "|",
              ";;&", ";;", ";&", ";", "(", ")")
_REDIRECTS = {"<<<", "<<-", "<<", "<&", "<>", "<", ">>", "&>>", "&>", ">&", ">|", ">"}
_HEREDOCS = {"<<", "<<-"}
# Words a simple command may start with before the program it runs.
_KEYWORDS = {"if", "elif", "while", "until", "!", "then", "else", "do", "{", "}"}
# Programs that run what their arguments name (or evaluate text), so the commands they run are not in the words.
_RUNS_ARGUMENTS = {"eval", "source", ".", "xargs", "find", "watch", "flock", "su", "ssh", "trap", "parallel",
                   "chroot"}


class _Wrapper(NamedTuple):
    """Which operand of a wrapper runs as the program. Options are read one by one: a flag in `flags` is skipped,
    one in `values` takes a value (joined, `-n5` / `--adjustment=5`, or the next word), one in `no_run` means the
    operand is not run (`command -v x`). Any other option, or an option word holding an expansion, leaves the
    program unknown: the command may run anything and is not certain. `--` ends the options."""
    flags: frozenset[str] = frozenset()
    values: frozenset[str] = frozenset()
    no_run: frozenset[str] = frozenset()
    # NAME=VALUE words before the program: "env" takes any word with `=` (env(1) splits at the first one), "bash" takes
    # what bash takes as a prefix assignment (the `time` keyword); "" takes none.
    assignments: str = ""
    operands_before: int = 0  # operands before the program (timeout's DURATION)
    numeric: bool = False  # `-N` is an option (nice -10)
    # The program certainly starts, as itself, in this directory, when bash reaches the command. False where the
    # wrapper may refuse, defer, kill or relocate it (sudo, timeout, setsid's fork, builtin's builtins-only).
    certain: bool = True


def _options(*names: str) -> frozenset[str]:
    return frozenset(names)


# One table for every wrapper; tests/test_shell_invocations.py runs each certain one in real bash.
_WRAPPERS: dict[str, _Wrapper] = {
    "env": _Wrapper(flags=_options("-i", "--ignore-environment", "-0", "--null", "-v", "--debug"),
                    values=_options("-u", "--unset"), assignments="env"),
    "nice": _Wrapper(values=_options("-n", "--adjustment"), numeric=True),
    "nohup": _Wrapper(),
    "stdbuf": _Wrapper(values=_options("-i", "-o", "-e", "--input", "--output", "--error")),
    "command": _Wrapper(flags=_options("-p"), no_run=_options("-v", "-V")),
    "exec": _Wrapper(flags=_options("-c", "-l"), values=_options("-a")),
    "time": _Wrapper(flags=_options("-p"), assignments="bash"),
    "timeout": _Wrapper(flags=_options("--preserve-status", "--foreground", "-v", "--verbose"),
                        values=_options("-s", "--signal", "-k", "--kill-after"), operands_before=1, certain=False),
    "sudo": _Wrapper(flags=_options("-E", "-H", "-n", "-P", "-S", "-A", "-N", "--preserve-env", "--set-home",
                                    "--non-interactive", "--preserve-groups", "--stdin", "--askpass"),
                     values=_options("-u", "-g", "-p", "-r", "-t", "-T", "-C", "-h", "--user", "--group",
                                     "--prompt", "--role", "--type", "--command-timeout", "--close-from", "--host"),
                     no_run=_options("-l", "-v", "-k", "-K", "-V", "--list", "--validate"), certain=False),
    "setsid": _Wrapper(flags=_options("-c", "--ctty", "-f", "--fork", "-w", "--wait"), certain=False),
    "ionice": _Wrapper(flags=_options("-t", "--ignore"), values=_options("-c", "--class", "-n", "--classdata"),
                       certain=False),
    "builtin": _Wrapper(certain=False),
}
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish"}
# Shell options that keep "run the first operand as a script": the rest (-c text, -s stdin, -i interactive,
# -n noexec, -t one command, -r restricted, -l login profile, -D, -o/-O NAME, --rcfile FILE ...) are uncertain.
_SHELL_FLAGS = frozenset("abefhkmpuvxBCEHPT")
_SHELL_LONG_FLAGS = frozenset({"--noprofile", "--norc", "--posix", "--noediting", "--verbose"})
# A prefix assignment as bash reads it: NAME, NAME[SUBSCRIPT] (bash 5.2 refuses the subscript but still runs the
# command), then = or +=. NAME, `[` and `=` must be unquoted: _is_assignment checks that against Token.plain.
_ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)(\[.*?\])?\+?=", re.DOTALL)
# What bash expands in a program word: a brace expansion and a glob may name a program the text does not.
_BRACE_EXPANSION = re.compile(r"\{[^{}]*(,|\.\.)[^{}]*\}")
_GLOB = re.compile(r"[*?]|\[[^\]]+\]")
_ARRAY_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=$")
_FUNCTION_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_.:@-]*$")
_SPACE = " \t"
_DOUBLE_ESCAPES = '"\\$`'
_DOLLAR_NAME = re.compile(r"[A-Za-z_0-9@*#?$!-]")


class Token(NamedTuple):
    kind: str  # "word", "op" or "nl"
    text: str
    quoted: bool = False  # a word with any quoted or escaped part
    start: int = 0
    end: int = 0
    dynamic: bool = False  # the word holds an expansion bash resolves at run time ($x, ${..}, $(..), `..`, <(..))
    subs: tuple[str, ...] = ()  # the scripts of its command and process substitutions
    plain: int = 0  # how many leading characters of text are unquoted, unescaped literals (an assignment's NAME=)


class Lexed(NamedTuple):
    tokens: list[Token]
    complete: bool  # False: the lexer stopped at something it could not finish; later text is unread
    heredoc_subs: list[str]  # scripts of `$(..)` and backticks in unquoted heredoc bodies and arithmetic commands


class Invocation(NamedTuple):
    words: list[str]  # the program first (a leading `./` dropped), then its arguments; [] for an unlexable tail
    certain: bool  # nothing in or before the command is beyond the lexer
    any_program: bool  # it may also run programs the words do not name


_CASE_WORD = re.compile(r"(case|in|esac)(?=[ \t\n;&|()<>]|$)")


def _match_close(text: str, index: int, opener: str) -> int | None:
    """The index just past the `)` or `}` closing the construct whose opener (`$(`, `<(`, `>(`, `${`, or `((` for an
    arithmetic command) starts at `index`; None if it never closes. Quotes and nested brackets are skipped, and so
    are a `case` clause's parens (`$(case x in y) cmd ;; esac)`: the pattern's `)` closes nothing)."""
    close = "}" if opener == "${" else ")"
    depth = 1
    i = index + (1 if opener == "((" else len(opener))
    cases: list[str] = []  # per open `case`: "head" until `in`, "pattern" until its `)`, then "body"
    while i < len(text):
        if close == ")" and (i == 0 or text[i - 1] in " \t\n;&|()<>"):
            word = _CASE_WORD.match(text, i)
            if word is not None:
                name = word.group(1)
                if name == "case" and (not cases or cases[-1] != "pattern") and _case_starts(text, i):
                    cases.append("head")
                elif name == "in" and cases and cases[-1] == "head":
                    cases[-1] = "pattern"
                elif name == "esac" and cases and cases[-1] != "head":
                    cases.pop()
                i = word.end()
                continue
        if cases and cases[-1] == "pattern" and text[i] == ")":
            cases[-1] = "body"
            i += 1
            continue
        if cases and cases[-1] == "pattern" and text[i] == "(":
            i += 1  # a pattern list's optional leading paren
            continue
        if cases and cases[-1] == "body" and text.startswith((";;", ";&"), i):
            cases[-1] = "pattern"
            i += 3 if text.startswith(";;&", i) else 2
            continue
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            end = text.find("'", i + 1)
            if end < 0:
                return None
            i = end + 1
            continue
        if c == '"':
            i += 1
            while i < len(text) and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            if i >= len(text):
                return None
            i += 1
            continue
        if text.startswith(("$(", "<(", ">("), i) and close == ")":
            depth += 1
            i += 2
            continue
        if text.startswith("${", i) and close == "}":
            depth += 1
            i += 2
            continue
        # A substitution inside a parameter expansion (`${x:-$(a)}`), or a parameter expansion inside a substitution
        # (`$(echo ${x:-)})`), closes on its own bracket: a `)` or `}` in it does not close this one.
        if text.startswith("$(", i) and close == "}" or text.startswith("${", i) and close == ")":
            end = _match_close(text, i, text[i:i + 2])
            if end is None:
                return None
            i = end
            continue
        if c == "`" and close == "}":
            end = _backtick_close(text, i)
            if end is None:
                return None
            i = end
            continue
        if c == "(" and close == ")":
            depth += 1
        elif c == close:
            depth -= 1
            if depth == 0:
                return None if cases else i + 1
        i += 1
    return None


def _arithmetic_end(text: str, index: int) -> int | None:
    """The index past the `))` closing the arithmetic command whose `((` starts at `index`; None if it is not one."""
    end = _match_close(text, index, "((")
    return end if end is not None and text.startswith("))", end - 2) else None


def _case_starts(text: str, index: int) -> bool:
    """Whether the word `case` at `index` starts a command: first in the text, after an operator or newline, or after
    a keyword (`then case ..`)."""
    before = text[:index].rstrip(" \t")
    if not before or before[-1] in ";&|()\n":
        return True
    return re.search(r"(?:^|[ \t\n;&|()])(?:if|elif|while|until|then|else|do|!|\{)$", before) is not None


def _backtick_close(text: str, index: int) -> int | None:
    i = index + 1
    while i < len(text):
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == "`":
            return i + 1
        i += 1
    return None


def _backtick_script(body: str) -> str:
    """The script a backtick substitution runs: inside backticks a backslash before $, ` or another backslash is
    removed first, so `` `echo \\$(a)` `` runs $(a)."""
    return re.sub(r"\\([$`\\])", r"\1", body)


def _arithmetic_body(text: str) -> str | None:
    """The body of a ``$((..))`` or legacy ``$[..]`` arithmetic expansion, or None for another expansion."""
    if text.startswith("$(("):
        return text[3:-2]
    if text.startswith("$["):
        return text[2:-1]
    return None


def _legacy_arithmetic_subs(text: str) -> list[str] | None:
    """The substitutions inside every legacy `$[ ]` arithmetic expansion in TEXT, including one nested in a
    parameter expansion that shell_tree reads as literal text."""
    found: list[str] = []
    at = 0
    while True:
        at = text.find("$[", at)
        if at < 0:
            return found
        end = _bracket_close(text, at)
        if end is None:
            return None
        inner = _body_subs(text[at + 2:end - 1])
        if inner is None:
            return None
        found.extend(script for script in inner if script not in found)
        at = end


def _tree_subs(source: str, words: list) -> list[str] | None:
    """The scripts of the command and process substitutions in WORDS (shell_tree Words of SOURCE), at any depth of
    parameter expansion, arithmetic and array subscript; one inside another is in its outer script. None when a
    ${..@P} (prompt expansion, which runs the substitutions in a variable's value) is among them."""
    found: list[str] = []
    for word in words:
        if word is None:
            continue
        legacy = _legacy_arithmetic_subs(source[word.start:word.end])
        if legacy is None:
            return None
        found.extend(script for script in legacy if script not in found)
        for sub in shell_tree.subs(word.parts):
            if sub.form == "`":
                found.append(_backtick_script(source[sub.start + 1:sub.end - 1]))
            else:
                found.append(source[sub.start + 2:sub.end - 1])
        for part in _expansions(word.parts):
            if isinstance(part, shell_tree.Param) and re.search(r"@P\}$", source[part.start:part.end]):
                return None
            # bash reads an arithmetic body as double-quoted text, wherever the $(( )) or $[ ] is; shell_tree reads
            # a ${ } inside one unquoted, so `$(( ${x:-'$(a)'} ))` is read again as bash does (a shorter text each time).
            if isinstance(part, shell_tree.Arith):
                body = _arithmetic_body(source[part.start:part.end])
                if body is None:
                    continue
                inner = _body_subs(body)
                if inner is None:
                    return None
                found.extend(script for script in inner if script not in found)
    return found


def _expansions(parts: list):
    for part in parts:
        if isinstance(part, (shell_tree.Param, shell_tree.Arith)):
            yield part
            yield from _expansions(part.parts)


def _expansion_subs(text: str, in_double: bool) -> list[str] | None:
    """The scripts of the substitutions a `${..}`, `$((..))` or `$[..]` expansion (TEXT, whole) may run, read by shell_tree.
    Both readings count, because a context this lexer does not track can change which applies: unquoted, and as
    bash reads it inside double quotes or arithmetic, where a ${ }'s single quote is literal (`(( ${x:-'`a`'} ))`
    runs a). An arithmetic body is also read the way bash reads it, as double-quoted text. None when either reading
    fails: the caller then stops, so whatever follows may run anything (fail closed)."""
    found = _read_expansion(text, in_double)
    arithmetic_body = _arithmetic_body(text)
    other = _body_subs(arithmetic_body) if arithmetic_body is not None else _read_expansion(text, not in_double)
    if found is None or other is None:
        return None
    return found + [script for script in other if script not in found]


def _read_expansion(text: str, in_double: bool) -> list[str] | None:
    source = f'"{text}"' if in_double else text
    try:
        script = shell_tree.parse(source)
    except shell_tree.Unparsed:
        return None
    if len(script.commands) != 1 or len(script.commands[0].words) != 1 or script.commands[0].redirects:
        return None
    return _tree_subs(source, script.commands[0].words)


def _body_subs(body: str) -> list[str] | None:
    """The scripts of the substitutions an unquoted heredoc body expands, at any depth of expansion, read by
    shell_tree as a here-document; None if it cannot read one."""
    lines = body.split("\n")
    delimiter = "SHELL_INVOCATIONS_EOF"
    while delimiter in lines:
        delimiter += "_"
    source = f": <<{delimiter}\n{body}\n{delimiter}\n"
    try:
        script = shell_tree.parse(source)
    except shell_tree.Unparsed:
        return None
    return _tree_subs(source, [redirect.body for command in script.commands for redirect in command.redirects])


def _bracket_close(text: str, index: int) -> int | None:
    """The index just past the `]` closing the `$[` at `index`; None if it never closes. Substitutions and parameter
    expansions inside are skipped whole."""
    depth = 1
    i = index + 2
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if text.startswith(("$(", "${"), i):
            end = _match_close(text, i, text[i:i + 2])
            if end is None:
                return None
            i = end
            continue
        if c == "`":
            end = _backtick_close(text, i)
            if end is None:
                return None
            i = end
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def _skip_heredoc_bodies(text: str, index: int, pending: list[tuple[str, bool, bool]],
                         subs: list[str]) -> tuple[int, bool]:
    """The index after the bodies of every pending heredoc, read in order from the line starting at `index`; False
    when a body never reaches its terminator or expands something the lexer cannot read."""
    ok = True
    for delimiter, strip_tabs, expands in pending:
        body: list[str] = []
        closed = False
        while index < len(text):
            newline = text.find("\n", index)
            line = text[index:] if newline < 0 else text[index:newline]
            index = len(text) if newline < 0 else newline + 1
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                closed = True
                break
            body.append(line)
        ok = ok and closed
        if expands:
            found = _body_subs("\n".join(body))
            if found is None:
                ok = False
            else:
                subs.extend(found)
    return index, ok


def lex(text: str) -> Lexed:
    tokens: list[Token] = []
    heredoc_subs: list[str] = []
    pending: list[tuple[str, bool, bool]] = []  # (delimiter, strip tabs, body expands)
    expect_delimiter: bool | None = None  # the <<- flag after a heredoc operator, until its word arrives
    buf: list[str] = []
    subs: list[str] = []
    quoted = False
    dynamic = False
    in_word = False
    word_start = 0
    plain = 0  # the unquoted literal prefix of the word being read
    plain_open = True  # nothing quoted, escaped or expanded yet in it
    i = 0

    def start_word(at: int) -> None:
        nonlocal in_word, word_start
        if not in_word:
            in_word, word_start = True, at

    def end_word(at: int) -> None:
        nonlocal buf, subs, quoted, dynamic, in_word, expect_delimiter, plain, plain_open
        if not in_word:
            return
        word = "".join(buf)
        if expect_delimiter is not None:
            pending.append((word, expect_delimiter, not quoted))
            expect_delimiter = None
        tokens.append(Token("word", word, quoted, word_start, at, dynamic, tuple(subs), plain))
        buf, subs, quoted, dynamic, in_word = [], [], False, False, False
        plain, plain_open = 0, True

    def command_starts() -> bool:
        """Whether a word here would be the first of a command (where `((` opens an arithmetic command)."""
        if in_word:
            return False
        if not tokens:
            return True
        last = tokens[-1]
        if last.kind == "nl":
            return True
        if last.kind == "op":
            return last.text not in _REDIRECTS
        return not last.quoted and last.text in _KEYWORDS | {"for", "time"}

    def expansion(at: int, in_double: bool) -> int | None:
        """Read the expansion starting at `$` or a backtick at `at`; return the index after it, or None when it
        never closes (the lexer stops there)."""
        nonlocal dynamic
        if text[at] == "`":
            end = _backtick_close(text, at)
            if end is None:
                return None
            dynamic = True
            subs.append(_backtick_script(text[at + 1:end - 1]))
            buf.append("\x00")
            return end
        if text.startswith("$((", at):
            end = _match_close(text, at, "$(")
            if end is None:
                return None
            # `$(( $(a) + 1 ))` runs `a` (#41398 review F1): the substitutions inside arithmetic are commands.
            inner = _expansion_subs(text[at:end], in_double)
            if inner is None:
                return None
            subs.extend(inner)
            dynamic = True
            buf.append("\x00")
            return end
        if text.startswith("$(", at):
            end = _match_close(text, at, "$(")
            if end is None:
                return None
            dynamic = True
            subs.append(text[at + 2:end - 1])
            buf.append("\x00")
            return end
        if text.startswith("${", at):
            end = _match_close(text, at, "${")
            if end is None:
                return None
            # `${x:-$(a)}` runs `a` (#41133 review F2), and so does `${x:-$(( $(a) ))}` or `${arr[$(a)]}` (#41398
            # review F1): every substitution inside a parameter expansion, at any depth, is a command.
            inner = _expansion_subs(text[at:end], in_double)
            if inner is None:
                return None
            subs.extend(inner)
            dynamic = True
            buf.append(text[at:end])
            return end
        if text.startswith("$[", at):
            # `$[ .. ]`, bash's old arithmetic, reads its body as double-quoted text: its substitutions run whatever
            # quotes surround them. The words go on to be read as usual too.
            end = _bracket_close(text, at)
            inner = None if end is None else _body_subs(text[at + 2:end - 1])
            if inner is None:
                return None
            subs.extend(inner)
            dynamic = True
        if _DOLLAR_NAME.match(text[at + 1:at + 2] or " "):
            dynamic = True
        buf.append("$")
        return at + 1

    while i < len(text):
        c = text[i]
        if c == "\\":
            if text[i + 1:i + 2] == "\n":
                i += 2
                continue
            if i + 1 >= len(text):
                return Lexed(tokens, False, heredoc_subs)
            start_word(i)
            buf.append(text[i + 1])
            quoted = True
            plain_open = False
            i += 2
        elif c == "'":
            close = text.find("'", i + 1)
            if close < 0:
                return Lexed(tokens, False, heredoc_subs)
            start_word(i)
            buf.append(text[i + 1:close])
            quoted = True
            plain_open = False
            i = close + 1
        elif c == '"':
            start_word(i)
            quoted = True
            plain_open = False
            i += 1
            while True:
                if i >= len(text):
                    return Lexed(tokens, False, heredoc_subs)
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
                if text[i] in "$`":
                    after = expansion(i, True)
                    if after is None:
                        return Lexed(tokens, False, heredoc_subs)
                    i = after
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
                i, closed = _skip_heredoc_bodies(text, i, pending, heredoc_subs)
                pending.clear()
                if not closed:
                    return Lexed(tokens, False, heredoc_subs)
        elif c in "$`":
            start_word(i)
            plain_open = False
            after = expansion(i, False)
            if after is None:
                return Lexed(tokens, False, heredoc_subs)
            i = after
        elif c in "<>" and text.startswith("(", i + 1):
            start_word(i)
            plain_open = False
            end = _match_close(text, i, c + "(")
            if end is None:
                return Lexed(tokens, False, heredoc_subs)
            dynamic = True
            subs.append(text[i + 2:end - 1])
            buf.append("\x00")
            i = end
        elif text.startswith("((", i) and command_starts() and (end := _arithmetic_end(text, i)) is not None:
            # `(( expr ))` and `for (( a; b; c ))`: an arithmetic expression, no commands and no redirections (`<<`
            # is a shift, not a heredoc). Only its substitutions run; they are reported nested. A `((` that does not
            # close as `))` is two subshells, as bash reads it.
            inside = _expansion_subs("$" + text[i:end], False)
            if inside is None:
                return Lexed(tokens, False, heredoc_subs)
            heredoc_subs.extend(inside)
            tokens.append(Token("op", "((", False, i, end))
            i = end
        elif c in ";&|()<>":
            end_word(i)
            if text.startswith("((", i):
                # An arithmetic command `(( .. ))` or `for (( .. ))` reads its body as double-quoted text, so a
                # substitution inside runs whatever quotes surround it; its words are read as usual too.
                end = _match_close(text, i, "$(")
                if end is not None and text[end:end + 1] == ")":
                    inner = _body_subs(text[i + 2:end - 1])
                    if inner is None:
                        return Lexed(tokens, False, heredoc_subs)
                    heredoc_subs.extend(inner)
            operator = next(op for op in _OPERATORS if text.startswith(op, i))
            if operator in _HEREDOCS:
                expect_delimiter = operator == "<<-"
            tokens.append(Token("op", operator, False, i, i + len(operator)))
            i += len(operator)
        else:
            start_word(i)
            buf.append(c)
            if plain_open:
                plain += 1
            i += 1
    end_word(len(text))
    return Lexed(tokens, not pending and expect_delimiter is None, heredoc_subs)


class _Command(NamedTuple):
    words: list[Token]
    dynamic: bool  # some word, or a redirection target, holds a substitution or expansion
    nested: bool  # it runs inside a substitution
    reached: bool = False  # bash runs it whenever the script runs to its end (_Flow); False unless shown
    stdin: bool = False  # input redirection may feed executable content to an interpreter


# Compound commands: the keyword that opens one, and the one that closes it.
_OPENS = {"if": "fi", "while": "done", "until": "done", "for": "done", "arith_for": "done",
          "select": "done", "case": "esac"}
_CLOSES = {"fi", "done", "esac"}
# A command after which bash runs nothing more of the script (`exec` only with a program to run).
_ENDS = {"exit", "return"}


class _Frame:
    """One open construct: the top level, a `{ }` group, a `( )` subshell or a compound command."""

    def __init__(self, kind: str, entered: bool, part: str = "") -> None:
        self.kind = kind  # "top", "{", "(", or an opening keyword of _OPENS
        self.entered = entered  # bash surely reaches the construct itself
        self.part = part  # in an `if`: "cond" (the first condition) or "branch"; in a loop or case: "body"
        self.after_and_or = False  # a `&&` or `||` came before, in this list: the rest may be skipped


class _Flow:
    """Whether bash surely reaches each top-level command, read off the keywords and operators between them. It fails
    closed: anything it cannot place (an unpaired closing keyword, an `exit`) makes every later command unreached."""

    def __init__(self) -> None:
        self.frames = [_Frame("top", True)]
        self.lost = False  # an exit, return or exec PROGRAM ran, or the structure could not be followed

    def reached(self) -> bool:
        if self.lost:
            return False
        for frame in self.frames:
            if not frame.entered or frame.after_and_or:
                return False
            if frame.kind in _OPENS and frame.kind != "arith_for" and not (frame.kind == "if" and frame.part == "cond"):
                return False
        return True

    def keywords(self, words: list[Token]) -> int:
        """Read the keywords that start a command (pushing and popping constructs); the index of its first other word."""
        index = 0
        while index < len(words) and not words[index].quoted:
            text = words[index].text
            top = self.frames[-1]
            if text in _OPENS:
                if text == "if":
                    self.frames.append(_Frame("if", self.reached(), "cond"))
                else:
                    self.frames.append(_Frame(text, False, "body"))
                index += 1
                if text in ("for", "select", "case"):
                    return len(words)  # `for x in ...`, `case $x in pattern`: no command in the header
                continue
            if text in ("then", "elif", "else"):
                if top.kind != "if":
                    self.lost = True
                else:
                    top.part = "branch"
                    top.after_and_or = False
            elif text == "do":
                if top.kind not in ("while", "until", "for", "arith_for", "select"):
                    self.lost = True
            elif text in _CLOSES:
                if _OPENS.get(top.kind) != text:
                    self.lost = True
                else:
                    self.frames.pop()
            elif text == "{":
                self.frames.append(_Frame("{", self.reached()))
            elif text == "}":
                if top.kind != "{":
                    self.lost = True
                else:
                    self.frames.pop()
            elif text == "function":
                # A function's body runs only where it is called: fail closed, nothing after it is reached.
                self.lost = True
                index += 2
                continue
            elif text != "!":
                break
            index += 1
        return index

    def ended(self, words: list[Token], start: int) -> None:
        """After a command: an exit, return or exec PROGRAM there may end the script, so every command after it is
        unreached. One exception: an `exit N` bash may skip (`test -n "$X" || exit 1`) with N a literal nonzero
        status ends only a run that fails, and a credit holds for a run that succeeds."""
        rest = [word for word in words[start:] if not _ASSIGNMENT.match(word.text)]
        if not rest or rest[0].quoted:
            return
        name = rest[0].text
        if name == "exit" and not self.reached() and len(rest) == 2 and not rest[1].quoted and not rest[1].dynamic \
                and rest[1].text.isdigit() and int(rest[1].text) % 256 != 0:
            return
        if name in _ENDS or (name == "exec" and len(rest) > 1):
            self.lost = True

    def operator(self, text: str, starts_command: bool) -> None:
        top = self.frames[-1]
        if text in ("&&", "||"):
            top.after_and_or = True
        elif text in (";", "&", "\n", ";;", ";&", ";;&"):
            top.after_and_or = False
        elif text == "((":
            if top.kind == "for":
                top.kind = "arith_for"
                top.entered = True
        elif text == "(":
            if top.kind == "case":
                return  # a pattern's optional `(`
            if starts_command:
                self.frames.append(_Frame("(", self.reached()))
            else:
                self.lost = True  # a function's `name ( )`, or something not read here
        elif text == ")":
            if top.kind == "case":
                return  # a pattern's `)`
            if top.kind == "(":
                self.frames.pop()
            else:
                self.lost = True


def _commands(run: str, nested: bool, defined: set[str]) -> tuple[list[_Command], bool]:
    """Each simple command's words (operators that end a command split it; redirections and their targets drop
    out), with those of every substitution after it; False if the lexer stopped early."""
    lexed = lex(run)
    found: list[_Command] = []
    inner: list[_Command] = []
    complete = lexed.complete
    words: list[Token] = []
    dynamic = False
    stdin = False
    skip_target = False
    previous: Token | None = None
    tokens = lexed.tokens
    in_array = 0  # depth inside `name=( .. )`: its elements are values, not commands
    flow = _Flow()
    joined = False  # the last operator was `&&`, `||` or `|`: a newline after it continues the list

    # Per open `case`: "subject" (its word), "in", "pattern" (a pattern list up to its `)`), "body" (commands).
    cases: list[str] = []
    case_subjects: list[str | None] = []
    case_pattern_matches: list[bool] = []
    case_body_active: list[bool] = []
    case_fallthrough: list[bool] = []
    in_conditional = False  # inside `[[ .. ]]`: an expression, its operators split nothing

    def case_reached() -> bool:
        return all(case_body_active)

    def close(command_words: list[Token], command_dynamic: bool, command_stdin: bool) -> None:
        # The keywords that open, continue or close a construct (and a `for`/`case` header) are no command.
        start = flow.keywords(command_words)
        if start < len(command_words):
            found.append(_Command(command_words[start:], command_dynamic, nested,
                                  not nested and flow.reached() and case_reached(), command_stdin))
        flow.ended(command_words, start)

    def at_command_start() -> bool:
        return all(word.text in _KEYWORDS and not word.quoted for word in words) and not skip_target

    def nested_subs(token: Token) -> None:
        nonlocal complete
        for sub in token.subs:
            commands, ok = _commands(sub, True, defined)
            inner.extend(commands)
            complete = complete and ok

    for index, token in enumerate(tokens):
        if in_conditional:
            if token.kind == "word" and token.text == "]]" and not token.quoted:
                in_conditional = False
                words, dynamic, stdin = [], False, False
            elif token.kind == "word":
                nested_subs(token)  # `[[ $(cmd) ]]` runs cmd, unless an operator short-cuts it: nested
            previous = token
            continue
        if cases and cases[-1] != "body":
            state = cases[-1]
            if token.kind == "nl":
                pass
            elif state == "subject" and token.kind == "word":
                nested_subs(token)
                case_subjects[-1] = token.text
                cases[-1] = "in"
            elif state == "in" and token.kind == "word" and token.text == "in" and not token.quoted:
                case_pattern_matches[-1] = False
                cases[-1] = "pattern"
            elif state == "pattern" and token.kind == "word" and token.text == "esac" and not token.quoted \
                    and previous is not None and (previous.kind == "nl" or previous.text in ("in", ";;", ";&", ";;&")):
                cases.pop()
                case_subjects.pop()
                case_pattern_matches.pop()
                case_body_active.pop()
                case_fallthrough.pop()
            elif state == "pattern" and token.kind == "word":
                nested_subs(token)  # a pattern's substitution runs only when bash reaches the pattern: nested
                case_pattern_matches[-1] |= token.text == case_subjects[-1]
            elif state == "pattern" and token.kind == "op" and token.text in ("(", "|"):
                pass
            elif state == "pattern" and token.kind == "op" and token.text == ")":
                case_body_active[-1] = case_fallthrough[-1] or case_pattern_matches[-1]
                cases[-1] = "body"
            else:
                complete = False  # bash refuses this case: what follows is unread
                break
            previous = token
            continue
        if token.kind == "word" and not token.quoted and at_command_start() \
                and token.text in ("case", "esac", "[["):
            if words:
                flow.keywords(words)
                words, dynamic, stdin = [], False, False
            if token.text == "[[":
                in_conditional = True
                words, dynamic, stdin = [], False, False
                previous = token
                continue
            if token.text == "case":
                cases.append("subject")
                case_subjects.append(None)
                case_pattern_matches.append(False)
                case_body_active.append(False)
                case_fallthrough.append(False)
                words, dynamic, stdin = [], False, False
                previous = token
                continue
            if token.text == "esac" and cases:
                cases.pop()
                case_subjects.pop()
                case_pattern_matches.pop()
                case_body_active.pop()
                case_fallthrough.pop()
                words, dynamic, stdin = [], False, False
                previous = token
                continue
        if cases and token.kind == "op" and token.text in (";;", ";&", ";;&"):
            if words:
                close(words, dynamic, stdin)
            words, dynamic, stdin, skip_target = [], False, False, False
            cases[-1] = "pattern"
            case_pattern_matches[-1] = False
            case_fallthrough[-1] = token.text == ";&" and case_body_active[-1]
            case_body_active[-1] = False
            previous = token
            continue
        if in_array:
            if token.kind == "op" and token.text == "(":
                in_array += 1
            elif token.kind == "op" and token.text == ")":
                in_array -= 1
            elif token.kind == "word":
                for sub in token.subs:
                    commands, ok = _commands(sub, True, defined)
                    inner.extend(commands)
                    complete = complete and ok
                dynamic = dynamic or bool(token.subs)
            continue
        if token.kind == "op" and token.text == "(" and previous is not None and previous.kind == "word" \
                and previous.end == token.start and not previous.quoted and _ARRAY_ASSIGNMENT.match(previous.text) \
                and words and words[-1] is previous:
            in_array = 1
            continue
        if token.kind == "word":
            for sub in token.subs:
                commands, ok = _commands(sub, True, defined)
                inner.extend(commands)
                complete = complete and ok
            dynamic = dynamic or bool(token.subs)
            if skip_target:
                skip_target = False
            else:
                words.append(token)
                # `name ( )` defines a function, `function name` and `alias name=..` define one too.
                if index + 2 < len(tokens) and tokens[index + 1].text == "(" and tokens[index + 2].text == ")" \
                        and tokens[index + 1].kind == "op" and _FUNCTION_NAME.match(token.text) \
                        and not _ARRAY_ASSIGNMENT.match(token.text):
                    defined.add(token.text)
                if len(words) >= 2 and words[-2].text == "function" and not words[-2].quoted:
                    defined.add(token.text)
                if len(words) >= 2 and words[-2].text == "alias" and not words[-2].quoted:
                    defined.add(token.text.split("=", 1)[0])
        elif token.kind == "op" and token.text in _REDIRECTS:
            # `2>/dev/null`: the file descriptor number written against the operator is no word.
            if words and words[-1] is previous and previous.end == token.start and not previous.quoted \
                    and previous.text.isdigit():
                words.pop()
            stdin = stdin or token.text in {"<", "<<", "<<-", "<<<", "<&"}
            skip_target = True
        else:
            skip_target = False
            starts_command = not words
            if words:
                close(words, dynamic, stdin)
            words, dynamic, stdin = [], False, False
            if token.kind == "nl":
                if not joined:
                    flow.operator("\n", starts_command)
            else:
                flow.operator(token.text, starts_command)
            joined = token.kind == "op" and token.text in ("&&", "||", "|", "|&")
        if token.kind == "word":
            joined = False
        previous = token
    if words:
        close(words, dynamic or not lexed.complete, stdin)  # a command cut short is not certain
    if cases or in_conditional:
        complete = False  # an unclosed `case` or `[[`: bash refuses the script
    for sub in lexed.heredoc_subs:
        commands, ok = _commands(sub, True, defined)
        inner.extend(commands)
        complete = complete and ok
    return found + inner, complete


def _opaque(word: Token) -> bool:
    """The word's text is not what bash runs: an expansion, a brace expansion or a glob (fail closed on a quoted `*`
    too: a quoted one is rare in a program word, and reading it as a glob only costs certainty)."""
    return word.dynamic or "\x00" in word.text or bool(_BRACE_EXPANSION.search(word.text) or _GLOB.search(word.text))


def _is_assignment(word: Token) -> bool:
    """Whether bash takes the word as a prefix assignment: NAME, `[` and `=` unquoted (`"X=1" cmd` runs X=1)."""
    match = _ASSIGNMENT.match(word.text)
    if match is None:
        return False
    if match.group(2) is None:
        return word.plain >= match.end()
    return word.plain > len(match.group(1))  # `X["k y"]=v`: the subscript may be quoted, NAME[ may not


def _program_name(text: str) -> str:
    """The name a program word is matched on: an absolute path by its basename (`/usr/bin/env` is env, `/bin/bash`
    is bash); anything else as written (`./bash` is a script of that name, not the shell)."""
    return text.rsplit("/", 1)[-1] if text.startswith("/") else text


# An option that hands a program its command as text, as a shell's -c does: on an absolute program this does not
# know, the program may run anything.
_TEXT_OPTION = re.compile(r"-[A-Za-z]*c")
_INTERPRETER_NAMES = frozenset({
    "node", "nodejs", "perl", "ruby", "php", "pwsh", "powershell", "deno", "bun", "lua", "luajit",
    "fish", "csh", "tcsh", "ash", "busybox", "tclsh", "wish", "gjs", "qjs", "quickjs", "osascript",
})
_INLINE_CODE_OPTIONS = frozenset({"-c", "-e", "-E", "-r", "--eval", "--execute", "--command"})


def _is_interpreter(name: str) -> bool:
    return name in _INTERPRETER_NAMES or name.startswith(("python", "pypy", "perl", "ruby", "php"))


def _has_inline_interpreter_code(name: str, args: list[Token], stdin: bool) -> bool:
    """Whether an interpreter is being handed executable text or input we cannot inspect."""
    if not _is_interpreter(name) or name in _SHELLS:
        return False
    if stdin or any(word.text == "-" for word in args):
        return True
    for word in args:
        text = word.text
        if text in _INLINE_CODE_OPTIONS or text.startswith(("--eval=", "--execute=", "--command=")):
            return True
        if text.startswith("-") and not text.startswith("--") and any(option in text[1:] for option in "ceEr"):
            return True
    return False


def _unwrap(words: list[Token], index: int, wrapper: _Wrapper) -> tuple[int | None, bool]:
    """The index of the program `words[index]` (a wrapper) runs, and whether it runs it for certain; None when the
    options leave the program unknown or say nothing runs."""
    i = index + 1
    while i < len(words):
        word = words[i]
        text = word.text
        if _opaque(word):
            return None, False
        if text == "--":
            i += 1
            break
        if not text.startswith("-") or text == "-":
            break
        if wrapper.numeric and re.fullmatch(r"-[0-9]+", text):
            i += 1
            continue
        if text.startswith("--"):
            name, joined = text.split("=", 1)[0], "=" in text
            if name in wrapper.no_run:
                return None, False
            if name in wrapper.values:
                i += 1 if joined else 2
                continue
            if name in wrapper.flags:
                i += 1
                continue
            return None, False
        taken = False
        for at, letter in enumerate(text[1:], start=1):
            option = "-" + letter
            if option in wrapper.no_run:
                return None, False
            if option in wrapper.values:
                taken = at == len(text) - 1  # `-u NAME`: the value is the next word; `-uNAME`: the rest
                break
            if option not in wrapper.flags:
                return None, False
        i += 2 if taken else 1
    while i < len(words) and (wrapper.assignments == "env" and "=" in words[i].text
                              or wrapper.assignments == "bash" and _is_assignment(words[i])):
        if wrapper.assignments == "env" and _opaque(words[i]):
            return None, False  # env's word is expanded (a glob in `Y[0]=2`) before env reads it
        i += 1
    for _ in range(wrapper.operands_before):
        if i >= len(words) or _opaque(words[i]):
            return None, False
        i += 1
    return i, wrapper.certain


def _shell_script(words: list[Token], index: int) -> tuple[int | None, bool]:
    """The index of the script a shell (`words[index]`) runs as its first operand, and whether that is certain.
    None when it runs text or stdin instead (-c, -s, no operand), so it may run anything. A mode this does not
    model as "run the script" (-n, -i, -t, -o NAME, --rcfile FILE ...) keeps the operand but is not certain, and
    may run any program. `--` or `-` ends the options: the next word is the script."""
    i = index + 1
    certain = True
    while i < len(words):
        word = words[i]
        text = word.text
        if _opaque(word):
            return None, False
        if text in ("--", "-"):
            i += 1
            break
        if not text.startswith(("-", "+")) or len(text) < 2:
            break
        if text.startswith("--"):
            if text in ("--rcfile", "--init-file"):
                i += 2
                certain = False
                continue
            if text not in _SHELL_LONG_FLAGS:
                certain = False
            i += 1
            continue
        letters = text[1:]
        if any(letter in "cs" for letter in letters):
            return None, False  # `bash -c TEXT` runs TEXT; `bash -s` reads its script from stdin; anywhere in a cluster
        # Each o or O in a cluster takes the next word as its value (`-oc pipefail`, `-euo pipefail`), as bash reads it.
        values = sum(letter in "oO" for letter in letters)
        if values or any(letter not in _SHELL_FLAGS for letter in letters):
            certain = False
        i += 1 + values
    if i >= len(words):
        return None, False  # no operand: the shell reads its script from stdin
    return i, certain


def _classify(command: _Command, defined: set[str]) -> Invocation | None:
    words = command.words
    start = 0
    while start < len(words) and words[start].text in _KEYWORDS and not words[start].quoted:
        start += 1
    if start < len(words) and words[start].text == "coproc" and not words[start].quoted:
        # `coproc cmd` runs cmd in the background, `coproc NAME { .. }` a group: what runs is not read here.
        return Invocation([w.text for w in words[start:]], False, True)
    while start < len(words):
        if _is_assignment(words[start]):
            start += 1
        elif words[start].text == "function" and not words[start].quoted:
            # `function NAME { BODY` / `function NAME if ..`: the definition's words are no command, its body's are
            # (#41133 BLOCK F1: `function publish { gh release create ..; }` hid the gh).
            start += 2
        else:
            break
    certain = not command.dynamic and not command.nested and command.reached
    any_program = False
    while start < len(words) and not _opaque(words[start]):
        name = _program_name(words[start].text)
        if name in _WRAPPERS:
            program, sure = _unwrap(words, start, _WRAPPERS[name])
        elif name in _SHELLS:
            program, sure = _shell_script(words, start)
        else:
            break
        if program is None:
            return Invocation([w.text for w in words[start:]], False, True)
        if program >= len(words):
            # `env` or `nice` alone runs itself; `exec` or `time` alone runs nothing.
            return Invocation([w.text for w in words[start:]], certain and sure, False)
        certain = certain and sure
        start = program
        if name in _SHELLS:
            # An unmodeled mode (-i reads rc files, --rcfile FILE, -l a profile) may run a file the words name
            # only as an option value, or none.
            any_program = not sure
            break  # the operand is a script file, whatever its name
    if start >= len(words):
        return None  # only assignments and redirections: nothing is run (a substitution's commands are separate)
    program = words[start]
    name = _program_name(program.text)
    if _opaque(program) or program.text.startswith("$"):
        certain, any_program = False, True
    if _has_inline_interpreter_code(name, words[start + 1:], command.stdin):
        certain, any_program = False, True
    if name in _RUNS_ARGUMENTS or program.text in defined:
        certain, any_program = False, True
    if program.text.startswith("/") and name not in _SHELLS and name not in _WRAPPERS \
            and any(_TEXT_OPTION.fullmatch(word.text) for word in words[start + 1:]):
        certain, any_program = False, True  # an absolute program this does not know, given -c: it may run anything
    return Invocation([program.text.removeprefix("./"), *(w.text for w in words[start + 1:])], certain, any_program)


def may_run(run: str) -> list[Invocation]:
    """Every command that might run, with how sure the detector is. An unlexable script ends with
    Invocation([], False, True): anything after the point it stopped may run."""
    defined: set[str] = set()
    commands, complete = _commands(run, False, defined)
    found = []
    for command in commands:
        invocation = _classify(command, defined)
        if invocation is not None:
            found.append(invocation)
    if defined:
        found = [invocation._replace(certain=False) for invocation in found]
    if not complete:
        found.append(Invocation([], False, True))
    return found


def must_run(run: str) -> list[list[str]]:
    """The commands (program first) bash really runs and the detector is certain of. Anything it cannot be sure of
    is left out: use this where a script is credited with running something."""
    return [invocation.words for invocation in may_run(run) if invocation.certain]


def run_when_reached(run: str) -> list[list[str]]:
    """must_run() without the control flow: the commands bash runs whenever it gets to them (behind `&&`, in a branch
    or a loop too), read in full: none in a substitution, behind an expansion or eval, or after a function is
    defined. Use it only where a credit holds for every run that gets to the command, and holds when no run does
    (script_made_keychain(): a script that imports the certificate and makes the keychain in one)."""
    defined: set[str] = set()
    commands, complete = _commands(run, False, defined)
    if defined:
        return []
    found = []
    for command in commands:
        invocation = _classify(command._replace(reached=True), defined)
        if invocation is not None and invocation.certain:
            found.append(invocation.words)
    return found


def may_run_program(run: str, program: str) -> bool:
    """Whether `program` (as written, a leading `./` dropped) might run: named by a command, or run by one that may
    run any program. Use this where a script is blamed for running something."""
    return any(invocation.any_program or (invocation.words and invocation.words[0] == program)
               for invocation in may_run(run))


class GhApiRequest(NamedTuple):
    """How `gh api` reads its arguments (the words after `api`): the method it sends and the endpoint it calls."""
    method: str | None  # upper case; None when the words do not say for certain (a variable, an option gh may add)
    endpoint: str | None  # None when absent (xargs feeds it) or not readable (a variable or substitution)

    @property
    def writes(self) -> bool:
        """Whether it may send anything but a read. A method it cannot read may be a write."""
        return self.method not in ("GET", "HEAD")


# gh api's options (`gh api --help`): those that take a value, the boolean ones, and the field flags that turn the
# default method from GET into POST (as does --input).
_GH_API_VALUES = {"-X": "--method", "-f": "--raw-field", "-F": "--field", "-H": "--header", "-q": "--jq",
                  "-t": "--template", "-p": "--preview"}
_GH_API_LONG_VALUES = frozenset(_GH_API_VALUES.values()) | {"--input", "--hostname", "--cache"}
_GH_API_BOOLEANS = {"-i": "--include"}
_GH_API_LONG_BOOLEANS = frozenset(_GH_API_BOOLEANS.values()) | {"--paginate", "--silent", "--verbose", "--slurp"}
_GH_API_POST = frozenset({"--raw-field", "--field", "--input"})


def _unreadable(text: str) -> bool:
    """A word whose text bash only knows at run time (a variable or a substitution)."""
    return "$" in text or "\x00" in text or "`" in text


def gh_api_request(args: list[str]) -> GhApiRequest:
    """The method and endpoint of `gh api ARGS`, read the way gh reads them: a field flag (-f, -F, --field,
    --raw-field) or --input makes it a POST unless -X/--method names another; flags come spaced, attached
    (-XPOST, -ftag=v1, --method=POST) or clustered (-iXPOST).

    Writes first: a write method anywhere wins over a GET or HEAD anywhere else (`-X POST -X GET` is a write), and
    --input, a request body, makes even a GET a write. An option gh does not document, a method held in a
    variable, or more than one endpoint leaves the method or endpoint unknown, which a caller counts as a write
    (`writes`) or as possibly any path. Only a read method with no write marker is a read; with no method, field
    flags alone (-f, -F with -X GET) are query parameters."""
    methods: list[str | None] = []
    posts = False
    body = False
    unknown = False
    endpoints: list[str | None] = []

    def take(name: str, value: str | None) -> None:
        nonlocal posts, body
        if name == "--method":
            methods.append(None if value is None or _unreadable(value) else value.upper())
        elif name in _GH_API_POST:
            posts = True
            body = body or name == "--input"

    index = 0
    while index < len(args):
        word = args[index]
        index += 1
        if word == "--":
            endpoints.extend(None if _unreadable(rest) else rest for rest in args[index:])
            break
        if word.startswith("--"):
            name, joined, value = word.partition("=")
            if name in _GH_API_LONG_VALUES:
                if not joined:
                    value = args[index] if index < len(args) else None
                    index += 1
                take(name, value)
            elif name not in _GH_API_LONG_BOOLEANS:
                unknown = True
            continue
        if word.startswith("-") and len(word) > 1:
            for at in range(1, len(word)):
                option = "-" + word[at]
                if option in _GH_API_BOOLEANS:
                    continue
                if option in _GH_API_VALUES:
                    value = word[at + 1:] or None
                    if value is None:
                        value = args[index] if index < len(args) else None
                        index += 1
                    take(_GH_API_VALUES[option], value)
                    break
                unknown = True
                break
            continue
        endpoints.append(None if _unreadable(word) else word)
    endpoint = endpoints[0] if len(endpoints) == 1 else None
    if unknown or None in methods:
        return GhApiRequest(None, endpoint)
    written = [method for method in methods if method not in ("GET", "HEAD")]
    if written:
        return GhApiRequest(written[0], endpoint)
    if methods:
        return GhApiRequest(None if body else methods[-1], endpoint)  # a GET with a request body is no read
    return GhApiRequest("POST" if posts else "GET", endpoint)


class Options(NamedTuple):
    """A tool's option grammar before its subcommand: the options that take a value (`-p X`, `-pX`, `--package X`,
    `--package=X`) and those that take none. Short ones may cluster (`-vq`, `-Ro/r`)."""
    values: frozenset[str] = frozenset()
    flags: frozenset[str] = frozenset()


def first_operand(args: list[str], options: Options) -> int | None:
    """The index in ARGS of the first operand (the subcommand), read with OPTIONS: an option's value is never an
    operand, and `--` ends the options. len(ARGS) when there is none; None when an option before it is one the
    grammar does not know, or a word bash only knows at run time, so its position cannot be read (fail closed)."""
    index = 0
    while index < len(args):
        word = args[index]
        if _unreadable(word):
            return None
        if word == "--":
            return index + 1
        if word == "-" or not word.startswith("-"):
            return index
        if word in options.flags:
            index += 1
            continue
        if word in options.values:
            index += 2
            continue
        if word.startswith("--"):
            if "=" in word and word.split("=", 1)[0] in options.values:
                index += 1
                continue
            return None
        for at in range(1, len(word)):
            option = "-" + word[at]
            if option in options.values:
                index += 1 if at < len(word) - 1 else 2
                break
            if option not in options.flags:
                return None
        else:
            index += 1
    return len(args)


# Past this many levels of one command running another, what it runs counts as unreadable.
_NEST_LIMIT = 4
_SOURCES = {"source", "."}


def may_run_nested(run: str) -> list[list[str]]:
    """Every command that might run, wrapped ones included, as word lists (program first). For a command that may
    run programs its words do not name, the commands inside it follow its own words: the text an eval or a shell's
    -c runs, a text argument (`su -c '..'`, `ssh host '..'`, `env -S '..'`), and each tail of its words a runner
    (xargs, find -exec, flock, a wrapper with options this does not model) may run as a command. An empty list
    stands for executable content this cannot read: a heredoc or stdin into a shell, eval or -c of text held in a
    variable or substitution, a sourced file, an unlexable tail, nesting past _NEST_LIMIT. A variable program
    (`"$python" -m x`) is read by its argument tails like any runner, so its arguments still count. A caller
    asking "may this publish" counts an empty list as yes; a function's body is listed where it is defined."""
    found: list[list[str]] = []
    _nested(run, set(), 0, found)
    return found


def _nested(run: str, defined: set[str], depth: int, found: list[list[str]]) -> None:
    commands, complete = _commands(run, depth > 0, defined)
    for command in commands:
        invocation = _classify(command, defined)
        if invocation is not None:
            _expand(invocation, defined, depth, found)
    if not complete:
        found.append([])


def _shell_text(args: list[str]) -> str | None:
    """The command text `bash -c TEXT` runs; None when the shell reads stdin or a script instead, or -c has no text.

    bash reads every option first, wherever -c sits among them, and each `o` or `O` in an option word (`-o NAME`,
    `+O NAME`, or clustered: `-co pipefail`, `-euco pipefail`, `-coo a b`) takes the next word as its value. The
    text is the first word after the options and their values (or after `--`). #41133 F2: `bash -co pipefail TEXT`
    read pipefail as the text."""
    index = 0
    command = False
    while index < len(args):
        word = args[index]
        index += 1
        if word == "--":
            break
        if word.startswith("--"):
            index += 1 if word in ("--rcfile", "--init-file") else 0
            continue
        if word[:1] not in ("-", "+") or len(word) < 2:
            return word if command else None
        letters = word[1:]
        command = command or (word[0] == "-" and "c" in letters)
        index += sum(letter in "oO" for letter in letters)
    return args[index] if command and index < len(args) else None


def _word_token(text: str) -> Token:
    return Token("word", text, True, dynamic=_unreadable(text))


def _expand(invocation: Invocation, defined: set[str], depth: int, found: list[list[str]]) -> None:
    words = invocation.words
    found.append(words)
    if not words or not invocation.any_program:
        return
    program, args = _program_name(words[0]), words[1:]
    if words[0] in defined:
        return
    if depth >= _NEST_LIMIT or program in _SOURCES:
        found.append([])
        return
    if program == "eval":
        if args[:1] == ["--"]:
            args = args[1:]
        text = " ".join(args)
        if _unreadable(text):
            found.append([])
        else:
            _nested(text, defined, depth + 1, found)
        return
    if program in _SHELLS:
        if program == "fish":
            found.append([])
            return
        text = _shell_text(args)
        if text is None or _unreadable(text):
            found.append([])
        else:
            _nested(text, defined, depth + 1, found)
        return
    if not _unreadable(program) and program not in _RUNS_ARGUMENTS and program not in _WRAPPERS:
        found.append([])  # a script a shell runs in a mode this does not model
        return
    for word in args:
        if re.search(r"\s", word):
            _nested(word, defined, depth + 1, found)
    operand_seen = False
    for index in range(1, len(words)):
        word = words[index]
        # A variable may be the program only where the runner's first operand is; later it is an argument.
        if not (_unreadable(word) and operand_seen):
            tail = _classify(_Command([_word_token(text) for text in words[index:]], False, True), defined)
            if tail is not None:
                _expand(tail, defined, depth + 1, found)
        operand_seen = operand_seen or not word.startswith("-")
