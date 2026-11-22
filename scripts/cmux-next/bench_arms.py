"""The three arms of a felt bench and its headline (cmux-ad, reward-hacking audit 2 item 3c).

A bench whose app keeps work made ahead (a spare page, a spare Chromium window, the Ctrl-` stand-in, a warmed
picker, a pooled agent) times three arms of its press:

  warm   the press after the bench waited for the made-ahead work (the spare is ready, the warm-up ended);
  quick  two quick presses: the timed press comes right after the one before, with no wait for the spare or the
         warm-up to refill;
  cold   cold, no wait: the timed press comes right after launch, or right after the spare was consumed, with no
         warm-up wait.

A person who presses quickly or right after launch waits for the quick or the cold arm, never only the warm one.
So the bench's HEADLINE is its WORST arm: the arm with a defect (a bench's own count of a fault a person sees, such as
cmd-n-paint's blank frames; the most first) or a missed run (a press that gave no result), else the arm with the
highest p95, then the highest max. An arm that did not run is listed as not run and never chosen.

Every arm is reported with n, missed, p50, p95, p99 and max (linear interpolation, as scripts/perf-lab/perf_stats.py).
"""

ARMS = ("warm", "quick", "cold")
RULE = ("headline = the WORST arm (a defect or a missed run first, else the highest p95, then the highest max); "
        "warm = after the spare or warm-up is ready, quick = the press right after another press, "
        "cold = right after launch or after the spare was consumed, with no warm-up wait")


def pct(values, q):
    """The q-quantile of the numeric values, linear interpolation; None when there is none."""
    vals = sorted(v for v in values if isinstance(v, (int, float)) and not isinstance(v, bool))
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return round(vals[lo] + (vals[hi] - vals[lo]) * (k - lo), 2)


def stats(samples):
    """{n, missed, p50, p95, p99, max} of one arm's samples; a None sample is a missed run."""
    samples = list(samples)
    return {"n": len(samples), "missed": sum(1 for s in samples if s is None),
            "p50": pct(samples, .5), "p95": pct(samples, .95), "p99": pct(samples, .99), "max": pct(samples, 1)}


def worst(arms, defects=None):
    """The name of the worst arm of {name: stats}, by RULE; None when no arm ran. `defects` ({name: count}) puts an
    arm with a defect first, the most defects first."""
    ran = {name: s for name, s in arms.items() if s and s["n"]}
    if not ran:
        return None
    defects = defects or {}

    def badness(item):
        name, s = item
        count = defects.get(name) or 0
        return (count > 0 or s["missed"] > 0, count, s["missed"] > 0, s["p95"] if s["p95"] is not None else float("inf"),
                s["max"] if s["max"] is not None else float("inf"))

    return max(ran.items(), key=badness)[0]


def report(bench, metric, unit, samples_by_arm, out=print, defects=None, defect_name="defects"):
    """Prints one ARM line per arm and the HEADLINE line (the worst arm, with RULE); returns
    {"metric", "unit", "arms": {name: stats}, "not_run": [...], "headline": name, "rule": RULE}. `defects`
    ({arm: count}, named `defect_name`) is printed in each ARM line and the HEADLINE, and an arm with any is worst."""
    arms = {name: stats(samples_by_arm.get(name) or []) for name in ARMS if name in samples_by_arm}
    not_run = [name for name in ARMS if not (arms.get(name) or {}).get("n")]
    defects = {name: count for name, count in (defects or {}).items() if name in arms}
    tail = (lambda name: f" {defect_name}={defects.get(name, 0)}") if defects else (lambda name: "")
    for name, s in arms.items():
        if s["n"]:
            out(f"ARM {bench} {metric} {name}: n={s['n']} missed={s['missed']} p50={s['p50']} p95={s['p95']} "
                f"p99={s['p99']} max={s['max']} {unit}{tail(name)}")
    head = worst(arms, defects)
    if head:
        s = arms[head]
        out(f"HEADLINE {bench} {metric} = {head} arm: p50={s['p50']} p95={s['p95']} p99={s['p99']} max={s['max']} {unit} "
            f"missed={s['missed']}{tail(head)}" + (f" (not run: {', '.join(not_run)})" if not_run else "") + f" [{RULE}]")
    else:
        out(f"HEADLINE {bench} {metric} = none: no arm ran [{RULE}]")
    return {"metric": metric, "unit": unit, "arms": arms, "not_run": not_run, "headline": head, "rule": RULE,
            defect_name: defects or None}
