#!/usr/bin/env python3
"""Pin a webview test file that went red on a feat-cmux-next base batch to the one merged pull request that broke it.

    webviews_bisect.py targets HISTORY --out TARGETS.json [--max-files 8] [--github-output FILE]
        the files red on HISTORY's newest run (the batch) that were green on the newest earlier run that ran them:
        writes {"bad": SHA, "targets": [{"file", "good"}], "skipped_over_cap": N}; with --github-output appends
        `matrix=<targets as compact JSON>` and `count=N` so a workflow fans out one job a file
    webviews_bisect.py commits --good G --bad B [--repo DIR]
        print the first-parent commits in G..B, oldest first: [{"sha", "pr", "subject"}]
    webviews_bisect.py run --good G --bad B --file F --cmd CMD --out RESULT.json
                           [--repo DIR] [--confirm-bad] [--max-probes 12]
        bisect one file over G..B: CMD runs under bash with BISECT_SHA and BISECT_FILE set (it checks out, installs
        and runs the file itself); exit 0 is green. Writes one entry of the "files" list below
    webviews_bisect.py merge RESULT.json... --out CULPRITS.json [--bad SHA] [--summary FILE]
                             [--repo-slug OWNER/REPO] [--run-url URL]
        join the per-file results into CULPRITS.json and append a Markdown table to SUMMARY

Why: the base batch runs every webview test file after several pull requests merge together, so a new red there
names a range of merges, not a culprit. Each file bisects alone over the first-parent commits between its last
green batch and this one, log2(n) runs, and the files run in parallel as separate matrix jobs, so the culprit is
known in minutes. A file red at its last green sha too is base-red (a flake or an older break), never a culprit.
This only names culprits; the auto-revert step that reads CULPRITS.json is someone else's.

CULPRITS.json (schema "webviews-bisect/1"):

    {
      "schema": "webviews-bisect/1",
      "bad": "<this batch sha>",
      "run_url": "<url or empty>",
      "files": [
        {"file": "...", "verdict": "culprit" | "base-red" | "flaky" | "unresolved",
         "good": "<sha>", "bad": "<sha>", "suspects": [{"sha", "pr", "subject"}, ...],
         "culprit": {"sha": "...", "pr": 123 | null, "subject": "..."} | null,
         "probes": [{"sha": "...", "green": true, "seconds": 12.3}],
         "rounds": <bisect probes, not counting the good and bad checks>,
         "reason": "<one line>"}
      ],
      "culprits": [{"sha": "...", "pr": 123 | null, "subject": "...", "files": ["..."]}]
    }

`suspects` is the first-parent range good..bad, oldest first. `culprits` groups the files whose verdict is
"culprit" by culprit sha (one pull request may break several files), oldest commit first. A per-file RESULT.json
is one entry of "files".
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
import webviews_test_history  # noqa: E402

SCHEMA = "webviews-bisect/1"
VERDICTS = ("culprit", "base-red", "flaky", "unresolved")
MAX_FILES = 8  # matrix jobs a batch may fan out; more new reds at once is a broken base, not one culprit
MAX_PROBES = 12  # 2 checks plus 10 rounds covers 1024 merges

SQUASH_RE = re.compile(r"\(#(\d+)\)\s*$")
MERGE_RE = re.compile(r"^Merge pull request #(\d+)\b")


def red_files(run: dict) -> set[str]:
    return {str(name).split(" > ", 1)[0] for name in run["red"]}


def targets(runs: list[dict], max_files: int = MAX_FILES) -> dict:
    """The newest run's newly red files, each with the sha of the newest earlier run that ran it green."""
    if not runs:
        return {"bad": "", "targets": [], "skipped_over_cap": 0}
    newest = runs[-1]
    found = []
    for file in sorted(red_files(newest)):
        for run in reversed(runs[:-1]):
            if file not in run["files"]:
                continue
            if file not in red_files(run):
                found.append({"file": file, "good": run["sha"]})
            break
    return {"bad": newest["sha"], "targets": found[:max_files], "skipped_over_cap": max(0, len(found) - max_files)}


def pr_number(subject: str) -> int | None:
    match = SQUASH_RE.search(subject) or MERGE_RE.match(subject)
    return int(match.group(1)) if match else None


def parse_commits(text: str) -> list[dict]:
    """`git log --format=%H%x09%s` lines as [{"sha", "pr", "subject"}]."""
    out = []
    for line in text.splitlines():
        if not line.strip():
            continue
        sha, _, subject = line.partition("\t")
        out.append({"sha": sha.strip(), "pr": pr_number(subject), "subject": subject})
    return out


