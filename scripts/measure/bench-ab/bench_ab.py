#!/usr/bin/env python3
"""Interleaved A/B of a fleet bench, with an A/A self-test and bootstrap intervals (fast benches, cmux-ad 2026-10-31).

This reads the JSON artifacts that the existing benches already write. It does not run a bench. The benches stay
where they are (scripts/measure/split-spring.sh suites, scripts/measure/instant-new-surfaces.sh); driver.py submits
their fleet steps, and publish.py writes the table.

  bench_ab.py compare BENCH ARTIFACT_DIR [BASE_SHA TIP_SHA]    one JSON report on stdout

ARTIFACT_DIR holds one file per fleet job: bench-<BENCH>[-<order>]-r<N>-(before|after)-<sha8>.json. "before" is arm A
(the base tip), "after" is arm B (the measured tip). Files of one BENCH with a different <order> (for example
instant-ab and instant-ba, one per mini) are separate benches: give the full name.

For each (key, metric) row and each arm: p50, p95, p99 and max. p50/p95/p99 get a 95 % interval from a two-level
(hierarchical) bootstrap: resample the arm's jobs, then the samples inside each drawn job (BOOT resamples, a fixed
seed), so the spread between jobs (a mini's state, a launch) counts, not only the spread inside one job. max gets no
interval and no verdict. delta = B - A per statistic, each arm resampled on its own. A/A = the A jobs split into two
halves (jobs 1, 3, ... against jobs 2, 4, ...), the same delta and interval.

Verdict per statistic:
  REGRESSION  the B - A interval is above the effect floor (max(FLOOR_ABS, FLOOR_REL x A's value)), and the A/A
              interval of the same statistic contains 0
  IMPROVED    the same, below minus the floor
  NOISY       the A/A interval does not contain 0: this run cannot judge the row
  same        otherwise
  too-few     an arm has fewer than MIN_JOBS jobs, or fewer than MIN_SAMPLES[stat] samples (a p99 of 30 samples is
              its second-largest value: no verdict); no-AA: an A/A half has fewer than MIN_JOBS jobs
The floor and the hierarchical resampling keep the false REGRESSION rate on equal arms low across the dozens of rows of a
tip (scripts/measure/tests/bench-ab.test.py checks it over many seeds).

The unit of resampling is the raw sample where the bench keeps it ("sample": instant-new-surfaces runs[], bench-startup
runs), else one value per job or round ("replicate": every-action rows keep only their own p50/p95, typing-frame and
terminal-resize keep one value per round, and a job's rounds stay together as that job). A replicate row is judged on
its median only, and needs MIN_JOBS jobs in each arm and in each A/A half.
"""
import glob, json, os, random, re, sys

BOOT = 2000
SEED = 20261031
MIN_JOBS = 2
MIN_SAMPLES = {"p50": 2, "p95": 40, "p99": 200}  # per arm; for a replicate row (one value per job) p50 only
FLOOR_ABS = 1.0   # ms, or one frame for a count
FLOOR_REL = 0.05  # of A's value


def q(vals, p):
    """The p-quantile, linear interpolation (as scripts/cmux-next/bench_arms.py); None for no values."""
    s = sorted(vals)
    if not s:
        return None
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


STATS = {"p50": lambda v: q(v, .5), "p95": lambda v: q(v, .95), "p99": lambda v: q(v, .99), "max": max}


def resample(jobs, rng):
    """One two-level bootstrap draw: jobs with replacement, then each drawn job's samples with replacement."""
    out = []
    for j in (rng.choice(jobs) for _ in jobs):
        out.extend(rng.choice(j) for _ in j)
    return out


def boot(jobs, f, rng):
    """95 % interval of f over an arm given as a list of per-job sample lists; None for fewer than 2 samples."""
    jobs = [j for j in jobs if j]
    if sum(len(j) for j in jobs) < 2:
        return None
    xs = sorted(f(resample(jobs, rng)) for _ in range(BOOT))
    return [round(q(xs, .025), 2), round(q(xs, .975), 2)]


def boot_delta(a_jobs, b_jobs, f, rng):
    """95 % interval of f(B) - f(A), each arm drawn on its own (two-level); None when an arm has under 2 samples."""
    a_jobs, b_jobs = [j for j in a_jobs if j], [j for j in b_jobs if j]
    if sum(map(len, a_jobs)) < 2 or sum(map(len, b_jobs)) < 2:
        return None
    xs = sorted(f(resample(b_jobs, rng)) - f(resample(a_jobs, rng)) for _ in range(BOOT))
    return [round(q(xs, .025), 2), round(q(xs, .975), 2)]


