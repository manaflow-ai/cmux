#!/usr/bin/env python3
"""Before/after eval of the "where you are" card (cmux-tui/crates/acpmux/src/agent_card.rs).

Each task is a question where an agent in a cmux chat should use (or correctly describe) one of
cmux's capabilities. The agent answers with no tools (`claude -p`, tools off) once without the
card ("before") and once with it in its system prompt ("after"), RUNS times each; a regex grader
scores every answer. The card is a file: print one with
`cargo test -p acpmux --lib example_cards -- --nocapture` (cmux-tui/).

    python3 tests/agent-evals/where_you_are_card.py CARD_FILE [--runs 3] [--model sonnet]
"""

import argparse
import concurrent.futures
import re
import subprocess
import sys

# (id, prompt, must match, must not match)
TASKS = [
    (
        "sync-back",
        "I started you in a cmux Cloud chat on my project folder. When you edit files here, do "
        "they end up back on my Mac, or will I need to copy or push them back myself? One "
        "short paragraph.",
        r"(sync|come|go|land|appear|flow)s?\b[^.]{0,40}\bback|back (on|to) (your|the) Mac|"
        r"no(thing)? (need|needs) (to be )?cop",
        r"(you('ll| will)? need to|have to|must) (copy|push|download|scp|rsync)",
    ),
    (
        "too-small",
        "This build needs about 20 GB of RAM and 12 cores. Can we do it on the machine you're "
        "on? What would you do? One short paragraph.",
        r"resiz|grow|xlarge|bigger machine|larger (machine|size)|more (RAM|memory|CPU)",
        r"\b(can't|cannot|won't be able to|impossible)\b[^.]{0,30}\b(here|on this machine)\b",
    ),
    (
        "chart",
        "Show me a bar chart of these numbers: apples 3, pears 5, plums 2. Answer as you "
        "would in this chat.",
        r"```(chart|vega|vega-lite|mermaid)|xychart|\"mark\"\s*:",
        r"",
    ),
    (
        "browser",
        "I want you to look at https://example.com and tell me what the page shows, then "
        "click its link. How will you do that here? One short paragraph.",
        r"browser pane|cmux browser|cmux-browser",
        r"",
    ),
    (
        "long-job",
        "The full test suite takes 40 minutes. How will you run it without blocking our "
        "conversation? One short paragraph.",
        r"bg_start|bg_output|background job|in the background",
        r"",
    ),
    (
        "other-folder",
        "I also need you to change a file in another folder on my Mac, ~/work/api, which "
        "isn't on this machine. How do you get to it? One short paragraph.",
        r"cmux link access request|link access",
        r"",
    ),
    (
        "ask",
        "Before you delete the old migrations you need my yes or no. How will you ask me in "
        "this chat? One short paragraph.",
        r"wrap_up|answer buttons|buttons",
        r"",
    ),
    (
        "machine",
        "How many vCPUs and how much disk does the machine you're on have? Answer from what "
        "you know; don't run anything.",
        r"\b4 vCPU|\b4 (v?CPUs|cores)|41 GB",
        r"",
    ),
]


def ask(prompt, card, model):
    argv = ["claude", "-p", prompt, "--model", model, "--tools", ""]
    if card:
        argv += ["--append-system-prompt", card]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return ""
    return out.stdout


def grade(answer, good, bad):
    if not answer.strip():
        return False
    if not re.search(good, answer, re.I):
        return False
    return not (bad and re.search(bad, answer, re.I))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("card")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--show", action="store_true", help="print every answer")
    ap.add_argument("--only", help="comma-separated task names to run")
    args = ap.parse_args()
    card = open(args.card, encoding="utf-8").read()
    if args.only:
        TASKS[:] = [t for t in TASKS if t[0] in args.only.split(",")]
    jobs = [
        (task, cond, run)
        for task in TASKS
        for cond in ("before", "after")
        for run in range(args.runs)
    ]
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = {
            pool.submit(ask, task[1], card if cond == "after" else None, args.model): (task, cond, run)
            for task, cond, run in jobs
        }
        for fut in concurrent.futures.as_completed(futures):
            task, cond, run = futures[fut]
            answer = fut.result()
            results[(task[0], cond, run)] = (grade(answer, task[2], task[3]), answer)
    print(f"| task | before | after |\n|---|---|---|")
    totals = {"before": 0, "after": 0}
    for task in TASKS:
        row = []
        for cond in ("before", "after"):
            n = sum(results[(task[0], cond, r)][0] for r in range(args.runs))
            totals[cond] += n
            row.append(f"{n}/{args.runs}")
        print(f"| {task[0]} | {row[0]} | {row[1]} |")
    n = len(TASKS) * args.runs
    print(f"| **total** | **{totals['before']}/{n}** | **{totals['after']}/{n}** |")
    if args.show:
        for (tid, cond, run), (ok, answer) in sorted(results.items()):
            print(f"\n=== {tid} {cond} #{run} {'PASS' if ok else 'FAIL'}\n{answer.strip()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