def commits(good: str, bad: str, repo: str = ".") -> list[dict]:
    """The first-parent commits in GOOD..BAD, oldest first; raises CalledProcessError on a git error."""
    text = subprocess.run(["git", "-C", repo, "log", "--first-parent", "--reverse", "--format=%H%x09%s",
                           f"{good}..{bad}"], check=True, capture_output=True, text=True).stdout
    return parse_commits(text)


def midpoint(lo: int, hi: int) -> int:
    return (lo + hi) // 2


def bisect(suspects: list[dict], probe: Callable[[str], bool], good: str, confirm_bad: bool = False,
           max_probes: int = MAX_PROBES, clock: Callable[[], float] = time.monotonic) -> dict:
    """The culprit among SUSPECTS (good..bad, oldest first): PROBE(sha) is True when the file is green there.

    Returns {"verdict", "culprit", "probes", "rounds", "reason"}."""
    probes: list[dict] = []

    def run(sha: str) -> bool:
        start = clock()
        green = bool(probe(sha))
        probes.append({"sha": sha, "green": green, "seconds": round(clock() - start, 1)})
        return green

    def done(verdict: str, reason: str, culprit: dict | None = None, rounds: int = 0) -> dict:
        return {"verdict": verdict, "culprit": culprit, "probes": probes, "rounds": rounds, "reason": reason}

    if not suspects:
        return done("unresolved", f"no first-parent commits in {good[:12]}..")
    if max_probes < 1:
        return done("unresolved", "probe cap is 0")
    if not run(good):
        return done("base-red", f"red at the last green sha {good[:12]} too: a flake or an older break")
    bad = suspects[-1]["sha"]
    if confirm_bad:
        if len(probes) >= max_probes:
            return done("unresolved", f"probe cap {max_probes} hit")
        if run(bad):
            return done("flaky", f"green at {bad[:12]}: the red did not reproduce")
    if len(suspects) == 1:
        return done("culprit", "the only commit in range", suspects[0])
    lo, hi, rounds = -1, len(suspects) - 1, 0
    while hi - lo > 1:
        if len(probes) >= max_probes:
            return done("unresolved", f"probe cap {max_probes} hit with {hi - lo} suspects left", rounds=rounds)
        mid = midpoint(lo, hi)
        rounds += 1
        if run(suspects[mid]["sha"]):
            lo = mid
        else:
            hi = mid
    culprit = suspects[hi]
    return done("culprit", f"green at {suspects[lo]['sha'][:12] if lo >= 0 else good[:12]}, red at "
                           f"{culprit['sha'][:12]}", culprit, rounds)


def entry(file: str, good: str, bad: str, suspects: list[dict], found: dict) -> dict:
    return {"file": file, "verdict": found["verdict"], "good": good, "bad": bad, "suspects": suspects,
            "culprit": found["culprit"], "probes": found["probes"], "rounds": found["rounds"],
            "reason": found["reason"]}


def shell_probe(cmd: str, file: str, cwd: str) -> Callable[[str], bool]:
    import os  # noqa: PLC0415

    def probe(sha: str) -> bool:
        print(f"bisect: {file} at {sha}", file=sys.stderr, flush=True)
        env = dict(os.environ, BISECT_SHA=sha, BISECT_FILE=file)
        return subprocess.run(["bash", "-c", cmd], cwd=cwd, env=env).returncode == 0
    return probe


