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
`cmux customize docs`; the page's `<!-- prompt-check: shows "..." -->` names the words.
`--headless` checks with `cmux ext dev --once --headless --json`, which loads and renders in this
process, so it needs no running cmux (the scheduled customize-prompts-cold-model workflow runs
`--prompts --headless` on a Linux runner).

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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RECIPES = ROOT / "skills" / "cmux-extension-author" / "recipes"
PROMPTS = ROOT / "skills" / "cmux-extension-author" / "prompts"
SHOWS = re.compile(r'<!-- (?:recipe|prompt)-check: shows "([^"]+)" -->')
PROMPT_BLOCK = re.compile(r"```text\n(.*?)\n```", re.S)
TIMEOUT_S = 600

PROMPT = """You are in an empty folder. Build the cmux extension this page describes, in this folder,
by following the page. Write the files it names. Then run `cmux ext dev --once --json` and read its
JSON; if it does not exit 0, fix what `errors` names and run it again, until it exits 0 or you have
tried five times. Do not install packages. Reply with one line: done, or what stopped you.

--- the page ---
{page}
"""


def run_model(prompt: str, folder: Path, model: str) -> tuple[int, str]:
    argv = [
        "claude", "-p", prompt,
        "--model", model,
        "--allowedTools",
        "Read,Write,Edit,Bash(cmux ext dev:*),Bash(cmux customize docs:*),Bash(cmux customize prompts:*),"
        "Bash(mkdir:*),Bash(ls:*)",
        "--max-turns", "30",
    ]
    try:
        done = subprocess.run(argv, cwd=folder, capture_output=True, text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return 124, f"the model did not finish in {TIMEOUT_S} s"
    return done.returncode, (done.stdout or done.stderr).strip()[-2000:]


def check(folder: Path, shows: str | None, no_daemon_ok: bool, headless: bool) -> dict:
    argv = ["cmux", "ext", "dev", "--once", "--json"]
    argv += ["--headless"] if headless else ["--no-install", "--remove-on-exit"]
    done = subprocess.run(
        argv,
        cwd=folder, capture_output=True, text=True, timeout=300,
    )
    try:
        result = json.loads(done.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        result = {"raw": done.stdout[-2000:], "stderr": done.stderr[-2000:]}
    code = done.returncode
    scene = "\n".join(result.get("scene") or [])
    passed = code == 0 and (shows is None or shows in scene)
    if code == 3 and no_daemon_ok:
        passed = True  # the manifest and the build passed; no cmux to load into
    why = None
    if not passed:
        why = f"exit {code}" if code != 0 else f"the scene does not show {shows!r}"
    return {"exitCode": code, "passed": passed, "why": why, "errors": result.get("errors"), "scene": scene}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--recipe", action="append", help="a page's name (section, widget, ...); default every page")
    parser.add_argument("--model", default="haiku")
    parser.add_argument("--prompts", action="store_true", help="check the copy-paste prompts, not the recipes")
    parser.add_argument("--no-daemon-ok", action="store_true")
    parser.add_argument("--headless", action="store_true", help="check with ext dev --once --headless (no cmux)")
    parser.add_argument("--keep", action="store_true", help="keep each page's folder and print it")
    parser.add_argument("--json", action="store_true")
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
        match = SHOWS.search(text)
        folder = Path(tempfile.mkdtemp(prefix=f"cold-{page.stem}-"))
        if args.prompts:
            block = PROMPT_BLOCK.search(text)
            if not block:
                print(f"ext-recipe-cold-model: {page.name} has no ```text prompt", file=sys.stderr)
                return 2
            prompt = block.group(1) + "\nDo not install packages. End with one line: done, or what stopped you.\n"
        else:
            prompt = PROMPT.format(page=text)
        model_exit, said = run_model(prompt, folder, args.model)
        row = {"recipe": page.stem, "model": args.model, "modelExit": model_exit, "said": said}
        row.update(check(folder, match.group(1) if match else None, args.no_daemon_ok, args.headless))
        if args.keep:
            row["folder"] = str(folder)
        else:
            shutil.rmtree(folder, ignore_errors=True)
        report.append(row)
        if not args.json:
            verdict = "pass" if row["passed"] else f"FAIL ({row['why']})"
            print(f"{page.stem}: {verdict}" + (f"  {folder}" if args.keep else ""))
            if not row["passed"]:
                print(f"  errors: {row['errors']}\n  model: {said[-400:]}")
    if args.json:
        print(json.dumps(report, indent=2))
    return 0 if all(r["passed"] for r in report) else 1


if __name__ == "__main__":
    sys.exit(main())
