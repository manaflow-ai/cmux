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

An Invocation is `certain` only when nothing in or before the simple command is beyond this lexer: a command or
process substitution (`$(..)`, backticks, `<(..)`), an arithmetic or parameter expansion in its program word, a
program that runs its arguments (eval, source, xargs, find, `bash -c` ...), a function or alias defined anywhere in
the script, or a script the lexer could not finish (an unterminated quote or substitution). A wrapper (env, nice,
nohup, timeout, sudo, command, exec ...) and a shell given a script are read through one table of which operand
runs (_WRAPPERS, _shell_script): an option it does not model, or a mode that does not run the first operand as a
script (`bash -n`, `-s`, `-i`, `-o NAME`, `--rcfile`, `command -v`), leaves the command uncertain. Commands
inside a substitution, and those in an unquoted heredoc body's `$(..)`, are reported uncertain. Not modeled, and
documented here so no caller reads more into "certain" than it holds: control flow. A command in an `if`, after
`&&` / `||`, or after `exit` is reported as a command bash would run if control reached it. tests/
test_shell_invocations.py runs each fixture in real bash and checks must_run is a subset of what ran and may_run a
superset.

Lexing keeps quoting: a word remembers whether any part was quoted or escaped, and only an unquoted operator splits
commands, opens a heredoc or redirects. A heredoc terminator is an exact line for `<<`, leading tabs stripped for
`<<-`; several heredocs on one line take their bodies in order.
"""
from __future__ import annotations

import re
from typing import NamedTuple

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
    assignments: bool = False  # NAME=VALUE words may come before the program (env, the `time` keyword)
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
                    values=_options("-u", "--unset"), assignments=True),
    "nice": _Wrapper(values=_options("-n", "--adjustment"), numeric=True),
    "nohup": _Wrapper(),
    "stdbuf": _Wrapper(values=_options("-i", "-o", "-e", "--input", "--output", "--error")),
    "command": _Wrapper(flags=_options("-p"), no_run=_options("-v", "-V")),
    "exec": _Wrapper(flags=_options("-c", "-l"), values=_options("-a")),
    "time": _Wrapper(flags=_options("-p"), assignments=True),
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
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
# Shell options that keep "run the first operand as a script": the rest (-c text, -s stdin, -i interactive,
# -n noexec, -t one command, -r restricted, -l login profile, -D, -o/-O NAME, --rcfile FILE ...) are uncertain.
_SHELL_FLAGS = frozenset("abefhkmpuvxBCEHPT")
_SHELL_LONG_FLAGS = frozenset({"--noprofile", "--norc", "--posix", "--noediting", "--verbose"})
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
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


class Lexed(NamedTuple):
    tokens: list[Token]
    complete: bool  # False: the lexer stopped at something it could not finish; later text is unread
    heredoc_subs: list[str]  # scripts of `$(..)` and backticks in unquoted heredoc bodies


class Invocation(NamedTuple):
    words: list[str]  # the program first (a leading `./` dropped), then its arguments; [] for an unlexable tail
    certain: bool  # nothing in or before the command is beyond the lexer
    any_program: bool  # it may also run programs the words do not name


def _match_close(text: str, index: int, opener: str) -> int | None:
    """The index just past the `)` or `}` closing the construct whose opener (`$(`, `<(`, `>(`, `${`) starts at
    `index`; None if it never closes. Quotes and nested brackets are skipped."""
    close = "}" if opener == "${" else ")"
    depth = 1
    i = index + len(opener)
    while i < len(text):
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
                return i + 1
        i += 1
    return None


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


def _body_subs(body: str) -> list[str] | None:
    """The scripts of the `$(..)` and backtick substitutions an unquoted heredoc body expands; None if one is
    unfinished."""
    found = []
    i = 0
    while i < len(body):
        if body[i] == "\\":
            i += 2
        elif body.startswith("$((", i):
            end = _match_close(body, i, "$(")
            if end is None:
                return None
            i = end
        elif body.startswith("$(", i):
            end = _match_close(body, i, "$(")
            if end is None:
                return None
            found.append(body[i + 2:end - 1])
            i = end
        elif body[i] == "`":
            end = _backtick_close(body, i)
            if end is None:
                return None
            found.append(body[i + 1:end - 1])
            i = end
        else:
            i += 1
    return found


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
    i = 0

    def start_word(at: int) -> None:
        nonlocal in_word, word_start
        if not in_word:
            in_word, word_start = True, at

    def end_word(at: int) -> None:
        nonlocal buf, subs, quoted, dynamic, in_word, expect_delimiter
        if not in_word:
            return
        word = "".join(buf)
        if expect_delimiter is not None:
            pending.append((word, expect_delimiter, not quoted))
            expect_delimiter = None
        tokens.append(Token("word", word, quoted, word_start, at, dynamic, tuple(subs)))
        buf, subs, quoted, dynamic, in_word = [], [], False, False, False

    def expansion(at: int, in_double: bool) -> int | None:
        """Read the expansion starting at `$` or a backtick at `at`; return the index after it, or None when it
        never closes (the lexer stops there)."""
        nonlocal dynamic
        if text[at] == "`":
            end = _backtick_close(text, at)
            if end is None:
                return None
            dynamic = True
            subs.append(text[at + 1:end - 1])
            buf.append("\x00")
            return end
        if text.startswith("$((", at):
            end = _match_close(text, at, "$(")
            if end is None:
                return None
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
            # `${x:-$(a)}` runs `a` (#41133 review F2): the substitutions inside a parameter expansion are commands.
            inner = _body_subs(text[at + 2:end - 1])
            if inner is None:
                return None
            subs.extend(inner)
            dynamic = True
            buf.append(text[at:end])
            return end
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
            i += 2
        elif c == "'":
            close = text.find("'", i + 1)
            if close < 0:
                return Lexed(tokens, False, heredoc_subs)
            start_word(i)
            buf.append(text[i + 1:close])
            quoted = True
            i = close + 1
        elif c == '"':
            start_word(i)
            quoted = True
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
            after = expansion(i, False)
            if after is None:
                return Lexed(tokens, False, heredoc_subs)
            i = after
        elif c in "<>" and text.startswith("(", i + 1):
            start_word(i)
            end = _match_close(text, i, c + "(")
            if end is None:
                return Lexed(tokens, False, heredoc_subs)
            dynamic = True
            subs.append(text[i + 2:end - 1])
            buf.append("\x00")
            i = end
        elif c in ";&|()<>":
            end_word(i)
            operator = next(op for op in _OPERATORS if text.startswith(op, i))
            if operator in _HEREDOCS:
                expect_delimiter = operator == "<<-"
            tokens.append(Token("op", operator, False, i, i + len(operator)))
            i += len(operator)
        else:
            start_word(i)
            buf.append(c)
            i += 1
    end_word(len(text))
    return Lexed(tokens, not pending and expect_delimiter is None, heredoc_subs)


class _Command(NamedTuple):
    words: list[Token]
    dynamic: bool  # some word, or a redirection target, holds a substitution or expansion
    nested: bool  # it runs inside a substitution


def _commands(run: str, nested: bool, defined: set[str]) -> tuple[list[_Command], bool]:
    """Each simple command's words (operators that end a command split it; redirections and their targets drop
    out), with those of every substitution after it; False if the lexer stopped early."""
    lexed = lex(run)
    found: list[_Command] = []
    inner: list[_Command] = []
    complete = lexed.complete
    words: list[Token] = []
    dynamic = False
    skip_target = False
    previous: Token | None = None
    tokens = lexed.tokens
    in_array = 0  # depth inside `name=( .. )`: its elements are values, not commands
    for index, token in enumerate(tokens):
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
            skip_target = True
        else:
            skip_target = False
            if words:
                found.append(_Command(words, dynamic, nested))
            words, dynamic = [], False
        previous = token
    if words:
        found.append(_Command(words, dynamic or not lexed.complete, nested))  # a command cut short is not certain
    for sub in lexed.heredoc_subs:
        commands, ok = _commands(sub, True, defined)
        inner.extend(commands)
        complete = complete and ok
    return found + inner, complete


def _opaque(word: Token) -> bool:
    return word.dynamic or "\x00" in word.text


def _program_name(text: str) -> str:
    """The name a program word is matched on: an absolute path by its basename (`/usr/bin/env` is env, `/bin/bash`
    is bash); anything else as written (`./bash` is a script of that name, not the shell)."""
    return text.rsplit("/", 1)[-1] if text.startswith("/") else text


# An option that hands a program its command as text, as a shell's -c does: on an absolute program this does not
# know, the program may run anything.
_TEXT_OPTION = re.compile(r"-[A-Za-z]*c")


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
    while wrapper.assignments and i < len(words) and _ASSIGNMENT.match(words[i].text):
        if _opaque(words[i]):
            return None, False
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
        taken = False
        for at, letter in enumerate(text[1:], start=1):
            if letter in "cs":
                return None, False  # `bash -c TEXT` runs TEXT; `bash -s` reads its script from stdin
            if letter in "oO":
                certain = False
                taken = at == len(text) - 1
                break
            if letter not in _SHELL_FLAGS:
                certain = False
        i += 2 if taken else 1
    if i >= len(words):
        return None, False  # no operand: the shell reads its script from stdin
    return i, certain


def _classify(command: _Command, defined: set[str]) -> Invocation | None:
    words = command.words
    start = 0
    while start < len(words) and (
            _ASSIGNMENT.match(words[start].text)
            or (words[start].text in _KEYWORDS and not words[start].quoted)):
        start += 1
    certain = not command.dynamic and not command.nested
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
    if program.dynamic or "\x00" in program.text or program.text.startswith("$"):
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
    (-XPOST, -ftag=v1, --method=POST) or clustered (-iXPOST). An option gh does not document, or a method held
    in a variable, leaves the method unknown, which `writes` counts as a write."""
    method: str | None = None
    explicit = False
    posts = False
    unknown = False
    endpoint: str | None = None
    seen_endpoint = False

    def take(name: str, value: str | None) -> None:
        nonlocal method, explicit, posts, unknown
        if name == "--method":
            explicit = True
            method = None if value is None or _unreadable(value) else value.upper()
        elif name in _GH_API_POST:
            posts = True

    index = 0
    while index < len(args):
        word = args[index]
        index += 1
        if word == "--":
            if index < len(args) and not seen_endpoint:
                endpoint, seen_endpoint = (None if _unreadable(args[index]) else args[index]), True
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
        if not seen_endpoint:
            endpoint, seen_endpoint = (None if _unreadable(word) else word), True
    if not explicit:
        method = "POST" if posts else "GET"
    if unknown:
        method = None
    return GhApiRequest(method, endpoint)


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
    """The command text `bash -c TEXT` runs; None when the shell reads stdin or a script instead."""
    index = 0
    while index < len(args):
        word = args[index]
        index += 1
        if word.startswith("--") and word != "--":
            index += 1 if word in ("--rcfile", "--init-file") else 0
            continue
        if word[:1] not in ("-", "+") or len(word) < 2:
            return None
        letters = word[1:]
        if word[0] == "-" and "c" in letters:
            # bash reads its options first: the text is the first operand after them.
            return next((later for later in args[index:] if later[:1] not in ("-", "+")), None)
        if letters[-1:] in ("o", "O"):
            index += 1
    return None


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
        text = " ".join(args)
        if _unreadable(text):
            found.append([])
        else:
            _nested(text, defined, depth + 1, found)
        return
    if program in _SHELLS:
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
