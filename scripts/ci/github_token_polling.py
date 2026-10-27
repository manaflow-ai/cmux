#!/usr/bin/env python3
"""Find workflow steps that poll the GitHub API with the workflow's own GITHUB_TOKEN.

Every workflow in the repository shares one GITHUB_TOKEN budget an hour. A step
that sleeps in a loop and calls the API on each pass (a waiter, a coalescer)
spends that budget for as long as it waits; on 2026-10-25 and 2026-10-26 such
loops helped run it out, and nightly promotion, CLA and publish steps failed
with "API rate limit exceeded for installation".

A step polls when one loop in its script both sleeps and calls the API, the
script's own functions the loop calls counted (transitively), and the token
those calls use is github.token. Each language is read by its own rules:

- shell (a `run:` step): quotes, comments and heredoc bodies are not code;
  `for`/`while`/`until` end at their matching `done`, functions at their
  matching `}`; a helper counts only when it is called in command position.
  A heredoc fed to python or node is read as that language.
- Python (`shell: python`, or a heredoc fed to python): parsed with `ast`.
- JavaScript (actions/github-script, or a heredoc fed to node or bun): strings
  and comments are blanked, loops and functions end at their matching brace,
  and a helper counts only when it is called (`name(`, not `.name(`).

Token: gh prefers GH_TOKEN, so a non-empty GH_TOKEN the step sees (the step's
env first, then the job's, then the workflow's) decides for gh; an unset or
empty one falls back to GITHUB_TOKEN. A script that names $GITHUB_TOKEN itself
(curl, urllib) is judged by GITHUB_TOKEN too. Either counts when it carries
`github.token` or `secrets.GITHUB_TOKEN`. A github-script step counts unless
its `github-token:` is something else.

API calls: `gh <verb>`, and curl to api.github.com or to a variable that holds
the API URL: GITHUB_API_URL, an env value (step, job or workflow) that carries
`github.api_url` or api.github.com, or a shell assignment of either.

Scripts in the repository: a loop that runs a script file (`scripts/x.sh`,
`./scripts/x.sh`, `bash|sh|python3|node|bun scripts/x`) takes on the script's
API calls and sleeps, and that script's own scripts' in turn. A script the step
runs anywhere is also read for its own polling loops, judged by the step's
token. A script run through a variable (`$SCRIPT`) is not followed.

Not caught: Python `requests` or `http.client`, an argv built as `["gh"] + args`, JavaScript
class methods, `eval`, and script paths held in variables. No workflow polls through these
today; a reviewer catches a new one.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path
from typing import Iterable, Iterator

import yaml

OWN_TOKEN = re.compile(r"\$\{\{[^}]*\b(github\.token|secrets\.GITHUB_TOKEN)\b[^}]*\}\}")
SHELL_API = re.compile(r"^(gh)$")
GH_VERBS = {"api", "run", "pr", "issue", "release", "workflow", "label", "search", "cache"}
API_TEXT = re.compile(r"api\.github\.com")
API_URL_VALUE = re.compile(r"github\.api_url|api\.github\.com|\$\{?GITHUB_API_URL\b")
SCRIPT_PATH = re.compile(r"^(?:\./)?((?:scripts|\.github)/[\w./-]+\.(?:sh|bash|py|js|mjs|cjs|ts))$")
INTERPRETERS = {"bash", "sh", "python", "python3", "node", "bun", "ruby", "source", "."}
SEPARATORS = {";", "&&", "||", "|", "(", "$(", "{", "then", "else", "elif", "do", "!", "`", "&", "if", "while",
              "until", "time"}


# ------------------------------------------------------------------ token

def scope_value(name: str, step: dict, job: dict, workflow: dict) -> str | None:
    """The innermost value of an env name the step sees (step, then job, then workflow), or None."""
    for scope in (step.get("env") or {}, job.get("env") or {}, workflow.get("env") or {}):
        if name in scope:
            return str(scope[name] if scope[name] is not None else "")
    return None


def calls_with_own_token(step: dict, job: dict, workflow: dict, script: str = "") -> bool:
    """Whether the step's API calls can use github.token (see the module docstring)."""
    gh_token = scope_value("GH_TOKEN", step, job, workflow)
    github_token = scope_value("GITHUB_TOKEN", step, job, workflow) or ""
    gh_uses = gh_token if gh_token and gh_token.strip() else github_token
    if OWN_TOKEN.search(gh_uses):
        return True
    names_it = re.search(r"\$\{?GITHUB_TOKEN\b|environ(?:\.get\(|\[)\s*['\"]GITHUB_TOKEN", script)
    return bool(names_it and OWN_TOKEN.search(github_token))


