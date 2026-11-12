#!/usr/bin/env python3
"""Crash ratchet for pull requests into feat-cmux-next, judged against the base.

Usage: crash_ratchet_compare.py --script RATCHET --head HEAD_DIR --base BASE_DIR

GitHub merges into feat-cmux-next do not run safe-push, so its crash ratchet never saw them (#20223
added 3 unwraps that way, 2026-10-13). This runs one ratchet script (the pull request's
scripts/cmux-next/crash_ratchet.py with its own baseline) on the head tree (a checkout) and on the
base tree (an exported tree of tracked files, `--exported-tree`).

The head's baseline judges both trees, so a head that raised its own baseline would be green
against it. So first `RATCHET --baseline-against BASE_DIR` judges the head's baseline against the
base's copy: a counted row that rose (beyond a hit proven to have moved from another module) is
red whatever the trees show; a waived row that rose is a recorded waiver, a `::warning::`.

Then it compares the `crash-ratchet: <lang> <module>: <kind> N -> M` lines of the two trees:

- head prints `crash-ratchet: ok`: green.
- head red, base green (`ok`): red; every head line is printed with the base count beside it.
- both red: red only when the head is worse (a new line, or a higher count than the base's);
  otherwise a warning that the base is already red.
- a run that is neither `ok` nor a list of regression lines (a crash, a refusal): red, with
  its output, because nothing can be compared. A baseline judgment that prints neither
  `crash-ratchet: baseline ok` (exit 0) nor raised rows (exit 1) is red the same way.

Then it compares hits, not only counts: each tree's counted hits by line (`--hit-lines`: the class
and the stripped source line). A hit line the head has more often than the base, in any module, is
the change's and is red whatever the counts show: a change that fixes one hit and adds another keeps
a module's count at its row. A line that moved to another file or module is the same hit. Hit lines
that cannot be read from both trees are red too (nothing to compare).

Exit 0 = green or base-red-not-worse, 1 = red. Lines go to stdout; GitHub annotations are
`::error::` / `::warning::`.
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys
import tempfile

LINE = re.compile(r"^crash-ratchet: (\S+) (.+?): (\S+) (\d+) -> (\d+)$")
OK = re.compile(r"^crash-ratchet: ok\b")


def run(script, repo, exported, hit_lines=None):
    args = [sys.executable, script, "--repo", repo]
    if exported:
        args.append("--exported-tree")
    if hit_lines:
        args += ["--hit-lines", hit_lines]
    out = subprocess.run(args, capture_output=True, text=True)
    text = out.stdout + out.stderr
    found = {}
    ok = False
    for line in text.splitlines():
        line = line.strip()
        if OK.match(line):
            ok = True
        m = LINE.match(line)
        if m:
            found[(m.group(1), m.group(2), m.group(3))] = int(m.group(5))
    # Green only with the ok line and exit 0; red only with regression lines and a non-zero exit.
    state = "green" if ok and out.returncode == 0 else ("red" if found and out.returncode != 0 else "failed")
    return state, found, text, out.returncode


BASELINE_OK = re.compile(r"^crash-ratchet: baseline ok\b")
RAISED = "crash-ratchet: baseline raised: "
WAIVER = "crash-ratchet: waiver recorded: "
MOVED = "crash-ratchet: moved: "
NOTE = "crash-ratchet: note: "


def judge_baseline(script, head, base):
    """True when the head's baseline is not above the base's (printing recorded waivers as
    warnings and proven moves), False (printing why) when a counted row rose or the run failed."""
    out = subprocess.run([sys.executable, script, "--repo", head, "--baseline-against", base],
                         capture_output=True, text=True)
    lines = [line.strip() for line in (out.stdout + out.stderr).splitlines()]
    raised = [line[len(RAISED):] for line in lines if line.startswith(RAISED)]
    for line in lines:
        if line.startswith(MOVED):
            print(f"  baseline row moved with its hits: {line[len(MOVED):]}")
        elif line.startswith(NOTE):
            print(f"  {line}")
        elif line.startswith(WAIVER):
            print(f"::warning::a reviewed crash-allow waiver is recorded in the baseline: {line[len(WAIVER):]}")
    if out.returncode == 0 and not raised and any(BASELINE_OK.match(line) for line in lines):
        return True
    if out.returncode == 1 and raised:
        for row in raised:
            print(f"::error::crash-safety-baseline.json may only go down: {row}")
        print("::error::this change raises the crash baseline above the base's. The baseline may only go down: "
              "fix the hits (a hit that moved from another module carries its row with "
              "`crash_ratchet.py --update-baseline --base <the base commit>`; a reviewed waiver is recorded with "
              "--record-waivers).")
        return False
    print("\n".join(lines))
    print(f"::error::the crash baseline could not be judged against the base's (exit {out.returncode}, no "
          "`baseline ok` line and no raised rows)")
    return False


def label(key):
    lang, module, kind = key
    return f"{lang} {module}: {kind}"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--script", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--base", required=True)
    o = p.parse_args(argv)

    baseline_down = judge_baseline(o.script, o.head, o.base)
    with tempfile.TemporaryDirectory(prefix="crash-ratchet-hits-") as tmp:
        head_lines, base_lines = os.path.join(tmp, "head.json"), os.path.join(tmp, "base.json")
        trees = compare_trees(o.script, o.head, o.base, head_lines, base_lines)
        hits = compare_hits(head_lines, base_lines)
    return 0 if baseline_down and trees == 0 and hits == 0 else 1


def read_hit_lines(path):
    """{(lang, class, line): hits} and {(lang, class, line): [modules]} of a --hit-lines file, or None."""
    try:
        with open(path) as f:
            rows = json.load(f)
        counts, modules = collections.Counter(), {}
        for lang, kind, module, line, hits in rows:
            counts[(lang, kind, line)] += int(hits)
            modules.setdefault((lang, kind, line), []).append(module)
        return counts, modules
    except (OSError, ValueError, TypeError):
        return None


def compare_hits(head_path, base_path):
    """0 when every counted hit line of the head is on the base as often, 1 (naming each) otherwise."""
    head, base = read_hit_lines(head_path), read_hit_lines(base_path)
    if head is None or base is None:
        which = " and ".join(name for name, got in (("head", head), ("base", base)) if got is None)
        print(f"::error::the crash ratchet wrote no readable hit lines for the {which}; hits cannot be compared")
        return 1
    (head_counts, head_modules), (base_counts, _) = head, base
    new = sorted(key for key, n in head_counts.items() if n > base_counts.get(key, 0))
    for lang, kind, line in new:
        extra = head_counts[(lang, kind, line)] - base_counts.get((lang, kind, line), 0)
        times = f" ({extra} more)" if extra > 1 or base_counts.get((lang, kind, line)) else ""
        for module in sorted(set(head_modules[(lang, kind, line)])):
            print(f"::error::a crash-class hit the base does not have: {lang} {module}: {kind}: {line}{times}")
    if new:
        print(f"::error::{len(new)} crash-class hit line(s) are new against the base, whatever the counts: a fixed "
              "hit does not pay for a new one. Remove the new hit, or record a reviewed `// crash-allow: <reason>` "
              "waiver (crash_ratchet.py --record-waivers).")
        return 1
    print("crash-ratchet: no hit the base does not have")
    return 0


def compare_trees(script, head_dir, base_dir, head_lines=None, base_lines=None):
    """The tree comparison: 0 = head green or base red and not made worse, 1 = red. Writes each
    tree's hit lines to HEAD_LINES and BASE_LINES (the base is scanned whatever the head shows)."""
    head_state, head, head_text, head_rc = run(script, head_dir, exported=False, hit_lines=head_lines)
    base_state, base, base_text, base_rc = run(script, base_dir, exported=True, hit_lines=base_lines)
    if head_state == "green":
        print("crash-ratchet: ok on the head")
        return 0
    if head_state == "failed":
        print(head_text)
        print(f"::error::the crash ratchet did not run on the head (exit {head_rc}, no ok line and no regression lines)")
        return 1

    if base_state == "failed":
        print(head_text)
        print(base_text)
        print(f"::error::the crash ratchet did not run on the base (exit {base_rc}); the head is red and cannot be "
              "compared with the base")
        return 1

    def base_count(key):
        if base_state == "green":
            return "ok"
        return str(base[key]) if key in base else "not red"

    for key, n in sorted(head.items()):
        print(f"  {label(key)}: head {n}, base {base_count(key)}")
    if base_state == "green":
        print("::error::this change turns the crash ratchet red (the base is green). Fix the new crash-class hits. "
              "A reviewed `// crash-allow: <reason>` still counts, as a waived hit (`<class>.waived`): record it "
              "with `crash_ratchet.py --record-waivers` (this job annotates every recorded waiver). A counted row "
              "never rises: --update-baseline only lowers rows.")
        return 1
    worse = sorted(k for k, n in head.items() if n > base.get(k, -1))
    if worse:
        for key in worse:
            print(f"::error::crash ratchet worse than the base: {label(key)} head {head[key]}, base {base_count(key)}")
        print("::error::the base is already red on the crash ratchet and this change makes it worse")
        return 1
    print("::warning::the crash ratchet is already red on the base; this change does not make it worse")
    return 0


if __name__ == "__main__":
    sys.exit(main())
