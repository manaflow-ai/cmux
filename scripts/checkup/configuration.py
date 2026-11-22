#!/usr/bin/env python3
"""Checkup: the cmux-next settings file, with the verdict Settings > Advanced > Check Configuration shows.

Leo, 2026-11-20: "we ought to have good tools/scripts checkups for these" (ask-f70cfb2563, on cmux#47799). This runs
the Rust settings owner's own validator, `cmux --json settings validate [FILE]` (cmux-tui/crates/cmux-tui/src/cli/
app/settings.rs), so it adds no rules of its own, and sorts the answer into the page's three states:
  clean       the owner reports no problems (a missing default file is clean: every key has its default);
  problems    each refused key with its path, message and what it accepts, and a file that is not JSON;
  unreadable  the validator could not be run or read the file, never reported as clean.
It never writes settings.

Usage:
  scripts/checkup/configuration.py                 the default settings file (~/.config/cmux/cmux-next.json)
  scripts/checkup/configuration.py FILE [FILE...]  named files (each must exist)
Options: --json, --cmux PATH (the cmux CLI; default `cmux` on PATH), --timeout S (20).
Exit: 0 clean, 1 problems, 2 unreadable.
Test: python3 -I scripts/checkup/tests/configuration.test.py
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Any


def classify(returncode: int, stdout: str, stderr: str, file: str | None) -> dict[str, Any]:
    """One validator run's verdict: clean, problems or unreadable."""
    label = file or "default settings file"
    # The answer is stdout's JSON; a refusal (settings.invalid, settings.unreadable) is stderr's.
    answer = None
    for text in (stdout, stderr):
        try:
            answer = json.loads(text) if text.strip() else None
        except json.JSONDecodeError:
            answer = None
        if isinstance(answer, dict):
            break
    if isinstance(answer, dict) and answer.get("valid") is True and returncode == 0:
        if answer.get("diagnostics"):
            # The owner never says valid with diagnostics; if it does, the problems win over the word.
            return problems(answer.get("file") or label, answer["diagnostics"])
        return {"file": answer.get("file") or label, "state": "clean", "exists": answer.get("exists", True), "problems": []}
    if isinstance(answer, dict) and answer.get("code") == "settings.invalid":
        details = answer.get("details") or {}
        return problems(details.get("file") or label, details.get("diagnostics") or [])
    message = ""
    if isinstance(answer, dict):
        message = str(answer.get("message") or "")
    message = message or stderr.strip() or stdout.strip() or f"cmux settings validate exited {returncode}"
    return {"file": label, "state": "unreadable", "error": message, "problems": []}


def problems(file: str, diagnostics: list[Any]) -> dict[str, Any]:
    rows = []
    for d in diagnostics:
        d = d if isinstance(d, dict) else {"message": str(d)}
        rows.append(
            {
                "path": d.get("path") or "",
                "kind": d.get("kind") or "",
                "message": d.get("message") or "",
                "accepted": d.get("accepted"),
            }
        )
    if not rows:
        # "invalid" with nothing listed is still not clean.
        rows.append({"path": "", "kind": "unlisted", "message": "the owner refused the file but listed no problem", "accepted": None})
    return {"file": file, "state": "problems", "problems": rows}


def accepted_words(accepted: Any) -> str:
    if not isinstance(accepted, dict):
        return ""
    if "choices" in accepted and "min" in accepted:
        return f"one of {', '.join(map(str, accepted['choices']))}, or {accepted['min']} to {accepted['max']}"
    if "choices" in accepted:
        return "one of " + ", ".join(map(str, accepted["choices"]))
    if "min" in accepted:
        return f"a number from {accepted['min']} to {accepted.get('max')}"
    return json.dumps(accepted, sort_keys=True)


def run_validate(cmux: str, file: str | None, timeout: float) -> dict[str, Any]:
    command = [cmux, "--json", "settings", "validate"] + ([file] if file else [])
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return {"file": file or "default settings file", "state": "unreadable", "error": f"{cmux} is not on PATH", "problems": []}
    except subprocess.TimeoutExpired:
        return {"file": file or "default settings file", "state": "unreadable", "error": f"no answer in {timeout:g} s", "problems": []}
    return classify(done.returncode, done.stdout, done.stderr, file)


def render(result: dict[str, Any]) -> str:
    if result["state"] == "clean":
        note = "" if result.get("exists", True) else " (no file: every key has its default)"
        return f"{result['file']}: clean{note}"
    if result["state"] == "unreadable":
        return f"{result['file']}: UNREADABLE: {result['error']}"
    lines = [f"{result['file']}: {len(result['problems'])} problem(s)"]
    for p in result["problems"]:
        words = accepted_words(p["accepted"])
        lines.append(f"  {p['path'] or '(file)'}: {p['message']}" + (f"; expected {words}" if words else ""))
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--cmux", default="cmux")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args(argv)
    results = [run_validate(args.cmux, f, args.timeout) for f in (args.files or [None])]
    if args.json:
        print(json.dumps({"schema": "cmux-checkup-configuration/v1", "results": results}, indent=2))
    else:
        print("\n".join(render(r) for r in results))
    states = {r["state"] for r in results}
    return 2 if "unreadable" in states else 1 if "problems" in states else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
