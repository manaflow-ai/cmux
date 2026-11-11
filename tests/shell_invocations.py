"""Which programs a bash `run:` block runs, as a three-valued answer a caller must interpret.

A caller asks one of two questions and the two fail closed in opposite directions, so there is no default:

- must_run(run): the commands bash really runs and whose program is certain. Use it where a script CREDITS a step
  ("this step runs the signer / creates the keychain"): a command this detector cannot be sure of is not run.
- may_run(run): every command that might run, certain or not. Use it where a script is BLAMED ("is this file
  guarded / run"): a command it cannot be sure of is assumed to run. An Invocation with `any_program` may run
  programs the words do not name (eval, xargs, `bash -c`, a function, an unlexable tail), so a may_run caller asking
  "might PROGRAM run" uses may_run_program(), which counts those.

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
        name = words[start].text
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
    if program.dynamic or "\x00" in program.text or program.text.startswith("$"):
        certain, any_program = False, True
    if program.text in _RUNS_ARGUMENTS or program.text in defined:
        certain, any_program = False, True
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