def verdict(delta_ci, aa_ci, jobs_a, jobs_b, aa_jobs=(0, 0), n=(0, 0), stat="p50", a_value=0.0):
    if jobs_a < MIN_JOBS or jobs_b < MIN_JOBS or delta_ci is None or min(n) < MIN_SAMPLES.get(stat, 2):
        return "too-few"
    if aa_ci is None or min(aa_jobs) < MIN_JOBS:
        return "no-AA"
    if not aa_ci[0] <= 0 <= aa_ci[1]:
        return "NOISY"
    floor = max(FLOOR_ABS, FLOOR_REL * abs(a_value or 0.0))
    if delta_ci[0] > floor:
        return "REGRESSION"
    if delta_ci[1] < -floor:
        return "IMPROVED"
    return "same"


def load(art_dir, bench, base=None, tip=None):
    """{"before": [(round, doc)], "after": [...]} in round order, for exactly this bench name. With base and tip
    (shas, any length >= 8), an artifact counts only when its file names that arm's commit, so files of an earlier
    tip in a reused folder never join an arm."""
    arms = {"before": [], "after": []}
    want = {"before": (base or "")[:8], "after": (tip or "")[:8]}
    pat = re.compile(rf"^bench-{re.escape(bench)}-r(\d+)-(before|after)-([0-9a-f]+)\.json$")
    for path in glob.glob(os.path.join(art_dir, f"bench-{bench}-r*-*.json")):
        m = pat.match(os.path.basename(path))
        if not m or (want[m.group(2)] and not m.group(3).startswith(want[m.group(2)])):
            continue
        try:
            with open(path) as f:
                arms[m.group(2)].append((int(m.group(1)), json.load(f)))
        except (OSError, ValueError):
            continue
    for jobs in arms.values():
        jobs.sort(key=lambda j: j[0])
    return arms


