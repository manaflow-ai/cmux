#!/usr/bin/env python3
"""The cold-model test for the extension-author recipes (cmuxterm-hq extensions DESIGN.md section 12).

For each page in skills/cmux-extension-author/recipes, a small model (Claude Haiku by default) gets
only that page, in a fresh empty folder, and is told to build the extension it describes and run
`cmux ext dev --once --json` until it passes. Then this script runs `cmux ext dev --once --json`
itself and checks: exit 0 (`ok`), and that the first scene shows the words the page's
`<!-- recipe-check: shows "..." -->` line names. A page a small model fails is a docs bug or an
API bug; the report names the page, the exit code, the errors and the model's last words.

Opt-in: it calls a model, so it never runs in PR CI. It needs:
  - `claude` (Claude Code) on PATH, signed in or with ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN
    (as scripts/ci/chief-first-turn-cost.sh and .github/workflows/cloud-claude-matrix.yml run it);
  - `cmux` on PATH and a running cmux to load into. With no cmux running, `ext dev --once` exits 3
    after the manifest and build pass; `--no-daemon-ok` counts that as a pass of those two phases.

  python3 scripts/cmux-next/ext-recipe-cold-model.py [--recipe section] [--model haiku]
      [--no-daemon-ok] [--headless] [--keep] [--json]

`--prompts` checks the copy-paste prompts (skills/cmux-extension-author/prompts) instead: the model
gets only the page's prompt, as a person would paste it, and finds the rest with
`cmux customize docs`; the page's prompt-check names the expected scene text or command behavior.
`--headless` checks with `cmux ext dev --once --headless --json`, which loads and renders in this
process, so it needs no running cmux (the scheduled customize-prompts-cold-model workflow runs
`--prompts --headless` on a Linux runner).

Each row also records how the agent got there: `wallSeconds`, `docReads` (its `cmux customize
docs|prompts` calls), `sourceReads` (a file read or search outside its folder: the docs did not say
it), `guesses` (a tool call that came back an error, such as a denied tool, an unknown docs surface or
a failed command, not counting `ext dev`) and `devRuns`. Every source read and every guess is a docs
bug: `docsBugs` is their sum, and `--max-docs-bugs N` fails a page past N.

Exit 0 when every page passes, 1 when one fails, 2 when a tool is missing.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from ext_prompt_composer import check_composer
from ext_prompt_palette import check_palette

ROOT = Path(__file__).resolve().parents[2]
RECIPES = ROOT / "skills" / "cmux-extension-author" / "recipes"
PROMPTS = ROOT / "skills" / "cmux-extension-author" / "prompts"
COMMAND_CHECKS = {"command standup note": check_palette, "composer /review": check_composer}
SHOWS = re.compile(r'shows "([^"]+)"')
PROMPT_BLOCK = re.compile(r"```text\n(.*?)\n```", re.S)
TIMEOUT_S = 600

PROMPT = """You are in an empty folder. Build the cmux extension this page describes, in this folder,
by following the page. Write the files it names. Then run `cmux ext dev --once --json` and read its
JSON; if it does not exit 0, fix what `errors` names and run it again, until it exits 0 or you have
tried five times. Do not install packages. Reply with one line: done, or what stopped you.

--- the page ---
{page}
"""


SEARCH = re.compile(r"\b(?:cat|grep|rg|find|head|tail|sed|less)\b")


def trace(stream: str, folder: Path) -> tuple[dict, str]:
    """What the agent did, from Claude Code's stream-json events, and its last words."""
    calls: dict[str, tuple[str, dict]] = {}
    counts = {"docReads": 0, "sourceReads": 0, "guesses": 0, "devRuns": 0}
    said = ""
    inside = str(folder.resolve())
    for line in stream.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "result":
            said = str(event.get("result") or "")
        content = (event.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict):
                continue
            if item.get("type") == "tool_use":
                name, given = item.get("name", ""), item.get("input") or {}
                calls[item.get("id", "")] = (name, given)
                command = str(given.get("command", ""))
                path = str(given.get("file_path") or given.get("path") or "")
                if name == "Bash" and "cmux customize " in command:
                    counts["docReads"] += 1
                elif name == "Bash" and "cmux ext dev" in command:
                    counts["devRuns"] += 1
                elif name in ("Grep", "Glob") or (name == "Bash" and SEARCH.search(command)):
                    counts["sourceReads"] += 1
                elif name == "Read" and path and not str(Path(path).resolve()).startswith(inside):
                    counts["sourceReads"] += 1
            elif item.get("type") == "tool_result" and item.get("is_error"):
                name, given = calls.get(item.get("tool_use_id", ""), ("", {}))
                if not (name == "Bash" and "cmux ext dev" in str(given.get("command", ""))):
                    counts["guesses"] += 1
    counts["docsBugs"] = counts["sourceReads"] + counts["guesses"]
    return counts, said


def run_model(prompt: str, folder: Path, model: str) -> tuple[int, str, dict]:
    started = time.monotonic()
    argv = [
        "claude", "-p", prompt,
        "--model", model,
        "--output-format", "stream-json", "--verbose",
        "--allowedTools",
        "Read,Write,Edit,Bash(cmux ext dev:*),Bash(cmux customize docs:*),Bash(cmux customize prompts:*),"
        "Bash(mkdir:*),Bash(ls:*)",
        "--max-turns", "30",
    ]
    try:
        done = subprocess.run(argv, cwd=folder, capture_output=True, text=True, timeout=TIMEOUT_S)
        code, stream, stderr = done.returncode, done.stdout or "", done.stderr or ""
    except subprocess.TimeoutExpired as expired:
        code, stream = 124, expired.stdout.decode() if isinstance(expired.stdout, bytes) else (expired.stdout or "")
        stderr = f"the model did not finish in {TIMEOUT_S} s"
    counts, said = trace(stream, folder)
    counts["wallSeconds"] = round(time.monotonic() - started, 1)
    return code, (said or stderr).strip()[-2000:], counts