def run_file(file: str, good: str, bad: str, probe: Callable[[str], bool], repo: str = ".",
             confirm_bad: bool = False, max_probes: int = MAX_PROBES) -> dict:
    try:
        suspects = commits(good, bad, repo)
    except (subprocess.CalledProcessError, OSError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        reason = f"git log {good[:12]}..{bad[:12]} failed: {detail.strip().splitlines()[-1] if detail.strip() else error}"
        return entry(file, good, bad, [], {"verdict": "unresolved", "culprit": None, "probes": [], "rounds": 0,
                                            "reason": reason})
    return entry(file, good, bad, suspects, bisect(suspects, probe, good, confirm_bad, max_probes))


def read_result(path: str) -> dict:
    """One per-file result; a missing or malformed one becomes an unresolved entry."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        data, why = None, f"unreadable result {path}: {type(error).__name__}"
    else:
        why = f"malformed result {path}"
    if isinstance(data, dict) and isinstance(data.get("file"), str) and data.get("verdict") in VERDICTS:
        return data
    file = data.get("file") if isinstance(data, dict) and isinstance(data.get("file"), str) else ""
    good = data.get("good", "") if isinstance(data, dict) else ""
    bad = data.get("bad", "") if isinstance(data, dict) else ""
    return {"file": file, "verdict": "unresolved", "good": good, "bad": bad, "suspects": [], "culprit": None,
            "probes": [], "rounds": 0, "reason": why}


def merge(results: list[dict], bad: str = "", run_url: str = "") -> dict:
    """The CULPRITS.json document for per-file RESULTS."""
    if not bad:
        bad = next((r["bad"] for r in results if r.get("bad")), "")
    groups: dict[str, dict] = {}
    age: dict[str, int] = {}  # commits between the culprit and bad: every range ends at bad, so this orders them
    for result in results:
        culprit = result.get("culprit")
        if result["verdict"] != "culprit" or not isinstance(culprit, dict):
            continue
        sha = culprit["sha"]
        group = groups.setdefault(sha, {"sha": sha, "pr": culprit.get("pr"), "subject": culprit.get("subject", ""),
                                        "files": []})
        group["files"].append(result["file"])
        shas = [s.get("sha") for s in result.get("suspects") or []]
        if sha in shas:
            age[sha] = max(age.get(sha, 0), len(shas) - 1 - shas.index(sha))
    for group in groups.values():
        group["files"].sort()
    culprits = sorted(groups.values(), key=lambda g: (-age.get(g["sha"], 0), g["sha"]))
    return {"schema": SCHEMA, "bad": bad, "run_url": run_url, "files": results, "culprits": culprits}


def summary(doc: dict, repo_slug: str = "") -> str:
    lines = ["### Webview test bisect", ""]
    if doc["run_url"]:
        lines += [f"Run: {doc['run_url']}", ""]
    if not doc["files"]:
        return "\n".join(lines + ["No newly red webview test files.", ""])
    lines += ["| File | Verdict | Culprit | Probes |", "| --- | --- | --- | --- |"]
    for item in doc["files"]:
        culprit = item.get("culprit")
        cell = ""
        if isinstance(culprit, dict):
            short = culprit["sha"][:12]
            cell = f"[`{short}`](https://github.com/{repo_slug}/commit/{culprit['sha']})" if repo_slug else f"`{short}`"
            if culprit.get("pr"):
                pr = culprit["pr"]
                cell += f" [#{pr}](https://github.com/{repo_slug}/pull/{pr})" if repo_slug else f" #{pr}"
        reason = str(item.get("reason", "")).replace("|", "\\|")
        lines.append(f"| `{item['file'] or '?'}` | {item['verdict']}: {reason} | {cell} | {len(item.get('probes') or [])} |")
    return "\n".join(lines + [""])


def write_json(path: str, data: object) -> None:
    Path(path).write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    tg = sub.add_parser("targets")
    tg.add_argument("history")
    tg.add_argument("--out", required=True)
    tg.add_argument("--max-files", type=int, default=MAX_FILES)
    tg.add_argument("--github-output")
    cm = sub.add_parser("commits")
    cm.add_argument("--good", required=True)
    cm.add_argument("--bad", required=True)
    cm.add_argument("--repo", default=".")
    rn = sub.add_parser("run")
    rn.add_argument("--good", required=True)
    rn.add_argument("--bad", required=True)
    rn.add_argument("--file", required=True)
    rn.add_argument("--cmd", required=True)
    rn.add_argument("--out", required=True)
    rn.add_argument("--repo", default=".")
    rn.add_argument("--confirm-bad", action="store_true")
    rn.add_argument("--max-probes", type=int, default=MAX_PROBES)
    mg = sub.add_parser("merge")
    mg.add_argument("results", nargs="+")
    mg.add_argument("--out", required=True)
    mg.add_argument("--bad", default="")
    mg.add_argument("--summary")
    mg.add_argument("--repo-slug", default="")
    mg.add_argument("--run-url", default="")
    args = parser.parse_args(argv)

    if args.command == "targets":
        found = targets(webviews_test_history.load(args.history), args.max_files)
        write_json(args.out, found)
        if args.github_output:
            with open(args.github_output, "a", encoding="utf-8") as out:
                out.write(f"matrix={json.dumps(found['targets'], separators=(',', ':'))}\n")
                out.write(f"count={len(found['targets'])}\n")
        print(f"{len(found['targets'])} newly red file(s) at {found['bad'][:12]}"
              + (f", {found['skipped_over_cap']} over the cap" if found["skipped_over_cap"] else ""), file=sys.stderr)
        return 0
    if args.command == "commits":
        try:
            print(json.dumps(commits(args.good, args.bad, args.repo), indent=1))
        except subprocess.CalledProcessError as error:
            print(error.stderr, file=sys.stderr, end="")
            return 1
        return 0
    if args.command == "run":
        result = run_file(args.file, args.good, args.bad, shell_probe(args.cmd, args.file, args.repo), args.repo,
                          args.confirm_bad, args.max_probes)
        write_json(args.out, result)
        print(f"{args.file}: {result['verdict']}: {result['reason']}", file=sys.stderr)
        return 0
    doc = merge([read_result(path) for path in args.results], args.bad, args.run_url)
    write_json(args.out, doc)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as out:
            out.write(summary(doc, args.repo_slug))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