# ------------------------------------------------------------------ shell

def shell_words(text: str) -> list[tuple[str, int]]:
    """The shell's words and operators with their offsets: quoted text joins its word but is not a
    keyword, comments and heredoc bodies are dropped, and `$(` opens a nested command."""
    words: list[tuple[str, int]] = []
    i, n = 0, len(text)
    current, start, quoted = "", -1, False
    pending_heredocs: list[tuple[str, bool, int]] = []

    def flush() -> None:
        nonlocal current, start, quoted
        if start >= 0:
            words.append(("\0" + current if quoted else current, start))
        current, start, quoted = "", -1, False

    while i < n:
        c = text[i]
        if c == "\n":
            flush()
            words.append((";", i))
            i += 1
            for delimiter, strip, index in pending_heredocs:
                end = text.find("\n", i)
                body: list[str] = []
                while True:
                    line_end = n if end < 0 else end
                    line = text[i:line_end]
                    i = line_end + 1
                    if (line.lstrip("\t") if strip else line) == delimiter or line_end >= n:
                        break
                    body.append(line)
                    end = text.find("\n", i)
                word, offset = words[index]
                words[index] = (word + "\0" + "\n".join(body), offset)
            pending_heredocs = []
            continue
        if c in " \t":
            flush()
            i += 1
            continue
        if c == "#" and start < 0:
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "\\" and i + 1 < n:
            if start < 0:
                start = i
            current += text[i + 1] if text[i + 1] != "\n" else ""
            i += 2
            continue
        if c == "'":
            end = text.find("'", i + 1)
            end = n if end < 0 else end
            if start < 0:
                start = i
            current, quoted, i = current + text[i + 1:end], True, end + 1
            continue
        if c == '"':
            j, depth = i + 1, 0
            while j < n and (text[j] != '"' or depth):
                if text[j] == "\\":
                    j += 2
                    continue
                if text.startswith("$(", j):
                    depth += 1
                elif text[j] == ")" and depth:
                    depth -= 1
                j += 1
            inner = text[i + 1:j]
            # A command substitution inside the quotes is code: read it as its own words.
            for match in re.finditer(r"\$\(", inner):
                sub_start = i + 1 + match.start()
                words.extend(nested_substitution(text, sub_start))
            if start < 0:
                start = i
            current, quoted, i = current + re.sub(r"\$\([^)]*\)?", "", inner), True, j + 1
            continue
        if text.startswith("<<", i) and not text.startswith("<<<", i):
            flush()
            m = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][\w]*)\2", text[i:])
            if m:
                pending_heredocs.append((m.group(3), m.group(1) == "-", len(words)))
                words.append(("<<" + m.group(3), i))
                i += m.end()
                continue
        for op in ("$(", "&&", "||", ";;", ";", "|", "(", ")", "`", "&", "{", "}"):
            if text.startswith(op, i) and (op not in "{}" or start < 0 and (i + 1 >= n or text[i + 1] in " \t\n;")):
                flush()
                words.append((op, i))
                i += len(op)
                break
        else:
            if start < 0:
                start = i
            current += c
            i += 1
    flush()
    return words


def nested_substitution(text: str, at: int) -> list[tuple[str, int]]:
    """The words of the `$(...)` that starts at `at`, offsets kept."""
    depth, j = 0, at
    while j < len(text):
        if text.startswith("$(", j):
            depth += 1
            j += 2
            continue
        if text[j] == ")":
            depth -= 1
            if depth == 0:
                break
        j += 1
    return [(word, at + 2 + offset) for word, offset in shell_words(text[at + 2:j])] + [(";", j)]


