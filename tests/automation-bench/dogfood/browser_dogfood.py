#!/usr/bin/env python3
"""Browser-use dogfood run: real public sites, driven only through `cmux browser`.

Usage:
  browser_dogfood.py --tab tab_... [--cmux PATH] [--only ID,ID] [--out results.jsonl]

It navigates one agent tab (`--tab`, a browser tab the caller owns, never the
person's shown tab) through every task in tasks.json, runs the task's verbs and
checks the end state with a page expression. Tasks marked `fresh_tab` open their
own background tab with `cmux open` and close it afterwards. One JSONL row per
task (the automation-bench row shape: task_id, driver, domain, level, ok,
failure, wall_ms, live) plus a summary line on stdout. Live sites are flaky by
design: compare runs of the same day, and read the `detail` of each failure.
No task signs in, pays or types a password.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CMUX = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux"


class Fail(Exception):
    def __init__(self, category: str, detail: str):
        super().__init__(detail)
        self.category = category
        self.detail = detail


def run_cli(cmux: str, args: list[str], timeout: float = 60) -> dict:
    """Runs `cmux --json <args>` and returns the decoded answer (or raises Fail)."""
    try:
        proc = subprocess.run([cmux, "--json", *args], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Fail("timeout", f"cmux {' '.join(args[:3])} did not answer in {timeout:.0f} s")
    text = (proc.stdout or "").strip().splitlines()
    last = text[-1] if text else ""
    try:
        answer = json.loads(last) if last else {}
    except json.JSONDecodeError:
        answer = {"raw": last}
    if proc.returncode != 0 or (isinstance(answer, dict) and "code" in answer and "message" in answer):
        message = answer.get("message") if isinstance(answer, dict) else None
        raise Fail("input", f"{' '.join(args[2:4])}: {message or proc.stderr.strip()[:300] or last[:300]}")
    return answer if isinstance(answer, dict) else {"value": answer}


def page(cmux: str, tab: str, verb: list[str], agent: str) -> dict:
    return run_cli(cmux, ["browser", tab, *verb, "--agent", agent] if verb[0] not in ("eval", "state", "snapshot", "tabs", "wait") else ["browser", tab, *verb])


def evaluate(cmux: str, tab: str, expression: str):
    answer = run_cli(cmux, ["browser", tab, "eval", f"!!({expression})"])
    return answer.get("value")


def category_for(verb: str) -> str:
    return {"wait": "wait", "navigate": "nav"}.get(verb, "input")


def run_task(task: dict, cmux: str, tab: str, agent: str) -> dict:
    started = time.monotonic()
    own_tab = None
    target = tab
    try:
        if task.get("fresh_tab"):
            opened = run_cli(cmux, ["open", task["url"]])
            own_tab = opened.get("tab_id")
            if not own_tab:
                raise Fail("nav", f"cmux open gave no tab: {opened}")
            target = own_tab
        else:
            run_cli(cmux, ["browser", tab, "navigate", task["url"]])
            try:
                run_cli(cmux, ["browser", tab, "wait", "--load-state", "complete", "--timeout-ms", "20000"], timeout=40)
            except Fail as failure:
                raise Fail("nav", f"page did not load: {failure.detail}")
        for step in task.get("steps", []):
            verb = [part.replace("{fixture}", str(HERE)) for part in step]
            try:
                page(cmux, target, verb, agent)
            except Fail as failure:
                raise Fail(category_for(verb[0]) if failure.category != "timeout" else "timeout", failure.detail)
        if "snapshot_check" in task:
            spec = task["snapshot_check"]
            args = ["snapshot"] if spec.get("full") else ["snapshot", "--interactive"]
            snap = run_cli(cmux, ["browser", target, *args])
            text = snap.get("snapshot") or ""
            refs = snap.get("refs") or {}
            if len(refs) < spec.get("min_refs", 0):
                raise Fail("not_landed", f"snapshot has {len(refs)} refs, wants {spec['min_refs']}")
            missing = [needle for needle in spec.get("contains", []) if needle not in text]
            if missing:
                raise Fail("not_landed", f"snapshot lacks {missing}")
        if "tabs_check" in task:
            want = task["tabs_check"]["url_contains"]
            tabs = run_cli(cmux, ["browser", target, "tabs"])
            if want not in json.dumps(tabs):
                raise Fail("not_landed", f"no tab with {want} in {json.dumps(tabs)[:300]}")
        if "check" in task:
            deadline = time.monotonic() + 5
            while True:
                try:
                    if evaluate(cmux, target, task["check"]) is True:
                        break
                except Fail as failure:
                    if time.monotonic() > deadline:
                        raise Fail("not_landed", f"check could not run: {failure.detail}")
                if time.monotonic() > deadline:
                    raise Fail("not_landed", f"check false: {task['check'][:160]}")
                time.sleep(0.5)  # the end state of a click can land a moment later; bounded by the 5 s deadline
        row = {"ok": True}
    except Fail as failure:
        row = {"ok": False, "failure": failure.category, "detail": failure.detail[:500]}
    finally:
        if own_tab:
            try:
                run_cli(cmux, ["browser", own_tab, "close", "--no-wait"], timeout=20)
            except Fail:
                pass
    row.update({
        "task_id": task["id"], "needs": task.get("needs"), "driver": "cmux-browser-cli", "domain": "browser",
        "level": "primitive", "live": True, "wall_ms": round((time.monotonic() - started) * 1000),
    })
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tab", required=True)
    parser.add_argument("--cmux", default=os.environ.get("CMUX_DOGFOOD_CLI", DEFAULT_CMUX))
    parser.add_argument("--agent", default="dogfood")
    parser.add_argument("--only", default="")
    parser.add_argument("--out", default="")
    args = parser.parse_args()
    tasks = json.loads((HERE / "tasks.json").read_text())["tasks"]
    if args.only:
        wanted = set(args.only.split(","))
        tasks = [task for task in tasks if task["id"] in wanted]
    rows = []
    out = open(args.out, "w") if args.out else None
    for task in tasks:
        row = run_task(task, args.cmux, args.tab, args.agent)
        rows.append(row)
        line = json.dumps(row)
        print(line, flush=True)
        if out:
            out.write(line + "\n")
            out.flush()
    passed = sum(1 for row in rows if row["ok"])
    print(json.dumps({"summary": True, "passed": passed, "total": len(rows),
                      "failed": [row["task_id"] for row in rows if not row["ok"]]}))
    return 0 if passed == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
