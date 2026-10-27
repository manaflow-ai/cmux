#!/usr/bin/env python3
# Vendored from manaflow-ai/cmuxterm-hq tools/agent-guards/block_polling.py; keep the two copies in sync.
# Change the judge there first, then copy it here unchanged below this header.
"""PreToolUse(Bash) judge for block-gh-polling.sh: refuse real polling loops.

The old hook matched text, so a command that only *mentioned* a loop (a pkill of
a poller, a grep for "until gh") was refused. This one parses the shell command
into commands and loops and judges only what would run:

* a `while`/`until` loop that calls GitHub (any `gh` network command, or
  curl/wget of api.github.com) and sleeps under 300 s, or has no sleep and
  polls: the GitHub call is in the loop condition, or the condition is constant
* a `for` loop that calls GitHub, sleeps under 300 s and does not use its loop
  variable in the call (a poll, not pacing over a list)
* `watch` re-running a GitHub call; `gh run watch` / `gh pr checks --watch`
  with an interval under 300 s
* a `while`/`until` loop that only waits on a file (`[ -s f ]`, `test -e f`,
  `ls f`, `grep -q x f`) with nothing bounding it: it keeps a session alive for
  nothing (2026-10-20: nine `until [ -s never*.txt ]` loops)

Words inside quotes, heredoc bodies and arguments of other commands are data,
except the text handed to a shell (`bash -c`, `eval`, `ssh host '...'`,
`docker exec c sh -c`, a heredoc fed to bash) and `$(...)` substitutions, which
are parsed too.

Reads the hook payload on stdin; prints a deny decision or nothing. A parser
fault allows the command.
"""

import bisect
import json
import re
import sys

MAX_DEPTH = 8
LONG_SLEEP = 300  # seconds; one check per 5 minutes is fine for a command an agent runs once
# Checked-in scripts and workflows (find_violations) get no slow-poll pass: any sleeping GitHub loop is a
# poll there, since the file runs again and again. The hook's own threshold stays LONG_SLEEP.
STRICT = {"on": False}