def command_positions(words: list[tuple[str, int]]) -> list[bool]:
    """Whether each word starts a command."""
    out, expect = [], True
    for word, _ in words:
        out.append(expect and not word.startswith("\0"))
        expect = word in SEPARATORS or (expect and re.fullmatch(r"[A-Za-z_]\w*=.*", word) is not None)
    return out


def shell_blocks(words: list[tuple[str, int]]) -> tuple[list[list[str]], dict[str, list[str]]]:
    """(each loop's words, each function's words) from a shell word list."""
    starts = command_positions(words)
    plain = [w.lstrip("\0") if not w.startswith("\0") else w for w, _ in words]
    loops: list[list[str]] = []
    functions: dict[str, list[str]] = {}
    for index, word in enumerate(plain):
        if starts[index] and word in ("for", "while", "until"):
            depth, end = 0, len(plain)
            for j in range(index + 1, len(plain)):
                if starts[j] and plain[j] == "do":
                    depth += 1
                elif starts[j] and plain[j] == "done":
                    depth -= 1
                    if depth <= 0:
                        end = j + 1
                        break
            loops.append(plain[index:end])
        name = None
        if starts[index] and word == "function" and index + 1 < len(plain):
            name = plain[index + 1].removesuffix("()")
        elif starts[index] and index + 2 < len(plain) and plain[index + 1] == "(" and plain[index + 2] == ")":
            name = word
        elif starts[index] and word.endswith("()") and len(word) > 2:
            name = word[:-2]
        if name and re.fullmatch(r"[A-Za-z_][\w-]*", name):
            j = index + 1
            while j < len(plain) and plain[j] != "{":
                j += 1
            depth, end = 0, len(plain)
            for k in range(j, len(plain)):
                if plain[k] == "{":
                    depth += 1
                elif plain[k] == "}":
                    depth -= 1
                    if depth == 0:
                        end = k + 1
                        break
            functions[name] = plain[j:end]
    return loops, functions


def shell_calls(block: list[str], names: Iterable[str]) -> set[str]:
    starts = command_positions([(w, 0) for w in block])
    wanted = set(names)
    return {w for w, start in zip(block, starts) if start and w in wanted}


def shell_sleeps(block: list[str]) -> bool:
    starts = command_positions([(w, 0) for w in block])
    return any(start and w == "sleep" for w, start in zip(block, starts))


def api_url_pattern(names: Iterable[str]) -> re.Pattern[str]:
    """Text naming the API: api.github.com, or $NAME / ${NAME} for a variable holding its URL."""
    alternatives = sorted({"GITHUB_API_URL", *names})
    return re.compile(r"api\.github\.com|\$\{?(?:" + "|".join(map(re.escape, alternatives)) + r")\b")


def api_url_names(script: str, scopes: Iterable[dict] = ()) -> set[str]:
    """Variables that hold the API URL: env values (any scope given) and shell assignments in the script."""
    names = {"GITHUB_API_URL"}
    for scope in scopes:
        for name, value in (scope or {}).items():
            if API_URL_VALUE.search(str(value or "")):
                names.add(str(name))
    changed = True
    while changed:
        changed = False
        url = api_url_pattern(names)
        for match in re.finditer(r"(?m)(?:^|[\s;(])(?:local\s+|export\s+|readonly\s+)?([A-Za-z_]\w*)=(\S+)", script):
            if match.group(1) not in names and (API_URL_VALUE.search(match.group(2)) or url.search(match.group(2))):
                names.add(match.group(1))
                changed = True
    return names


def shell_api(block: list[str], api_url: re.Pattern[str] = API_TEXT) -> bool:
    starts = command_positions([(w, 0) for w in block])
    for index, (word, start) in enumerate(zip(block, starts)):
        if start and word == "gh" and index + 1 < len(block) and block[index + 1] in GH_VERBS:
            return True
        if start and word == "curl" and any(api_url.search(w) for w in block[index + 1:index + 30]
                                            if not w.startswith("<<")):
            return True
    return False