def page_check(page: str, prompts: bool) -> str:
    kind = "prompt" if prompts else "recipe"
    checks = re.findall(rf"^<!-- {kind}-check: (.+) -->$", page, re.MULTILINE)
    if len(checks) == 1:
        check = checks[0]
        if SHOWS.fullmatch(check) or check in COMMAND_CHECKS or (not prompts and check == "loads"):
            return check
    raise ValueError(f"expected one supported {kind}-check, got {checks!r}")


def check(folder: Path, expectation: str, no_daemon_ok: bool, headless: bool,
          *, prompts: bool = False) -> dict:
    argv = ["cmux", "ext", "dev", "--once", "--json"]

    def run(options: list[str]) -> subprocess.CompletedProcess:
        return subprocess.run(argv + options, cwd=folder, capture_output=True, text=True, timeout=300)

    done = run(["--headless"] if headless else ["--no-install", "--remove-on-exit"])
    if prompts and no_daemon_ok and not headless and done.returncode == 3:
        done = run(["--headless"])
    try:
        result = json.loads(done.stdout.strip().splitlines()[-1])
        if not isinstance(result, dict):
            raise ValueError("expected a JSON object")
    except (ValueError, IndexError):
        errors = [done.stderr[-2000:] or "ext dev returned no JSON object"]
        return {"exitCode": done.returncode, "passed": False, "why": "invalid ext dev result",
                "errors": errors, "scene": ""}
    code = done.returncode
    scene = "\n".join(result.get("scene") or [])
    why = None
    if code == 0:
        shows = SHOWS.fullmatch(expectation)
        if shows and shows.group(1) not in scene:
            why = f"the scene does not show {shows.group(1)!r}"
        elif expectation in COMMAND_CHECKS:
            why = COMMAND_CHECKS[expectation](folder)
        elif not shows and expectation != "loads":
            why = f"unknown expectation {expectation!r}"
    elif not (code == 3 and no_daemon_ok and not prompts):
        why = f"exit {code}"
    return {"exitCode": code, "passed": why is None, "why": why, "errors": result.get("errors"), "scene": scene}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--recipe", action="append", help="a page's name (section, widget, ...); default every page")
    parser.add_argument("--model", default="haiku")
    parser.add_argument("--prompts", action="store_true", help="check the copy-paste prompts, not the recipes")
    parser.add_argument("--no-daemon-ok", action="store_true")
    parser.add_argument("--headless", action="store_true", help="check with ext dev --once --headless (no cmux)")
    parser.add_argument("--keep", action="store_true", help="keep each page's folder and print it")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--max-docs-bugs", type=int, default=None,
                        help="fail a page whose agent read source or guessed more than N times")
    args = parser.parse_args()

    for tool in ("claude", "cmux"):
        if not shutil.which(tool):
            print(f"ext-recipe-cold-model: {tool} is not on PATH", file=sys.stderr)
            return 2
    pages = sorted(p for p in (PROMPTS if args.prompts else RECIPES).glob("*.md") if p.stem != "README")
    if args.recipe:
        wanted = {name.removesuffix(".md") for name in args.recipe}
        pages = [p for p in pages if p.stem in wanted]
        missing = wanted - {p.stem for p in pages}
        if missing:
            kind = "prompt" if args.prompts else "recipe"
            print(f"ext-recipe-cold-model: no {kind} {', '.join(sorted(missing))}", file=sys.stderr)
            return 2

    report = []
    for page in pages:
        text = page.read_text(encoding="utf-8")
        try:
            expectation = page_check(text, args.prompts)
        except ValueError as error:
            print(f"ext-recipe-cold-model: {page.name}: {error}", file=sys.stderr)
            return 2
        folder = Path(tempfile.mkdtemp(prefix=f"cold-{page.stem}-"))
        if args.prompts:
            block = PROMPT_BLOCK.search(text)
            if not block:
                print(f"ext-recipe-cold-model: {page.name} has no ```text prompt", file=sys.stderr)
                return 2
            prompt = block.group(1) + "\nDo not install packages. End with one line: done, or what stopped you.\n"
        else:
            prompt = PROMPT.format(page=text)
        model_exit, said, counts = run_model(prompt, folder, args.model)
        row = {"recipe": page.stem, "model": args.model, "modelExit": model_exit, "said": said, **counts}
        row.update(check(folder, expectation, args.no_daemon_ok, args.headless, prompts=args.prompts))
        if row["passed"] and args.max_docs_bugs is not None and counts["docsBugs"] > args.max_docs_bugs:
            row["passed"] = False
            row["why"] = f"{counts['docsBugs']} source reads or guesses (at most {args.max_docs_bugs})"
        if args.keep:
            row["folder"] = str(folder)
        else:
            shutil.rmtree(folder, ignore_errors=True)
        report.append(row)
        if not args.json:
            verdict = "pass" if row["passed"] else f"FAIL ({row['why']})"
            verdict += f"  {counts['wallSeconds']} s, {counts['sourceReads']} source reads, {counts['guesses']} guesses"
            print(f"{page.stem}: {verdict}" + (f"  {folder}" if args.keep else ""))
            if not row["passed"]:
                print(f"  errors: {row['errors']}\n  model: {said[-400:]}")
    if args.json:
        print(json.dumps(report, indent=2))
    return 0 if all(r["passed"] for r in report) else 1


if __name__ == "__main__":
    sys.exit(main())