def _add(out, key, metric, value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        out.setdefault(key, {}).setdefault(metric, []).append(float(value))


def samples_instant(doc):
    """instant-new-surfaces-bench.py: raw runs[] per command and phase (idle@Nws, load@Nws, quick, cold)."""
    out = {}
    for r in doc.get("runs") or []:
        key = f"{r.get('command')}/{r.get('phase')}"
        for m in ("visible_ms", "confirmed_ms", "key_ms", "typeable_ms"):
            _add(out, key, m, r.get(m))
    return out


def missed_instant(doc):
    """Runs that gave no result (a missed press), per command/phase: they are not samples, so they are counted apart
    (a B that misses more cannot look faster). A --typeable run (it has a "lost" key or typeable_ms) is missed when it
    has no typeable_ms; any other run is missed when it has no visible_ms."""
    out = {}
    for r in doc.get("runs") or []:
        metric = "typeable_ms" if ("lost" in r or "typeable_ms" in r) else "visible_ms"
        if not isinstance(r.get(metric), (int, float)) or isinstance(r.get(metric), bool):
            key = f"{r.get('command')}/{r.get('phase')}"
            out[key] = out.get(key, 0) + 1
    return out


def samples_every_action(doc):
    """every-action-sweep.py: one replicate per job: each row's p50/p95 (commit, turn, wait, key_to_frame, rpc) and
    its missed frames; for interactions also their frame counters."""
    out = {}
    for s in doc.get("sessions") or []:
        for r in (s.get("rows") or []) + (s.get("interactions") or []):
            key = f"{s.get('name')}/{r.get('id')}"
            interaction = r.get("kind") == "interaction"
            for m in ("commit_ms", "turn_ms", "wait_ms", "key_to_frame_ms") + (("rpc_ms", "input_ms") if interaction else ()):
                v = r.get(m)
                if isinstance(v, dict):
                    _add(out, key, m + ".p95", v.get("p95"))
                    _add(out, key, m + ".p50", v.get("p50"))
            fr = r.get("frames")
            if isinstance(fr, dict) and fr.get("missed_total") is not None:
                _add(out, key, "missed_frames", fr["missed_total"])
            elif isinstance(fr, dict) and interaction:
                for m in ("missed", "max_ms", "main_p95_ms", "main_max_ms"):
                    _add(out, key, "frames." + m, fr.get(m))
    return out


def samples_typing(doc):
    """typing-frame-bench.py: one replicate per round per surface.phase (key_to_frame_ms p50/p95/p99/max)."""
    out = {}
    for r in doc.get("runs") or []:
        key = f"{r.get('session', 'light')}/{r.get('surface')}.{r.get('phase')}"
        for st, v in (r.get("key_to_frame_ms") or {}).items():
            if st in ("p50", "p95", "p99", "max"):
                _add(out, key, f"key_to_frame.{st}", v)
    return out


def samples_launch(doc):
    """bench-startup.py (--suite=launch): raw marks (ms since process start) of every run, per mode."""
    out = {}
    for _tag, modes in (doc or {}).items():
        if not isinstance(modes, dict):
            continue
        for mode, runs in modes.items():
            for marks in runs if isinstance(runs, list) else []:
                verdict = ((marks or {}).get("daemons") or {}).get("verdict")
                if verdict not in (None, "run"):
                    continue  # its daemons or hosts were not the build under test: no sample (bench-startup prints it)
                for mark, v in (marks or {}).items():
                    _add(out, mode, mark, v)
    return out


def samples_resize(doc):
    """bench-terminal-resize.py: one replicate per drag round (frame intervals, missed, main-thread time); the idle
    cursor layout's frame count."""
    out = {}
    for r in doc.get("layouts") or []:
        key = str(r.get("layout") or "?")
        for rnd in r.get("rounds") or []:
            fr = rnd.get("frames") or {}
            for m in ("p95_ms", "p99_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms"):
                _add(out, key, "frames." + m, fr.get(m))
        if not isinstance(r.get("frames"), dict):
            _add(out, key, "ghostty_frames", r.get("frames"))
    return out


EXTRACT = {"instant": samples_instant, "ealight": samples_every_action, "eastress": samples_every_action,
           "typing": samples_typing, "launch": samples_launch, "restore": samples_launch, "resize": samples_resize}
RAW = {"instant", "launch", "restore"}


def kind(bench):
    """The extractor family of a bench name: instant-ab and instant-ba are both instant."""
    return bench if bench in EXTRACT else bench.split("-")[0]


def compare(bench, arms, seed=SEED):
    family = kind(bench)
    ext = EXTRACT[family]
    rng = random.Random(seed)
    per = {arm: [ext(doc) for _, doc in jobs] for arm, jobs in arms.items()}
    missed = {}
    if family == "instant":
        for arm, jobs in arms.items():
            for _, doc in jobs:
                for key, n in missed_instant(doc).items():
                    missed.setdefault(key, {"before": 0, "after": 0})[arm] += n
    keys = sorted({(k, m) for jobs in per.values() for d in jobs for k, ms in d.items() for m in ms})
    unit = "sample" if family in RAW else "replicate"
    rows = []
    for key, metric in keys:
        a_jobs = [d.get(key, {}).get(metric, []) for d in per["before"]]
        b_jobs = [d.get(key, {}).get(metric, []) for d in per["after"]]
        a = [v for j in a_jobs for v in j]
        b = [v for j in b_jobs for v in j]
        if not a or not b:
            continue
        # The fleet job is the unit: a job's rounds (typing-frame, terminal-resize --rounds) share one launch on one
        # mini, so they stay together in the job's list; the two-level bootstrap draws jobs, then rounds in each job.
        a_jobs, b_jobs = [j for j in a_jobs if j], [j for j in b_jobs if j]
        ja, jb = len(a_jobs), len(b_jobs)
        a1, a2 = a_jobs[0::2], a_jobs[1::2]
        row = {"key": key, "metric": metric, "unit": unit, "jobs_a": ja, "jobs_b": jb, "n_a": len(a), "n_b": len(b),
               "a": {}, "b": {}, "delta": {}, "aa": {}, "verdict": {}}
        if key in missed:
            row["missed"] = missed[key]
        stats = ("p50", "p95", "p99", "max") if unit == "sample" else ("p50",)
        for st in stats:
            f = STATS[st]
            if st == "max":
                row["a"][st], row["b"][st] = [round(f(a), 2), None], [round(f(b), 2), None]
                row["delta"][st], row["aa"][st] = [round(f(b) - f(a), 2), None], [None, None]
                continue
            row["a"][st] = [round(f(a), 2), boot(a_jobs, f, rng)]
            row["b"][st] = [round(f(b), 2), boot(b_jobs, f, rng)]
            row["delta"][st] = [round(f(b) - f(a), 2), boot_delta(a_jobs, b_jobs, f, rng)]
            flat1, flat2 = [v for j in a1 for v in j], [v for j in a2 for v in j]
            row["aa"][st] = ([round(f(flat2) - f(flat1), 2), boot_delta(a1, a2, f, rng)] if flat1 and flat2
                             else [None, None])
            if unit == "replicate":
                aa_jobs = (len(a1), len(a2))  # values per job are few: each A/A half needs MIN_JOBS jobs
            else:
                aa_jobs = (MIN_JOBS, MIN_JOBS) if a1 and a2 else (0, 0)  # raw samples: one job per half is enough
            row["verdict"][st] = verdict(row["delta"][st][1], row["aa"][st][1], ja, jb, aa_jobs,
                                         (len(a), len(b)), st, f(a))
        rows.append(row)
    return {"bench": bench, "unit": unit, "jobs_a": len(per["before"]), "jobs_b": len(per["after"]), "rows": rows}


def main(argv):
    if len(argv) not in (4, 6) or argv[1] != "compare":
        sys.exit(__doc__)
    base, tip = (argv[4], argv[5]) if len(argv) == 6 else (None, None)
    print(json.dumps(compare(argv[2], load(argv[3], argv[2], base, tip)), indent=1))


if __name__ == "__main__":
    main(sys.argv)