def heredoc_effects(block: list[str]) -> tuple[bool, bool]:
    """Whether a Python, node or bun heredoc fed by a command in the block calls the API, and whether one sleeps."""
    starts = command_positions([(w, 0) for w in block])
    calls = sleeps = False
    command = ""
    for word, start in zip(block, starts):
        if start:
            command = word.lstrip("\0")
        if not (word.startswith("<<") and "\0" in word):
            continue
        body = word.split("\0", 1)[1]
        name = command.rsplit("/", 1)[-1]
        if name.startswith("python"):
            c, z, _ = python_effects(body)
        elif name in ("node", "bun"):
            code = js_code(body)
            c, z = bool(JS_API.search(code)), bool(JS_SLEEP.search(code))
        else:
            continue
        calls, sleeps = calls or c, sleeps or z
    return calls, sleeps


def script_paths(block: list[str]) -> list[str]:
    """Repository script files the block runs: in command position, or after an interpreter."""
    starts = command_positions([(w, 0) for w in block])
    found = []
    for index, (word, start) in enumerate(zip(block, starts)):
        if not start:
            continue
        candidates = [word]
        if word in INTERPRETERS:
            candidates = [w for w in block[index + 1:index + 4] if not w.startswith("-")][:1]
        for candidate in candidates:
            match = SCRIPT_PATH.match(candidate.lstrip("\0"))
            if match:
                found.append(match.group(1))
    return found


class Scripts:
    """Reads repository scripts once and says whether each (with the scripts it runs) calls the API or sleeps."""

    def __init__(self, root: Path | None) -> None:
        self.root = root
        self.cache: dict[tuple[str, frozenset[str]], tuple[bool, bool, list[str], str]] = {}

    def read(self, path: str, names: Iterable[str] = ()) -> tuple[bool, bool, list[str], str]:
        """(calls the API, sleeps, scripts it runs, text) for one file, without following those scripts.

        `names` are the variables the caller's environment sets to the API URL (api_url_names)."""
        key = (path, frozenset(names))
        if key in self.cache:
            return self.cache[key]
        file = self.root / path if self.root else None
        if not file or not file.is_file():
            self.cache[key] = (False, False, [], "")
            return self.cache[key]
        text = file.read_text(encoding="utf-8", errors="replace")
        if path.endswith(".py"):
            calls, sleeps, runs = python_effects(text)
        elif path.endswith((".js", ".mjs", ".cjs", ".ts")):
            code = js_code(text)
            calls, sleeps, runs = bool(JS_API.search(code)), bool(JS_SLEEP.search(code)), []
        else:
            words = [w.lstrip("\0") if not w.startswith("\0") else w for w, _ in shell_words(text)]
            url = api_url_pattern(api_url_names(text) | set(names))
            here_calls, here_sleeps = heredoc_effects(words)
            calls = shell_api(words, url) or here_calls
            sleeps, runs = shell_sleeps(words) or here_sleeps, script_paths(words)
        self.cache[key] = (calls, sleeps, runs, text)
        return self.cache[key]

    def effects(self, paths: Iterable[str], names: Iterable[str] = ()) -> tuple[bool, bool]:
        """Whether running these scripts calls the API, and whether it sleeps, scripts they run included."""
        calls = sleeps = False
        seen: set[str] = set()
        todo = list(paths)
        while todo:
            path = todo.pop()
            if path in seen:
                continue
            seen.add(path)
            c, z, runs, _ = self.read(path, names)
            calls, sleeps = calls or c, sleeps or z
            todo.extend(runs)
        return calls, sleeps

    def closure(self, paths: Iterable[str]) -> list[str]:
        """These scripts and every repository script they run, in the order first seen."""
        seen: list[str] = []
        todo = list(paths)
        while todo:
            path = todo.pop(0)
            if path in seen:
                continue
            seen.append(path)
            todo.extend(self.read(path)[2])
        return seen


