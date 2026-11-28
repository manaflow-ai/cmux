#!/usr/bin/env python3
"""Reviewed-exemption markers can only go down: a committed count per marker, and a PR that raises one fails.

Leo, 2026-11-27: "what are minimally rigorous things we can be adding to the app ci situation to be proving
correctness and perf in fast fail open ways/targetted tests per type of situation that things touch based off
relevance."

The perf ratchets (check-main-actor-work.py, check-bridge-on-main.py, the webviews scroll-writer and whole-list
checks, the perf gate) each let a site out with a `// <marker>: <reason>` comment. Their own baselines count only
unmarked hits, so a marker is free: a PR that moves a JSON decode onto the main actor and adds
`// main-actor-ok: small` passes every check. This counts the markers themselves.

scripts/cmux-next/exemption-ratchet-baseline.json holds, per marker, the total and the per-file counts of
origin/feat-cmux-next. A marker whose total is above its baseline fails and names the files that grew; a total
below asks for `--update-baseline` (a note, never a failure, so a fix never waits on this file). A marker moved
between files is net zero and passes. `--update-baseline` only lowers totals; it never raises one.

The count is a `git grep` over tracked source (MARKERS' paths), so it has no noise: it blocks.
Override (a reviewed new exemption that cannot move off the hot path): a PR body line
`exemption-raise: <marker> <reason>` (read from --pr-body-file or $PR_BODY) lets that marker grow in this PR;
the run prints the reason so the reviewer sees it.

Usage: scripts/cmux-next/check-exemption-ratchet.py [--root <repo>] [--update-baseline] [--list] [--pr-body-file F]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

BASELINE = "scripts/cmux-next/exemption-ratchet-baseline.json"
SOURCE = ["Packages", "webviews/src", "cmux-tui/crates", "cmux-next-ios"]
# Checker fixtures and tests quote markers on purpose.
EXCLUDE = [":(exclude,glob)**/Tests/**", ":(exclude,glob)**/tests/**", ":(exclude,glob)**/test/**",
           ":(exclude,glob)**/__fixtures__/**"]
# marker -> the check whose exemption it is. retry-prompt-ok is not here: its rule keeps real prompts (a paid
# re-send, a sign-in code) by design, so new reviewed sites are expected (check-retry-prompts.py).
MARKERS = {
    "main-actor-ok": "scripts/cmux-next/check-main-actor-work.py",
    "bridge-ok": "scripts/cmux-next/check-bridge-on-main.py",
    "perf-gate-ok": "the perf gate",
    "scroll-writer-ok": "webviews scroll-writer check",
    "whole-list-ok": "webviews/scripts whole-list-rows check",
}
RAISE = re.compile(r"^\s*exemption-raise:\s*(?P<marker>[a-z-]+)\s+(?P<reason>\S.*)$", re.M)


def counts(root: str, marker: str) -> dict[str, int]:
    """{file: number of `// MARKER: <reason>` comments} over tracked source."""
    pattern = rf"(//|#|/\*|\*)\s*{re.escape(marker)}:\s*\S"
    out = subprocess.run(["git", "-C", root, "grep", "-cE", pattern, "--", *SOURCE, *EXCLUDE],
                         capture_output=True, text=True)
    if out.returncode not in (0, 1):
        raise SystemExit(f"check-exemption-ratchet: git grep failed: {out.stderr.strip()}")
    result: dict[str, int] = {}
    for line in out.stdout.splitlines():
        path, _, n = line.rpartition(":")
        result[path] = int(n)
    return dict(sorted(result.items()))


def listing(root: str, marker: str) -> list[str]:
    pattern = rf"(//|#|/\*|\*)\s*{re.escape(marker)}:\s*\S"
    out = subprocess.run(["git", "-C", root, "grep", "-nE", pattern, "--", *SOURCE, *EXCLUDE],
                         capture_output=True, text=True)
    return out.stdout.splitlines()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=None)
    parser.add_argument("--update-baseline", action="store_true", help="lower the totals that fell (never raises)")
    parser.add_argument("--list", action="store_true", help="print every marker site")
    parser.add_argument("--pr-body-file", default=None)
    parser.add_argument("--base-ref", default=None,
                        help="a ref whose committed baseline this one may not exceed (default origin/$GITHUB_BASE_REF,"
                             " else origin/feat-cmux-next); unreadable: warn and skip")
    args = parser.parse_args()
    root = args.root or subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                                       check=True).stdout.strip()
    baseline_path = os.path.join(root, BASELINE)
    baseline: dict = {}
    if os.path.exists(baseline_path):
        with open(baseline_path, encoding="utf-8") as handle:
            baseline = json.load(handle)
    body = os.environ.get("PR_BODY", "")
    if args.pr_body_file and os.path.exists(args.pr_body_file):
        with open(args.pr_body_file, encoding="utf-8") as handle:
            body = handle.read()
    raises = {m.group("marker"): m.group("reason").strip() for m in RAISE.finditer(body)}

    now = {marker: counts(root, marker) for marker in MARKERS}
    if args.update_baseline:
        written = {}
        for marker, files in now.items():
            total = sum(files.values())
            old = baseline.get(marker)
            if old is not None and total > old["total"]:
                print(f"check-exemption-ratchet: {marker}: {total} above the baseline {old['total']}; not raised "
                      f"(a raise is a PR body `exemption-raise: {marker} <reason>`, then edit the file by hand)")
                written[marker] = old
                continue
            written[marker] = {"check": MARKERS[marker], "total": total, "files": files}
        os.makedirs(os.path.dirname(baseline_path), exist_ok=True)
        with open(baseline_path, "w", encoding="utf-8") as handle:
            json.dump(written, handle, indent=1, sort_keys=True)
            handle.write("\n")
        print("check-exemption-ratchet: baseline written: "
              + ", ".join(f"{m} {w['total']}" for m, w in sorted(written.items())))
        return 0

    if args.list:
        for marker in MARKERS:
            for line in listing(root, marker):
                print(f"{marker}: {line}")

    failures, lowered = 0, []
    # A hand-raised baseline row is a raise too: the committed totals may not exceed the base branch's.
    base_ref = args.base_ref or f"origin/{os.environ.get('GITHUB_BASE_REF') or 'feat-cmux-next'}"
    shown = subprocess.run(["git", "-C", root, "show", f"{base_ref}:{BASELINE}"], capture_output=True, text=True)
    if shown.returncode != 0:
        print(f"check-exemption-ratchet: warn: no baseline at {base_ref}; the committed one is not compared to it")
    else:
        base = json.loads(shown.stdout)
        for marker, entry in baseline.items():
            was = base.get(marker, {}).get("total")
            if was is not None and entry["total"] > was:
                if marker in raises:
                    print(f"check-exemption-ratchet: {marker}: baseline raised {was} -> {entry['total']}, allowed by "
                          f"the PR body: exemption-raise: {marker} {raises[marker]}")
                    continue
                failures += 1
                print(f"exemption-ratchet violation: {BASELINE}: {marker} raised {was} -> {entry['total']} "
                      f"over {base_ref}'s")
    for marker, files in now.items():
        total = sum(files.values())
        entry = baseline.get(marker)
        if entry is None:
            print(f"check-exemption-ratchet: warn: {marker} has no baseline row; run --update-baseline")
            continue
        if total > entry["total"]:
            grew = [(f, n, entry["files"].get(f, 0)) for f, n in files.items() if n > entry["files"].get(f, 0)]
            if marker in raises:
                print(f"check-exemption-ratchet: {marker}: {total} above the baseline {entry['total']}, allowed by "
                      f"the PR body: exemption-raise: {marker} {raises[marker]}")
                continue
            failures += 1
            print(f"exemption-ratchet violation: {marker} ({entry['check']}): {total} marker(s), baseline "
                  f"{entry['total']}")
            for f, n, was in grew:
                print(f"    {f}: {was} -> {n}")
                for line in listing(root, marker):
                    if line.startswith(f + ":"):
                        print(f"        {line}")
        elif total < entry["total"]:
            lowered.append(f"{marker} {entry['total']} -> {total}")
    if failures:
        print(f"check-exemption-ratchet: {failures} marker total(s) went up. Reviewed exemptions only go down: fix "
              "the hit the marker hides (move the work off the main actor, cache the Rust answer, batch the rows) "
              "instead of marking it. Moving a marker between files is fine. A reviewed raise: add the PR body line "
              "`exemption-raise: <marker> <reason>`.")
        return 1
    totals = ", ".join(f"{m} {sum(f.values())}" for m, f in now.items())
    if lowered:
        print(f"check-exemption-ratchet: ok ({totals}); fell: {'; '.join(lowered)}: run "
              "scripts/cmux-next/check-exemption-ratchet.py --update-baseline and commit it.")
        return 0
    print(f"check-exemption-ratchet: ok ({totals})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
