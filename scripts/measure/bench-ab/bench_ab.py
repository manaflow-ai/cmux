#!/usr/bin/env python3
"""Interleaved A/B of a fleet bench, with an A/A self-test and bootstrap intervals (fast benches, cmux-ad 2026-10-31).

This reads the JSON artifacts that the existing benches already write. It does not run a bench. The benches stay
where they are (scripts/measure/split-spring.sh suites, scripts/measure/instant-new-surfaces.sh); driver.py submits
their fleet steps, and publish.py writes the table.

  bench_ab.py compare BENCH ARTIFACT_DIR    one JSON report on stdout

ARTIFACT_DIR holds one file per fleet job: bench-<BENCH>[-<order>]-r<N>-(before|after)-<sha8>.json. "before" is arm A
(the base tip), "after" is arm B (the measured tip). Files of one BENCH with a different <order> (for example
instant-ab and instant-ba, one per mini) are separate benches: give the full name.

For each (key, metric) row and each arm: p50, p95, p99 and max, each with a 95 % percentile-bootstrap interval
(BOOT resamples, a fixed seed). delta = B - A per statistic, with its bootstrap interval (each arm resampled on its
own). A/A = the A jobs split into two halves (jobs 1, 3, ... against jobs 2, 4, ...), the same delta and interval.

Verdict per statistic:
  REGRESSION  the B - A interval is above 0, and the A/A interval of the same statistic contains 0
  IMPROVED    the B - A interval is below 0, and the A/A interval contains 0
  NOISY       the A/A interval does not contain 0: this run cannot judge the row
  same        the B - A interval contains 0
  too-few     an arm has fewer than MIN_JOBS jobs; no-AA: the A/A halves are empty

The unit of resampling is the raw sample where the bench keeps it ("sample": instant-new-surfaces runs[], bench-startup
runs), else one value per job or round ("replicate": every-action rows keep only their own p50/p95, typing-frame and
terminal-resize keep one value per round). A replicate row is judged on its median only.
"""
import glob, json, os, random, re, sys

BOOT = 2000
SEED = 20261031
MIN_JOBS = 2


def q(vals, p):
    """The p-quantile, linear interpolation (as scripts/cmux-next/bench_arms.py); None for no values."""
    s = sorted(vals)
    if not s:
        return None
    k = (len(s) - 1) * p
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


STATS = {"p50": lambda v: q(v, .5), "p95": lambda v: q(v, .95), "p99": lambda v: q(v, .99), "max": max}


def boot(vals, f, rng):
    """95 % percentile-bootstrap interval of f over vals; None for fewer than 2 values."""
    if len(vals) < 2:
        return None
    xs = sorted(f([rng.choice(vals) for _ in vals]) for _ in range(BOOT))
    return [round(q(xs, .025), 2), round(q(xs, .975), 2)]


def boot_delta(a, b, f, rng):
    """95 % interval of f(B) - f(A), each arm resampled on its own; None when an arm has fewer than 2 values."""
    if len(a) < 2 or len(b) < 2:
        return None
    xs = sorted(f([rng.choice(b) for _ in b]) - f([rng.choice(a) for _ in a]) for _ in range(BOOT))
    return [round(q(xs, .025), 2), round(q(xs, .975), 2)]


def verdict(delta_ci, aa_ci, jobs_a, jobs_b):
    if jobs_a < MIN_JOBS or jobs_b < MIN_JOBS or delta_ci is None:
        return "too-few"
    if aa_ci is None:
        return "no-AA"
    if not aa_ci[0] <= 0 <= aa_ci[1]:
        return "NOISY"
    if delta_ci[0] > 0:
        return "REGRESSION"
    if delta_ci[1] < 0:
        return "IMPROVED"
    return "same"


def load(art_dir, bench):
    """{"before": [(round, doc)], "after": [...]} in round order, for exactly this bench name."""
    arms = {"before": [], "after": []}
    pat = re.compile(rf"^bench-{re.escape(bench)}-r(\d+)-(before|after)-[0-9a-f]+\.json$")
    for path in glob.glob(os.path.join(art_dir, f"bench-{bench}-r*-*.json")):
        m = pat.match(os.path.basename(path))
        if not m:
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
        ja, jb = sum(bool(j) for j in a_jobs), sum(bool(j) for j in b_jobs)
        a1 = [v for j in a_jobs[0::2] for v in j]
        a2 = [v for j in a_jobs[1::2] for v in j]
        row = {"key": key, "metric": metric, "unit": unit, "jobs_a": ja, "jobs_b": jb, "n_a": len(a), "n_b": len(b),
               "a": {}, "b": {}, "delta": {}, "aa": {}, "verdict": {}}
        stats = STATS if unit == "sample" else {"p50": STATS["p50"]}
        for st, f in stats.items():
            row["a"][st] = [round(f(a), 2), boot(a, f, rng)]
            row["b"][st] = [round(f(b), 2), boot(b, f, rng)]
            row["delta"][st] = [round(f(b) - f(a), 2), boot_delta(a, b, f, rng)]
            row["aa"][st] = [round(f(a2) - f(a1), 2), boot_delta(a1, a2, f, rng)] if a1 and a2 else [None, None]
            if st != "max":
                row["verdict"][st] = verdict(row["delta"][st][1], row["aa"][st][1], ja, jb)
        rows.append(row)
    return {"bench": bench, "unit": unit, "jobs_a": len(per["before"]), "jobs_b": len(per["after"]), "rows": rows}


def main(argv):
    if len(argv) != 4 or argv[1] != "compare":
        sys.exit(__doc__)
    print(json.dumps(compare(argv[2], load(argv[3], argv[2])), indent=1))


if __name__ == "__main__":
    main(sys.argv)