def python_effects(text: str) -> tuple[bool, bool, list[str]]:
    """(calls the API, sleeps, scripts it runs) anywhere in a Python file."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return False, False, []
    calls = sleeps = False
    runs = []
    for call in (n for n in ast.walk(tree) if isinstance(n, ast.Call)):
        calls = calls or python_call_is_api(call)
        sleeps = sleeps or dotted(call.func).split(".")[-1] == "sleep"
        for arg in call.args:
            if isinstance(arg, ast.List):
                for element in arg.elts[:3]:
                    if isinstance(element, ast.Constant) and isinstance(element.value, str):
                        match = SCRIPT_PATH.match(element.value)
                        if match:
                            runs.append(match.group(1))
    return calls, sleeps, runs


def heredoc_programs(text: str) -> Iterator[tuple[str, str]]:
    """(language, body) of each heredoc fed to python, node or bun."""
    for match in re.finditer(r"(?m)^[^\n#]*\b(python3?|node|bun)\b[^\n]*<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\3[^\n]*\n", text):
        language = "python" if match.group(1).startswith("python") else "js"
        delimiter, strip = match.group(4), match.group(2) == "-"
        body = []
        for line in text[match.end():].split("\n"):
            if (line.lstrip("\t") if strip else line).strip() == delimiter:
                break
            body.append(line)
        yield language, "\n".join(body)


def shell_polls(text: str, env_scopes: Iterable[dict] = (), scripts: Scripts | None = None) -> str | None:
    words = shell_words(text)
    loops, functions = shell_blocks(words)
    env_scopes = list(env_scopes)
    names = api_url_names(text, env_scopes)
    url = api_url_pattern(names)
    scripts = scripts or Scripts(None)
    env_names = api_url_names("", env_scopes)
    for loop in loops:
        seen, todo, calls_api, sleeps = set(), [loop], False, False
        while todo:
            block = todo.pop()
            calls_api = calls_api or shell_api(block, url)
            sleeps = sleeps or shell_sleeps(block)
            script_calls, script_sleeps = scripts.effects(script_paths(block), env_names)
            here_calls, here_sleeps = heredoc_effects(block)
            calls_api = calls_api or script_calls or here_calls
            sleeps = sleeps or script_sleeps or here_sleeps
            for name in shell_calls(block, functions) - seen:
                seen.add(name)
                todo.append(functions[name])
        if calls_api and sleeps:
            return " ".join(loop[:6])
    for language, body in heredoc_programs(text):
        found = python_polls(body) if language == "python" else js_polls(body)
        if found:
            return found
    return None


# ------------------------------------------------------------------ Python

def dotted(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{dotted(node.value)}.{node.attr}"
    return ""


def python_call_is_api(call: ast.Call) -> bool:
    name = dotted(call.func)
    if name.endswith("urlopen") or name.split(".")[-1] in ("gh_json", "gh_api", "gh_run", "gh_items"):
        return True
    for arg in call.args:
        if isinstance(arg, ast.List) and len(arg.elts) >= 2 and isinstance(arg.elts[0], ast.Constant) \
                and arg.elts[0].value == "gh":
            verb = arg.elts[1]
            # ["gh", "api", ...] names its verb; ["gh", *args] (a wrapper) may run any of them.
            if not isinstance(verb, ast.Constant) or verb.value in GH_VERBS:
                return True
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and API_TEXT.search(arg.value):
            return True
    return False


def python_aliases(tree: ast.AST) -> dict[str, set[str]]:
    """Names bound to another callable: a parameter's default (`opener=urllib.request.urlopen`,
    `api=http_api`) or an assignment (`fetch = urlopen`), name -> the dotted targets."""
    aliases: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            args = node.args
            positional = args.posonlyargs + args.args
            for arg, default in zip(positional[len(positional) - len(args.defaults):], args.defaults):
                if dotted(default):
                    aliases.setdefault(arg.arg, set()).add(dotted(default))
            for arg, default in zip(args.kwonlyargs, args.kw_defaults):
                if default is not None and dotted(default):
                    aliases.setdefault(arg.arg, set()).add(dotted(default))
        elif isinstance(node, ast.Assign) and dotted(node.value):
            for target in node.targets:
                name = dotted(target).split(".")[-1]
                if name:
                    aliases.setdefault(name, set()).add(dotted(node.value))
    return aliases


def python_polls(text: str) -> str | None:
    """The first line of a loop that sleeps and calls the API, following the file's own functions:
    module functions called by name, methods called as an attribute (`self.jobs()`, `api.jobs()`),
    and callables bound to a name by a parameter default or an assignment."""
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    defs = (ast.FunctionDef, ast.AsyncFunctionDef)
    functions = {node.name: node for node in tree.body if isinstance(node, defs)}
    methods: dict[str, list[ast.AST]] = {}
    for cls in (n for n in ast.walk(tree) if isinstance(n, ast.ClassDef)):
        for node in cls.body:
            if isinstance(node, defs):
                methods.setdefault(node.name, []).append(node)
    aliases = python_aliases(tree)

    def resolve(call: ast.Call) -> tuple[bool, list[ast.AST]]:
        """Whether the call reaches the API through an alias, and the file's functions it may run."""
        name = dotted(call.func)
        last = name.split(".")[-1]
        api, bodies = False, []
        if isinstance(call.func, ast.Name) and name in functions:
            bodies.append(functions[name])
        if isinstance(call.func, ast.Attribute):
            bodies += methods.get(last, [])
        for target in aliases.get(last, ()):
            short = target.split(".")[-1]
            api = api or target.endswith("urlopen") or short in ("gh_json", "gh_api", "gh_run", "gh_items")
            if short in functions:
                bodies.append(functions[short])
            bodies += methods.get(short, [])
        return api, bodies

    for node in ast.walk(tree):
        if not isinstance(node, (ast.For, ast.While, ast.AsyncFor)):
            continue
        seen: set[int] = set()
        todo, calls_api, sleeps = [node], False, False
        while todo:
            for call in (n for n in ast.walk(todo.pop()) if isinstance(n, ast.Call)):
                name = dotted(call.func)
                sleeps = sleeps or name.split(".")[-1] == "sleep"
                via_alias, bodies = resolve(call)
                calls_api = calls_api or via_alias or python_call_is_api(call)
                for body in bodies:
                    if id(body) not in seen:
                        seen.add(id(body))
                        todo.append(body)
        if calls_api and sleeps:
            return ast.get_source_segment(text, node).splitlines()[0].strip()
    return None