def long_sleep():
    return float("inf") if STRICT["on"] else LONG_SLEEP
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
INTERPRETERS = {"python", "python3", "node", "deno", "bun", "ruby", "perl"}
# commands that run another command, possibly a shell, on this or another machine
CARRIERS = {"ssh", "reach", "docker", "podman", "kubectl", "nsenter", "chroot", "su", "sudo", "doas", "tmux", "screen"}
WRAPPER_FLAG_VALUES = {
    "nice": {"-n", "--adjustment"}, "ionice": {"-c", "-n", "-p"},
    "sudo": {"-u", "-g", "-C", "-h", "-p", "-r", "-t", "-U", "-D", "-R"}, "env": {"-u", "-C", "-S"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"}, "flock": {"-w", "-E"}, "stdbuf": {"-i", "-o", "-e"},
    "xargs": {"-I", "-n", "-P", "-d", "-L", "-s", "-E", "-a"}, "command": set(), "nohup": set(), "time": set(),
    "exec": {"-a"}, "setsid": set(), "builtin": set(), "chronic": set(),
}
KEYWORDS = {"do", "then", "else", "elif", "if", "!", "{", "}", "time", "coproc"}
LOCAL_GH = {"auth", "config", "completion", "alias", "help", "version", "extension", "--version"}
FILE_TEST = re.compile(r"^-[sfedrSpxLbcgkOGNtuw]$")
FILE_READERS = {"ls", "stat", "cat", "wc", "head", "tail"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag"}
# commands that make a loop body "just waiting": anything else in it is real work
IDLE = {"sleep", "echo", "printf", "true", "false", ":", "break", "continue", "date", "test", "[", "[[", "return",
        "exit"} | FILE_READERS | GREPS
BOUND_MARKERS = {"$ARITH", "$BOUNDED"}
BOUND_COMMANDS = {"let", "expr", "seq", "timeout"}

MSG_GH = ("Blocked: GitHub polling burns the shared API budget for every session (GraphQL and REST, 5000/h each). "
          "Do not loop or watch. For a PR in the desktop app: bind it (ccd_pr bind_pr) and wait for the CI event it pushes; "
          "read state with ccd_pr get_status. For a run (dispatched, main, anything without a PR): run "
          "'glaeda-gh wait run OWNER/REPO/RUN_ID' in the background (run_in_background); it exits 0 on success and 1 on "
          "failure; one daemon per machine does the polling with conditional requests that cost almost nothing (skill "
          "github-ci-wait). Outside the desktop app, 'glaeda-gh wait pr OWNER/REPO#N' does the same for a PR. Batch "
          "many-PR lookups into one GraphQL query.")
MSG_FILE = ("Blocked: a sleep loop that waits on a file keeps a session alive and burns a shell for nothing. Run "
            "'glaeda-gh wait file PATH --timeout SECS' in the background (run_in_background) instead: it exits 0 when "
            "the file exists and is not empty (--exists, --gone and --contains REGEX change the test), 2 on timeout. "
            "'glaeda-gh wait pid PID' waits for a process to exit. If a command you started writes the file, run it in "
            "the background and wait for it to finish.")

ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=.*")
CFLAG = re.compile(r"-[a-zA-Z]*c[a-zA-Z]*")


class Cmd(list):
    """argv of one command, with the 1-based line of the text it starts on (for the file scanner)."""
    line = None


class Text(str):
    """Text handed to an interpreter, with the line it starts on."""
    line = None


def at_line(cls, value, line):
    obj = cls(value)
    obj.line = line
    return obj


def base_of(word):
    return word.rsplit("/", 1)[-1]


def strip_wrappers(argv):
    """argv without leading keywords, VAR=value assignments and wrappers (env, nohup, timeout N, ...)."""
    a = list(argv)
    while a:
        w = a[0]
        if w in KEYWORDS or ASSIGN.fullmatch(w):
            a.pop(0)
        elif base_of(w) in WRAPPER_FLAG_VALUES:
            base = base_of(w)
            a.pop(0)
            while a and (a[0].startswith("-") or ASSIGN.fullmatch(a[0])):
                flag = a.pop(0)
                if flag in WRAPPER_FLAG_VALUES[base] and a:
                    a.pop(0)
            if base in ("timeout", "flock", "nice", "ionice") and a and re.fullmatch(r"[0-9.]+[smhd]?|/\S+", a[0]):
                a.pop(0)
        else:
            break
    return a


def read_heredoc(src, i, delim, strip):
    n = len(src)
    lines = []
    while i < n:
        k = src.find("\n", i)
        line = src[i:] if k < 0 else src[i:k]
        i = n if k < 0 else k + 1
        if (line.lstrip("\t") if strip else line).rstrip() == delim:
            break
        lines.append(line)
    return "\n".join(lines), i


def nested_texts(argv):
    """(shell texts, interpreter texts, bounded) that argv hands to another shell or interpreter."""
    eff = strip_wrappers(argv)
    if not eff:
        return [], [], False
    base = base_of(eff[0])
    bounded = any(base_of(w) == "timeout" for w in argv[:len(argv) - len(eff)])
    shells, interps = [], []
    if base in SHELLS or base in CARRIERS:
        starts = [0] if base in SHELLS else range(len(eff))
        for k in starts:
            if base_of(eff[k]) in SHELLS:
                for j in range(k + 1, len(eff) - 1):
                    if CFLAG.fullmatch(eff[j]):
                        shells.append(eff[j + 1])
                        break
        if base == "su":
            for j in range(1, len(eff) - 1):
                if eff[j] in ("-c", "--command"):
                    shells.append(eff[j + 1])
        if base in ("ssh", "reach", "doas"):
            shells += [a for a in eff[1:] if re.search(r"\s", a)]
    elif base == "eval":
        shells.append(" ".join(eff[1:]))
    elif base in INTERPRETERS:
        for j in range(1, len(eff) - 1):
            if eff[j] in ("-c", "-e", "-p", "--eval"):
                interps.append(eff[j + 1])
    return shells, interps, bounded


def split_command(src, depth=0, line0=1):
    """Lex shell text into (commands, interpreter texts). Commands are argv lists in order; the commands of
    $(...), `...`, `bash -c '...'`, eval and shell heredocs follow the command that holds them, inline."""
    cmds = []
    interps = []
    n = len(src)
    i = 0
    newlines = [m.start() for m in re.finditer("\n", src)]
    start = 0  # where the command being built starts

    def line_at(pos):
        return line0 + bisect.bisect_left(newlines, pos)
    words = []  # words of the command being built
    cur = []  # chars of the word being built
    in_word = False
    heredocs = []  # (delim, strip_tabs, owner argv) waiting for the next newline
    subs = []  # commands from $(...) in the command being built; they follow it, inside its loop

    def end_word():
        nonlocal cur, in_word
        if in_word:
            words.append("".join(cur))
        cur, in_word = [], False

    def merge(sub, extra):
        cmds.extend(sub)
        interps.extend(extra)

    def end_cmd():
        nonlocal words
        end_word()
        if words:
            line = line_at(start)
            cmds.append(at_line(Cmd, words, line))
            if depth < MAX_DEPTH:
                shells, found, bounded = nested_texts(words)
                interps.extend(at_line(Text, t, line) for t in found)
                for text in shells:
                    sub, extra = split_command(text, depth + 1, line)
                    for c in sub:
                        cmds.append(c)
                        if bounded:
                            cmds.append(["$BOUNDED"])
                    interps.extend(extra)
        cmds.extend(subs)
        del subs[:]
        words = []

    def match_paren(start):
        """Index of the ')' closing a '(' at start-1 (start is just past it)."""
        d, j = 1, start
        while j < n:
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == "#" and (j == start or src[j - 1] in " \t\n;(|&"):
                k = src.find("\n", j)  # a comment: its quotes and parens are not code
                j = n if k < 0 else k
                continue
            if c == "<" and src.startswith("<<", j) and not src.startswith("<<<", j):
                # A heredoc body (a perl or python script in `$(cat <<'X' ...)`) is data up to its terminator line.
                m = re.match(r"""<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|\\?([A-Za-z0-9_.-]+))""", src[j:])
                if m:
                    delim = m.group(2) or m.group(3) or m.group(4)
                    body = src.find("\n", j + m.end())
                    end = re.search(r"(?m)^" + ("\t*" if m.group(1) else "") + re.escape(delim) + r"[ \t]*$",
                                    src[body + 1:]) if body >= 0 else None
                    if end:
                        rest = src[j + m.end():body + 1]  # the rest of the heredoc's own line is still code
                        sub = match_paren_in(rest, d)
                        if sub is not None:
                            return j + m.end() + sub
                        j = body + 1 + end.end()
                        continue
            if c == "'":
                k = src.find("'", j + 1)
                j = n if k < 0 else k + 1
                continue
            if c == '"':
                j += 1
                while j < n and src[j] != '"':
                    j += 2 if src[j] == "\\" else 1
                j += 1
                continue
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
                if d == 0:
                    return j
            j += 1
        return n

    def match_paren_in(text, depth):
        """Index in text of the ')' that brings depth to 0, outside quotes, or None."""
        k = 0
        while k < len(text):
            c = text[k]
            if c == "\\":
                k += 2
                continue
            if c in "'\"":
                e = text.find(c, k + 1)
                if e < 0:
                    return None
                k = e + 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    return k
            k += 1
        return None

    def substitute(j):
        """Handle $( at src[j-2:j]; j is just past '('. Returns the index to resume at."""
        nonlocal in_word
        in_word = True
        if j < n and src[j] == "(":  # $(( arithmetic ))
            close = src.find("))", j)
            cur.append("$ARITH")
            subs.append(["$ARITH"])
            return n if close < 0 else close + 2
        close = match_paren(j)
        if depth < MAX_DEPTH:
            sub, extra = split_command(src[j:close], depth + 1, line_at(j))
            subs.extend(sub)
            interps.extend(extra)
        cur.append("$SUB")
        return close + 1

    def backtick(j):
        nonlocal in_word
        close = src.find("`", j)
        close = n if close < 0 else close
        if depth < MAX_DEPTH:
            sub, extra = split_command(src[j:close], depth + 1, line_at(j))
            subs.extend(sub)
            interps.extend(extra)
        in_word = True
        cur.append("$SUB")
        return close + 1

    def heredoc_body(owner, body, line):
        eff = strip_wrappers(owner)
        if not eff or depth >= MAX_DEPTH:
            return
        base = base_of(eff[0])
        if base in SHELLS or base == "source" or (base in CARRIERS and any(base_of(w) in SHELLS for w in eff)):
            sub, extra = split_command(body, depth + 1, line)
            merge(sub, extra)
        elif base in INTERPRETERS:
            interps.append(at_line(Text, body, line))

    while i < n:
        c = src[i]
        if not words and not in_word:
            start = i
        if c == "\\":
            if i + 1 < n and src[i + 1] == "\n":
                i += 2
                continue
            in_word = True
            if i + 1 < n:
                cur.append(src[i + 1])
            i += 2
            continue
        if c == "'":
            k = src.find("'", i + 1)
            k = n if k < 0 else k
            in_word = True
            cur.append(src[i + 1:k])
            i = k + 1
            continue
        if c == '"':
            in_word = True
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\" and i + 1 < n:
                    cur.append(src[i + 1])
                    i += 2
                elif src[i] == "$" and src[i + 1:i + 2] == "(":
                    i = substitute(i + 2)
                elif src[i] == "`":
                    i = backtick(i + 1)
                else:
                    cur.append(src[i])
                    i += 1
            i += 1
            continue
        if c == "$" and src[i + 1:i + 2] == "(":
            i = substitute(i + 2)
            continue
        if c == "`":
            i = backtick(i + 1)
            continue
        if c == "#" and not in_word:
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "<" and src.startswith("<<", i) and not src.startswith("<<<", i):
            j = i + 2
            strip = False
            if j < n and src[j] == "-":
                strip = True
                j += 1
            while j < n and src[j] in " \t":
                j += 1
            m = re.match(r"""(?:'([^']*)'|"([^"]*)"|\\?([A-Za-z0-9_.-]+))""", src[j:])
            if m:
                delim = m.group(1) or m.group(2) or m.group(3)
                # `(( x = 1 << 3 ))` is arithmetic: a heredoc needs its terminator line later on
                if re.search(r"(?m)^" + ("\t*" if strip else "") + re.escape(delim) + r"[ \t]*$", src[j + m.end():]):
                    owner = words + (["".join(cur)] if in_word else [])
                    heredocs.append((delim, strip, owner))
                    end_word()
                    i = j + m.end()
                    continue
        if c in "<>":
            in_word = True
            cur.append(c)
            i += 1
            if src[i:i + 1] == "&":
                cur.append("&")
                i += 1
            continue
        if c == "(" and src.startswith("((", i) and not in_word:
            end_cmd()
            cmds.append(["$ARITH"])
        if c == "\n":
            end_cmd()
            i += 1
            for delim, strip, owner in heredocs:
                body_line = line_at(i)
                body, i = read_heredoc(src, i, delim, strip)
                heredoc_body(owner, body, body_line)
            heredocs.clear()
            continue
        if c in ";|&(){}" and not (c in "{}" and in_word):
            end_cmd()
            i += 1
            continue
        if c in " \t":
            end_word()
            i += 1
            continue
        in_word = True
        cur.append(c)
        i += 1
    end_cmd()
    return cmds, interps


def seconds(text):
    m = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([smhd]?)", text)
    if not m:
        return 0.0  # unknown (a variable): treat as short
    return float(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]


def gh_positionals(eff):
    """Arguments of a gh command that are not flags or flag values (-R owner/repo)."""
    out, skip = [], False
    for a in eff[1:]:
        if skip:
            skip = False
        elif a in ("-R", "--repo", "--hostname"):
            skip = True
        elif not a.startswith("-"):
            out.append(a)
    return out


# Names of shell functions that call GitHub, set by find_violations for one file: a loop that calls
# `gh_read_api` polls as surely as one that calls `gh api`.
GH_FUNCS = set()
FUNC_DEF = re.compile(r"^([ \t]*)(?:function[ \t]+([A-Za-z_][\w:-]*)(?:[ \t]*\(\))?|([A-Za-z_][\w:-]*)[ \t]*\(\))[ \t]*\{?[ \t]*$",
                      re.M)
# `name() { body; }` on one line
FUNC_INLINE = re.compile(r"^[ \t]*(?:function[ \t]+([A-Za-z_][\w:-]*)(?:[ \t]*\(\))?|([A-Za-z_][\w:-]*)[ \t]*\(\))[ \t]*"
                         r"\{(.*)\}[ \t]*;?[ \t]*(?:#.*)?$", re.M)


def is_github(argv):
    """A gh network command, curl/wget against api.github.com, or a function of this file that calls one."""
    eff = strip_wrappers(argv)
    if not eff:
        return False
    base = base_of(eff[0])
    if eff[0] in GH_FUNCS:
        return True
    if base == "gh":
        pos = gh_positionals(eff)
        return bool(pos) and pos[0] not in LOCAL_GH
    if base in ("curl", "wget", "http", "https", "xh"):
        return any("api.github.com" in a for a in eff[1:])
    return False


def is_file_test(argv):
    eff = strip_wrappers(argv)
    if not eff:
        return False
    base = base_of(eff[0])
    operands = [a for a in eff[1:] if not a.startswith("-")]
    if base in ("[", "[[", "test"):
        return any(FILE_TEST.match(a) for a in eff[1:])
    if base in FILE_READERS:
        return bool(operands)
    if base in GREPS:
        return len(operands) >= 2
    return False


def interval_of(eff):
    for k, a in enumerate(eff):
        m = re.fullmatch(r"(?:--interval|-i|-n)(?:=?(\d+(?:\.\d+)?))?", a)
        if m:
            if m.group(1):
                return float(m.group(1))
            if k + 1 < len(eff) and re.fullmatch(r"\d+(\.\d+)?", eff[k + 1]):
                return float(eff[k + 1])
    return None


def sleeps_of(cmds):
    out = []
    for argv in cmds:
        eff = strip_wrappers(argv)
        if eff and base_of(eff[0]) == "sleep":
            out.append(max([seconds(a) for a in eff[1:] if not a.startswith("-")] or [0.0]))
    return out


def is_bound(argv):
    if argv and argv[0] in BOUND_MARKERS:
        return True
    eff = strip_wrappers(argv)
    return bool(eff) and (base_of(eff[0]) in BOUND_COMMANDS or any("SECONDS" in a for a in eff))


def is_read_loop(cmds):
    """`while read x` iterates a list; it is not a wait."""
    for argv in cmds:
        eff = strip_wrappers(argv)
        if eff and eff[0] == "read" and "-t" not in eff:
            return True
    return False


CONSTANT_CONDS = ([":"], ["true"], ["[", "1", "]"], ["[[", "1", "]]"], ["test", "1"])


def is_constant(cond):
    return not cond or all(list(strip_wrappers(c)) in CONSTANT_CONDS for c in cond)


def verdict(loop):
    kind, cond, body = loop["kind"], loop["cond"], loop["body"]
    if kind == "for":
        cond = []
    everything = cond + body
    sleeps = sleeps_of(everything)
    gh_cmds = [c for c in everything if is_github(c)]
    if kind in ("while", "until"):
        iterating = is_read_loop(everything)
        bounded = any(is_bound(c) for c in cond) or any(c and c[0] in BOUND_MARKERS for c in body)
        if gh_cmds:
            if sleeps:
                if min(sleeps) < long_sleep():
                    return MSG_GH
            elif not iterating and (any(is_github(c) for c in cond) or (is_constant(cond) and not bounded)):
                return MSG_GH
        pure = all(
            (c[0] in BOUND_MARKERS) or (strip_wrappers(c) and base_of(strip_wrappers(c)[0]) in IDLE)
            for c in body if c)
        if any(is_file_test(c) for c in everything) and pure and not iterating and (STRICT["on"] or not bounded):
            return MSG_FILE
    elif kind == "for" and gh_cmds and sleeps and min(sleeps) < long_sleep():
        var = loop.get("var")
        uses = var and any(re.search(r"\$\{?" + re.escape(var) + r"\b", " ".join(c)) for c in gh_cmds)
        if not uses:
            return MSG_GH
    return None


def iter_violations(cmds):
    """Yield (line, message) for every polling loop or watch in cmds, in order. line is None when unknown."""
    stack = []  # open loops: {"kind", "var", "cond", "body", "in_cond", "line"}
    for argv in cmds:
        line = getattr(argv, "line", None)
        k = 0
        while k < len(argv) and argv[k] in KEYWORDS:
            k += 1
        lead, rest = argv[:k], argv[k:]
        if "do" in lead and stack and stack[-1]["in_cond"]:
            stack[-1]["in_cond"] = False
        if rest and rest[0] == "done":
            if stack:
                loop = stack.pop()
                v = verdict(loop)
                if v:
                    yield loop["line"], v
            continue
        if rest and rest[0] in ("while", "until", "for", "select"):
            kind = "for" if rest[0] == "select" else rest[0]
            stack.append({"kind": kind, "var": rest[1] if kind == "for" and len(rest) > 1 else None,
                          "cond": [], "body": [], "in_cond": True, "line": line})
            rest = rest[1:] if kind in ("while", "until") else []
        if rest:
            for loop in stack:
                loop["cond" if loop["in_cond"] else "body"].append(rest)
        e = strip_wrappers(rest)
        if not e:
            continue
        base = base_of(e[0])
        if base == "watch" and re.search(r"\bgh\b|api\.github\.com", " ".join(e[1:])):
            iv = interval_of(e[1:])
            if iv is None or iv < LONG_SLEEP:
                yield line, MSG_GH
        if base == "gh":
            pos = gh_positionals(e)
            if pos[:2] == ["run", "watch"] or (pos[:2] == ["pr", "checks"] and "--watch" in e):
                iv = interval_of(e)
                if iv is None or iv < LONG_SLEEP:
                    yield line, MSG_GH + " Use --interval 300 or more if you need gh run watch / gh pr checks --watch, in a background job."
    while stack:
        loop = stack.pop()
        v = verdict(loop)
        if v:
            yield loop["line"], v


def judge_commands(cmds):
    """Return a deny message or None."""
    return next((msg for _, msg in iter_violations(cmds)), None)


GH_TEXT = re.compile(r"^\s*gh\s*$|(?:^|[\s;&|(])gh\s+[a-z]|api\.github\.com")


def python_polls(tree):
    """A for/while loop in a python AST whose body calls something named *sleep and names GitHub
    (a "gh" argv word, a "gh ..." command string, or an api.github.com URL)."""
    import ast
    for loop in ast.walk(tree):
        if not isinstance(loop, (ast.For, ast.AsyncFor, ast.While)):
            continue
        sleeps = github = False
        docstrings = {id(d.body[0].value) for d in ast.walk(loop)
                      if isinstance(d, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and d.body
                      and isinstance(d.body[0], ast.Expr) and isinstance(d.body[0].value, ast.Constant)}
        docstrings |= {id(e.value) for e in ast.walk(loop) if isinstance(e, ast.Expr) and isinstance(e.value, ast.Constant)}
        for node in ast.walk(loop):
            if id(node) in docstrings:
                continue
            if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
                continue  # a bare string statement is a comment, not a call argument
            if isinstance(node, ast.Call):
                f = node.func
                name = f.attr if isinstance(f, ast.Attribute) else f.id if isinstance(f, ast.Name) else ""
                sleeps = sleeps or name.endswith("sleep")
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and GH_TEXT.search(node.value):
                github = True
        if sleeps and github:
            return True
    return False


C_LIKE_TOKEN = re.compile(r"""//[^\n]*|/\*.*?\*/|#[^\n]*|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*"|`(?:\\.|[^`\\])*`""", re.S)


def interp_polls_strict(body):
    """File mode: python is read as python (its strings and comments are data); anything else has its
    comments and string literals blanked before looking for loop and sleep syntax."""
    import ast
    try:
        tree = ast.parse(body)
    except (SyntaxError, ValueError):
        tree = None
    if tree is not None:
        return python_polls(tree)
    strings = []

    def blank(m):
        tok = m.group(0)
        if tok[0] in "'\"`":
            strings.append(tok[1:-1])
            return '""'
        return " "
    code = C_LIKE_TOKEN.sub(blank, body)
    looping = re.search(r"\b(?:for|while)\s*\(|\bdo\s*\{|\bsetInterval\s*\(", code)
    sleeping = re.search(r"\b(?:sleep|setTimeout)\s*\(", code)
    github = any(GH_TEXT.search(t) for t in strings) or re.search(r"\bgh\s+[a-z]", code)
    return bool(looping and sleeping and github)


def interp_polls(body):
    """Whether interpreter text (python -c, node -e, a heredoc fed to python) loops on GitHub with a sleep.
    In files (STRICT) any loop counts, as a counted `for _ in range(60)` poll is still a poll; see
    interp_polls_strict."""
    if STRICT["on"]:
        return interp_polls_strict(body)
    looping = re.search(r"while\s+(True|1|true)\b|for\s*\(\s*;\s*;\s*\)|setInterval|while\s*\(\s*(true|1)\s*\)", body)
    sleeping = re.search(r"sleep|setTimeout", body)
    github = re.search(r"\bgh\b[\"', ]+\s*\W*[a-z]+|api\.github\.com", body)
    return bool(looping and sleeping and github)


def function_bodies(text):
    """{name: body} for the shell functions defined in text (a `name() {` line through its closing `}`)."""
    out = {}
    lines = text.split("\n")
    for m in FUNC_DEF.finditer(text):
        name = m.group(2) or m.group(3)
        lead = len(m.group(1).expandtabs())
        first = text.count("\n", 0, m.start())
        body = []
        for line in lines[first + 1:]:
            stripped = line.strip()
            if stripped.startswith("}") and len(line) - len(line.lstrip()) <= lead:
                break
            body.append(line)
        out[name] = out.get(name, "") + "\n".join(body) + "\n"
    for m in FUNC_INLINE.finditer(text):
        name = m.group(1) or m.group(2)
        out[name] = out.get(name, "") + m.group(3) + "\n"
    return out


def github_functions(text):
    """Names of functions in text that call GitHub, directly or through each other."""
    bodies = {name: split_command(body)[0] for name, body in function_bodies(text).items()}
    found = set()
    saved = set(GH_FUNCS)
    try:
        while True:
            GH_FUNCS.clear()
            GH_FUNCS.update(found)
            more = {name for name, cmds in bodies.items() if name not in found and any(is_github(c) for c in cmds)}
            if not more:
                return found
            found |= more
    finally:
        GH_FUNCS.clear()
        GH_FUNCS.update(saved)


def find_violations(text):
    """Every polling violation in shell text, as (line, message), for scanning files (polling_scan.py)."""
    funcs = github_functions(text)
    saved = set(GH_FUNCS)
    GH_FUNCS.clear()
    GH_FUNCS.update(funcs)
    strict = STRICT["on"]
    STRICT["on"] = True
    try:
        return _find_violations(text)
    finally:
        STRICT["on"] = strict
        GH_FUNCS.clear()
        GH_FUNCS.update(saved)


def _find_violations(text):
    cmds, interps = split_command(text)
    found = list(iter_violations(cmds))
    found += [(getattr(body, "line", None), MSG_GH) for body in interps if interp_polls(body)]
    return found


def judge(command):
    cmds, interps = split_command(command)
    msg = judge_commands(cmds)
    if msg:
        return msg
    if any(interp_polls(body) for body in interps):
        return MSG_GH
    return None


def main():
    try:
        payload = json.load(sys.stdin)
        command = payload.get("tool_input", {}).get("command") or ""
        reason = judge(command)
    except Exception:  # a parser fault must never block work
        return 0
    if reason:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
