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

Not caught: a sleep or call inside a separate script file the loop runs.
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
    pending_heredocs: list[tuple[str, bool]] = []

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
            for delimiter, strip in pending_heredocs:
                end = text.find("\n", i)
                while True:
                    line_end = n if end < 0 else end
                    line = text[i:line_end]
                    i = line_end + 1
                    if (line.lstrip("\t") if strip else line) == delimiter or line_end >= n:
                        break
                    end = text.find("\n", i)
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
                pending_heredocs.append((m.group(3), m.group(1) == "-"))
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


def shell_api(block: list[str]) -> bool:
    starts = command_positions([(w, 0) for w in block])
    for index, (word, start) in enumerate(zip(block, starts)):
        if start and word == "gh" and index + 1 < len(block) and block[index + 1] in GH_VERBS:
            return True
        if start and word == "curl" and any(API_TEXT.search(w) for w in block[index + 1:index + 30]):
            return True
    return False


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


def shell_polls(text: str) -> str | None:
    words = shell_words(text)
    loops, functions = shell_blocks(words)
    for loop in loops:
        seen, todo, calls_api, sleeps = set(), [loop], False, False
        while todo:
            block = todo.pop()
            calls_api = calls_api or shell_api(block)
            sleeps = sleeps or shell_sleeps(block)
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
        if isinstance(arg, ast.List) and len(arg.elts) >= 2 and all(isinstance(e, ast.Constant) for e in arg.elts[:2]):
            if arg.elts[0].value == "gh" and arg.elts[1].value in GH_VERBS:
                return True
        if isinstance(arg, ast.Constant) and isinstance(arg.value, str) and API_TEXT.search(arg.value):
            return True
    return False


def python_polls(text: str) -> str | None:
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return None
    functions = {node.name: node for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                 and node in tree.body}
    for node in ast.walk(tree):
        if not isinstance(node, (ast.For, ast.While, ast.AsyncFor)):
            continue
        seen, todo, calls_api, sleeps = set(), [node], False, False
        while todo:
            for call in (n for n in ast.walk(todo.pop()) if isinstance(n, ast.Call)):
                name = dotted(call.func)
                sleeps = sleeps or name.split(".")[-1] == "sleep"
                calls_api = calls_api or python_call_is_api(call)
                if isinstance(call.func, ast.Name) and name in functions and name not in seen:
                    seen.add(name)
                    todo.append(functions[name])
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

def step_polls(step: dict, job: dict, workflow: dict) -> str | None:
    """The first line of the step's polling loop on github.token, else None."""
    with_ = step.get("with") or {}
    if str(step.get("uses", "")).startswith("actions/github-script"):
        token = with_.get("github-token")
        if token is not None and not OWN_TOKEN.search(str(token)):
            return None
        return js_polls(str(with_.get("script", "")))
    script = str(step.get("run", "") or "")
    if not script or not calls_with_own_token(step, job, workflow, script):
        return None
    shell = str(step.get("shell") or (job.get("defaults") or {}).get("run", {}).get("shell") or "")
    if shell.startswith("python"):
        return python_polls(script)
    return shell_polls(script)


def polling_steps(workflows: Path) -> dict[str, str]:
    found = {}
    for path in sorted(workflows.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (workflow.get("jobs") or {}).values():
            for index, step in enumerate(job.get("steps") or []):
                line = step_polls(step, job, workflow)
                if line:
                    found[f"{path.name}: {step.get('name') or f'step {index + 1}'}"] = line
    return found