# ------------------------------------------------------------------ JavaScript

def js_code(text: str) -> str:
    """The text with strings, template text and comments blanked (offsets kept); `${...}` stays code."""
    out, i, n = list(text), 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            for k in range(i, end):
                out[k] = " " if text[k] != "\n" else "\n"
            i = end
            continue
        if c in "'\"`":
            j = i + 1
            while j < n and text[j] != c:
                if text[j] == "\\":
                    j += 2
                    continue
                if c == "`" and text.startswith("${", j):
                    depth, j = 1, j + 2
                    while j < n and depth:
                        depth += {"{": 1, "}": -1}.get(text[j], 0)
                        j += 1
                    continue
                if text[j] != "\n":
                    out[j] = " "
                j += 1
            i = j + 1
            continue
        i += 1
    return "".join(out)


def js_block(code: str, at: int) -> str:
    """From `at` to the brace that closes the first `{` after it (a one-statement body to its `;`)."""
    paren, j = 0, at
    while j < len(code):
        if code[j] == "(":
            paren += 1
        elif code[j] == ")":
            paren -= 1
            if paren == 0:
                break
        j += 1
    k = j + 1
    while k < len(code) and code[k] in " \t\n":
        k += 1
    if k < len(code) and code[k] == "{":
        depth = 0
        for m in range(k, len(code)):
            depth += {"{": 1, "}": -1}.get(code[m], 0)
            if depth == 0:
                return code[at:m + 1]
    end = code.find(";", k)
    return code[at:len(code) if end < 0 else end + 1]


