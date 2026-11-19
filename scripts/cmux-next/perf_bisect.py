#!/usr/bin/env python3
"""Replay a perf bisect: walk a regressed row's range with real runs on this machine, by the perf cron's own rule.

Chromium's perf bisect (Pinpoint) runs each commit of a regressed range several times and names a culprit only when
the change clears the noise. perf-cron.py's bisect steps now do that (commit_verdict: BISECT_RUNS agreeing runs, at
most one against; BISECT_MAX_RUNS without a decision is noise). This walks a whole range in one go with the same rule:
to replay a past regression, to check a range the cron gave up on, or to bisect a row by hand.

  - The good end runs BISECT_RUNS times; their median is the reference, and the noise threshold is the row's own:
    max(--floor, --regression x reference), perf-cron.py's worse_than as one number.
  - The bad end runs until commit_verdict decides. Not bad: the answer is "within noise" and no commit is named
    (Pinpoint's "no significant difference between the ends").
  - Then a binary search over the first-parent commits in between; a commit within noise, or one that does not
    measure, is skipped. No commit left between the ends names the bad one as the culprit; only skipped ones left
    is "unresolved", with the commits it could not judge.

Every run of one replay comes from this machine, so two runner speeds never mix (the shared Linux runner has two host
kinds, 1.2x to 1.4x apart on web benches; a bisect across both blames commits that touch nothing).

    perf_bisect.py replay --repo DIR --good SHA --bad SHA --row NAME --measure 'CMD {sha} {row}' [--floor F]
                          [--regression 0.10] [--runs 3] [--max-runs 5] [--json]

CMD prints `VALUE <number>` for one run at {sha} (higher is worse), anything else when it could not measure. A
culprit's JSON carries `nominee`, what culprit_revert.py takes (perf-cron.py culprit_nominee).
Tests: scripts/cmux-next/tests/test_perf_bisect.py.
"""
import argparse, importlib.util, json, os, re, statistics, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("perf_cron", os.path.join(HERE, "perf-cron.py"))
cron = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cron)

REGRESSION = 0.10  # perf-budgets.json's regression rule


def sample(sha, measure, ref, thr, runs, max_runs):
    """Run measure at sha until commit_verdict decides, or a run does not measure (NOISE). Returns (verdict, values)."""
    values = []
    while True:
        if values:
            v = cron.commit_verdict([x - ref > thr for x in values], runs, max_runs)
            if v != cron.AGAIN:
                return v, values
        x = measure(sha)
        if x is None:
            return cron.NOISE, values
        values.append(x)


def replay(commits, measure, floor, regression=REGRESSION, runs=cron.BISECT_RUNS, max_runs=cron.BISECT_MAX_RUNS,
           log=lambda s: None):
    """commits: first-parent, oldest first; commits[0] the good end, commits[-1] the bad end. measure(sha) -> float or
    None. Returns {'verdict': 'culprit' | 'within noise' | 'unresolved' | 'unmeasured', ...}."""
    good, bad = commits[0], commits[-1]
    good_values = []
    for _ in range(runs):
        x = measure(good)
        if x is None:
            return {"verdict": "unmeasured", "why": f"the good end {good[:12]} did not measure"}
        good_values.append(x)
    ref = statistics.median(good_values)
    thr = cron.bisect_threshold(ref, floor, regression)
    log(f"good {good[:12]}: {good_values} -> reference {ref:g}, noise threshold {thr:g}")
    probes = {good: {"verdict": cron.GOOD, "values": good_values}}
    end, values = sample(bad, measure, ref, thr, runs, max_runs)
    probes[bad] = {"verdict": end, "values": values}
    log(f"bad {bad[:12]}: {values} -> {end}")
    out = {"good": good, "bad": bad, "commits": len(commits) - 2, "reference": ref, "threshold": thr, "floor": floor,
           "regression": regression, "runs": runs, "max_runs": max_runs, "probes": probes}
    if end != cron.BAD:
        return {**out, "verdict": "within noise",
                "why": f"the bad end {bad[:12]} ({values}) is not worse than the good end's {ref:g} by more than "
                       f"{thr:g} in {runs} agreeing runs"}
    lo, hi, skip = 0, len(commits) - 1, set()
    while True:
        named = cron.range_culprit(commits[lo + 1:hi], skip, commits[hi])
        if named is not None:
            sha, unjudged = named
            steps = len(probes) - 2
            if sha:
                return {**out, "verdict": "culprit", "culprit": sha, "parent": commits[lo], "steps": steps,
                        "value": statistics.median(probes[sha]["values"])}
            return {**out, "verdict": "unresolved", "parent": commits[lo], "first_bad": commits[hi], "steps": steps,
                    "unjudged": unjudged}
        mid = (lo + hi) // 2
        left = [i for i in range(lo + 1, hi) if commits[i] not in skip]
        i = min(left, key=lambda j: (abs(j - mid), j))
        v, values = sample(commits[i], measure, ref, thr, runs, max_runs)
        probes[commits[i]] = {"verdict": v, "values": values}
        log(f"step {len(probes) - 2}: {commits[i][:12]} ({i - lo} of {hi - lo} past the good end): {values} -> {v}")
        if v == cron.BAD:
            hi = i
        elif v == cron.GOOD:
            lo = i
        else:
            skip.add(commits[i])


