#!/usr/bin/env python3
"""Replay a perf bisect: walk a regressed row's range with real runs on this machine, by the perf cron's own rule.

A perf bisect runs each commit of a regressed range several times and names a culprit only when the change clears the
noise. perf-cron.py's bisect steps now do that (commit_verdict: BISECT_RUNS agreeing runs, at most one against; BISECT_MAX_RUNS without a decision is noise). This walks a whole range in one go with the same rule:
to replay a past regression, to check a range the cron gave up on, or to bisect a row by hand.

  - The good end runs BISECT_RUNS times; their median is the reference, and the noise threshold is the row's own:
    max(--floor, --regression x reference), perf-cron.py's worse_than as one number.
  - The bad end runs until commit_verdict decides. Not bad: the answer is "within noise" and no commit is named
    (no significant difference between the ends).
  - Then a binary search over the first-parent commits in between; a commit within noise, or one that does not
    measure, is skipped. No commit left between the ends names the bad one as the culprit; only skipped ones left
    is "unresolved", with the commits it could not judge.

Every run of one replay comes from this machine, so two runner speeds never mix (the shared Linux runner has two host
kinds, 1.2x to 1.4x apart on web benches; a bisect across both blames commits that touch nothing).

    perf_bisect.py replay --repo DIR --good SHA --bad SHA --row NAME --measure 'CMD {sha} {row}' [--floor F]
                          [--regression 0.10] [--runs 3] [--max-runs 5] [--cache FILE] [--json]

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


# A run that does not measure (the bench timed out on a loaded host, the commit does not build) is tried again: it
# counts toward max_runs, and FAILS_IN_A_ROW of them end the commit. 2026-11-19: one 150 s bench timeout after a
# 0.81 run ended commit 8743439 as noise on its first step.
FAILS_IN_A_ROW = 2


def sample(sha, measure, ref, thr, runs, max_runs):
    """Run measure at sha until commit_verdict decides (NOISE after max_runs attempts, or FAILS_IN_A_ROW failed runs in
    a row). Returns (verdict, values)."""
    values, attempts, fails = [], 0, 0
    while True:
        if values:
            v = cron.commit_verdict([x - ref > thr for x in values], runs, max_runs)
            if v != cron.AGAIN:
                return v, values
        if attempts >= max_runs or fails >= FAILS_IN_A_ROW:
            return cron.NOISE, values
        x = measure(sha)
        attempts += 1
        if x is None:
            fails += 1
            continue
        fails = 0
        values.append(x)


def replay(commits, measure, floor, regression=REGRESSION, runs=cron.BISECT_RUNS, max_runs=cron.BISECT_MAX_RUNS,
           log=lambda s: None):
    """commits: first-parent, oldest first; commits[0] the good end, commits[-1] the bad end. measure(sha) -> float or
    None. Returns {'verdict': 'culprit' | 'within noise' | 'unresolved' | 'unmeasured', ...}."""
    good, bad = commits[0], commits[-1]
    good_values, attempts, fails = [], 0, 0
    while len(good_values) < runs:
        if attempts >= max_runs or fails >= FAILS_IN_A_ROW:
            return {"verdict": "unmeasured", "why": f"the good end {good[:12]} measured {len(good_values)} of {runs} "
                                                    f"runs in {attempts} attempts"}
        x = measure(good)
        attempts += 1
        fails = 0 if x is not None else fails + 1
        if x is not None:
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
    if not values:
        # No run at the bad end measured: nothing says the ends differ or not (2026-11-20: "within noise" from zero
        # runs, every attempt a missing bun).
        return {**out, "verdict": "unmeasured", "why": f"the bad end {bad[:12]} did not measure"}
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


def cached(measure, path):
    """measure, with every measured run kept in the JSON file path ({sha: [value, ...]}, in run order). A replay
    started again (the host restarted, the job hit its cap) takes each commit's kept values first, in order, and runs
    the bench only past them, so no measured run is paid twice. A run that did not measure is not kept: it is most
    often the host (a missing tool, a timeout under load), so a replay started again tries that commit again."""
    try:
        with open(path) as f:
            kept = json.load(f)
    except (OSError, ValueError):
        kept = {}
    kept = {sha: [x for x in xs if isinstance(x, (int, float))] for sha, xs in kept.items() if isinstance(xs, list)}
    used = {}

    def run(sha):
        i = used.get(sha, 0)
        used[sha] = i + 1
        if i < len(kept.get(sha, [])):
            return kept[sha][i]
        x = measure(sha)
        if x is None:
            used[sha] = i  # the next call at sha runs again instead of reading past a gap
            return None
        kept.setdefault(sha, []).append(x)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(kept, f, indent=1, sort_keys=True)
        os.replace(tmp, path)
        return x
    return run


def cmd_replay(o):
    def git(*a):
        return subprocess.run(["git", "-C", o.repo, *a], check=True, text=True, capture_output=True).stdout.strip()
    good = git("rev-parse", f"{o.good}^{{commit}}")
    commits = [good, *git("rev-list", "--first-parent", "--reverse", f"{good}..{o.bad}").split()]
    log = lambda s: print(f"perf-bisect: {s}", file=sys.stderr, flush=True)
    log(f"{o.row}: {len(commits) - 2} first-parent commits between {good[:12]} and {commits[-1][:12]}")
    measure = shell_measure(o.measure, o.row)
    if o.cache:
        measure = cached(measure, o.cache)
    out = replay(commits, measure, o.floor, o.regression, o.runs, o.max_runs, log)
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
    r.add_argument("--cache", help="JSON file of every run's result; a replay started again resumes from it")
    r.add_argument("--json", action="store_true")
    return cmd_replay(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