JS_LOOP = re.compile(r"(?<![\w$.])(for|while)\s*\(")
JS_FUNCTION = re.compile(r"(?<![\w$.])(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\("
                         r"|(?<![\w$.])(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>")
JS_API = re.compile(r"(?<![\w$])github\.(rest|graphql|request|paginate)\b")
JS_SLEEP = re.compile(r"(?<![\w$.])(setTimeout|sleep)\s*\(")


def js_functions(code: str) -> dict[str, str]:
    found = {}
    for match in JS_FUNCTION.finditer(code):
        name = match.group(1) or match.group(2)
        start = match.start()
        if match.group(1):
            found[name] = js_block(code, code.index("(", match.end() - 1))
        else:
            arrow = code.index("=>", start) + 2
            k = arrow
            while k < len(code) and code[k] in " \t\n":
                k += 1
            if k < len(code) and code[k] == "{":
                depth = 0
                for m in range(k, len(code)):
                    depth += {"{": 1, "}": -1}.get(code[m], 0)
                    if depth == 0:
                        found[name] = code[start:m + 1]
                        break
            else:
                end = code.find("\n", k)
                found[name] = code[start:len(code) if end < 0 else end]
    return found


def js_polls(text: str) -> str | None:
    code = js_code(text)
    functions = js_functions(code)
    for match in JS_LOOP.finditer(code):
        loop = js_block(code, code.index("(", match.start()))
        seen, todo, calls_api, sleeps = set(), [loop], False, False
        while todo:
            block = todo.pop()
            calls_api = calls_api or bool(JS_API.search(block))
            sleeps = sleeps or bool(JS_SLEEP.search(block))
            for name in functions:
                if name not in seen and re.search(rf"(?<![\w$.]){re.escape(name)}\s*\(", block):
                    seen.add(name)
                    todo.append(functions[name])
        if calls_api and sleeps:
            return text[match.start():].splitlines()[0].strip()
    return None


# ------------------------------------------------------------------ workflows

def step_polls(step: dict, job: dict, workflow: dict, scripts: Scripts | None = None) -> str | None:
    """The first line of the step's polling loop on github.token, else None."""
    scripts = scripts or Scripts(None)
    with_ = step.get("with") or {}
    if str(step.get("uses", "")).startswith("actions/github-script"):
        token = with_.get("github-token")
        if token is not None and not OWN_TOKEN.search(str(token)):
            return None
        return js_polls(str(with_.get("script", "")))
    script = str(step.get("run", "") or "")
    if not script:
        return None
    shell = str(step.get("shell") or (job.get("defaults") or {}).get("run", {}).get("shell") or "")
    runs = [] if shell.startswith("python") else scripts.closure(
        script_paths([w.lstrip("\0") if not w.startswith("\0") else w for w, _ in shell_words(script)]))
    every_text = script + "".join(scripts.read(path)[3] for path in runs)
    if not calls_with_own_token(step, job, workflow, every_text):
        return None
    if shell.startswith("python"):
        return python_polls(script)
    scopes = (step.get("env") or {}, job.get("env") or {}, workflow.get("env") or {})
    found = shell_polls(script, scopes, scripts)
    if found:
        return found
    for path in runs:
        text = scripts.read(path)[3]
        if path.endswith(".py"):
            found = python_polls(text)
        elif path.endswith((".js", ".mjs", ".cjs", ".ts")):
            found = js_polls(text)
        else:
            found = shell_polls(text, scopes, scripts)
        if found:
            return f"{path}: {found}"
    return None


def polling_steps(workflows: Path) -> dict[str, str]:
    found = {}
    scripts = Scripts(workflows.parent.parent)
    for path in sorted(workflows.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (workflow.get("jobs") or {}).values():
            for index, step in enumerate(job.get("steps") or []):
                line = step_polls(step, job, workflow, scripts)
                if line:
                    found[f"{path.name}: {step.get('name') or f'step {index + 1}'}"] = line
    return found