def shell_measure(template, row):
    def measure(sha):
        p = subprocess.run(template.replace("{sha}", sha).replace("{row}", row), shell=True, text=True,
                           capture_output=True)
        for line in reversed(p.stdout.splitlines()):
            m = re.match(r"^VALUE\s+(\S+)\s*$", line.strip())
            if m:
                try:
                    return float(m.group(1))
                except ValueError:
                    break
        print(f"perf-bisect: {sha[:12]} did not measure: {(p.stdout + p.stderr).strip()[-300:]}", file=sys.stderr)
        return None
    return measure


def cmd_replay(o):
    def git(*a):
        return subprocess.run(["git", "-C", o.repo, *a], check=True, text=True, capture_output=True).stdout.strip()
    good = git("rev-parse", f"{o.good}^{{commit}}")
    commits = [good, *git("rev-list", "--first-parent", "--reverse", f"{good}..{o.bad}").split()]
    log = lambda s: print(f"perf-bisect: {s}", file=sys.stderr, flush=True)
    log(f"{o.row}: {len(commits) - 2} first-parent commits between {good[:12]} and {commits[-1][:12]}")
    out = replay(commits, shell_measure(o.measure, o.row), o.floor, o.regression, o.runs, o.max_runs, log)
    out["row"] = o.row
    if out.get("culprit"):
        rows = [{"name": o.row, "ref": out["reference"], "value": out["value"], "threshold": out["threshold"]}]
        out["nominee"] = cron.culprit_nominee(out["culprit"], git("log", "-1", "--format=%s", out["culprit"]),
                                              out["parent"], rows, out["steps"])
    if o.json:
        print(json.dumps(out, indent=1))
    elif out.get("culprit"):
        print(f"culprit: {out['culprit']} {out['nominee']['subject']} (reference {out['reference']:g}, culprit "
              f"{out['value']:g}, threshold {out['threshold']:g}, {out['steps']} steps)")
    else:
        print(f"{out['verdict']}: {out.get('why') or ', '.join(out.get('unjudged') or [])}")
    return 0 if out["verdict"] in ("culprit", "within noise") else 2


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("replay", help="bisect a range with real runs on this machine")
    r.add_argument("--repo", required=True)
    r.add_argument("--good", required=True)
    r.add_argument("--bad", required=True)
    r.add_argument("--row", required=True)
    r.add_argument("--measure", required=True, help="shell command; {sha} and {row} filled in; prints VALUE <n>")
    r.add_argument("--floor", type=float, default=1.0, help="the row's perf-budgets floor")
    r.add_argument("--regression", type=float, default=REGRESSION)
    r.add_argument("--runs", type=int, default=cron.BISECT_RUNS)
    r.add_argument("--max-runs", type=int, default=cron.BISECT_MAX_RUNS)
    r.add_argument("--json", action="store_true")
    return cmd_replay(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
