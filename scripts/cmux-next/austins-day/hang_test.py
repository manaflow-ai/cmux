#!/usr/bin/env python3
"""The #28041 extension (cmux-ad 2026-10-30): did the head make acpmux's first failing Chief wave hang at
the 90 s agent_start limit more often than the base?

  hang_test.py RUN_DIR [RUN_DIR...]     (each RUN_DIR has run.json and arm.json; base and head arms, by round)

Per run: whether any chat open hit "agent_start did not finish within 90s" (a 90 s hang), and how many.
Tests, over the rounds that have both arms on one host:
- McNemar's exact test on the paired yes/no (two-sided binomial on the discordant rounds);
- Fisher's exact test on the 2x2 table of runs with / without a hang per arm (ignores pairing);
- the paired t-interval (95 %) of the hang count, as summarize.py computes it.
Prints a table and one JSON line `HANG-TEST {...}`.
"""
import json
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
T975 = (12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228, 2.201, 2.179, 2.160, 2.145, 2.131,
        2.120, 2.110, 2.101, 2.093, 2.086, 2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042)


def hangs(run_dir):
    with open(os.path.join(run_dir, "run.json")) as f:
        run = json.load(f)
    answers = [a for w in run["series"]["waves"] for a in (w.get("answers") or [])]
    return sum(1 for a in answers if "agent_start did not finish" in (a.get("error") or ""))


def binom_two_sided(k, n):
    """Exact two-sided binomial p (p = 0.5) for k of n."""
    if n == 0:
        return 1.0
    probs = [math.comb(n, i) / 2 ** n for i in range(n + 1)]
    return min(1.0, sum(p for p in probs if p <= probs[k] + 1e-12))


def fisher_two_sided(a, b, c, d):
    """Fisher's exact test, two-sided, for [[a, b], [c, d]]."""
    n, row1, col1 = a + b + c + d, a + b, a + c

    def p(x):
        return math.comb(col1, x) * math.comb(n - col1, row1 - x) / math.comb(n, row1)
    observed = p(a)
    lo, hi = max(0, row1 + col1 - n), min(row1, col1)
    return min(1.0, sum(p(x) for x in range(lo, hi + 1) if p(x) <= observed + 1e-12))


def main():
    rounds = {}
    for d in sys.argv[1:]:
        with open(os.path.join(d, "arm.json")) as f:
            arm = json.load(f)
        rounds.setdefault((arm.get("batch", ""), arm["round"]), {})[arm["arm"]] = {"dir": d, "host": arm["host"], "hangs": hangs(d)}
    pairs = [(k, v) for k, v in sorted(rounds.items()) if "base" in v and "head" in v and v["base"]["host"] == v["head"]["host"]]
    print(f"{'round':>12} {'host':>8} {'base hangs':>11} {'head hangs':>11}")
    for (batch, rnd), v in pairs:
        print(f"{(batch + ' r' + str(rnd)).strip():>12} {v['base']['host']:>8} {v['base']['hangs']:>11} {v['head']['hangs']:>11}")
    b_yes = [v["base"]["hangs"] > 0 for _, v in pairs]
    h_yes = [v["head"]["hangs"] > 0 for _, v in pairs]
    only_head = sum(1 for b, h in zip(b_yes, h_yes) if h and not b)
    only_base = sum(1 for b, h in zip(b_yes, h_yes) if b and not h)
    mcnemar = binom_two_sided(min(only_head, only_base), only_head + only_base)
    a, b = sum(h_yes), len(h_yes) - sum(h_yes)
    c, d = sum(b_yes), len(b_yes) - sum(b_yes)
    fisher = fisher_two_sided(a, b, c, d)
    diffs = [v["head"]["hangs"] - v["base"]["hangs"] for _, v in pairs]
    if len(diffs) >= 2:
        mean = statistics.mean(diffs)
        half = (T975[len(diffs) - 2] if len(diffs) - 1 <= len(T975) else 1.96) * statistics.stdev(diffs) / math.sqrt(len(diffs))
        ci = [mean - half, mean + half]
    else:
        mean, ci = (diffs[0] if diffs else None), [None, None]
    out = {"rounds": len(pairs), "runs_with_hang": {"head": a, "base": c}, "discordant": {"only_head": only_head, "only_base": only_base},
           "mcnemar_exact_p": round(mcnemar, 5), "fisher_exact_p": round(fisher, 5),
           "hang_count_head_minus_base": {"mean": mean, "ci95": ci}}
    print(f"runs with a 90 s hang: head {a} of {len(pairs)}, base {c} of {len(pairs)}; discordant rounds: head only {only_head}, "
          f"base only {only_base}; McNemar exact p = {mcnemar:.4g}; Fisher exact p = {fisher:.4g}; "
          f"hang count head - base: {mean} [{ci[0]}, {ci[1]}] (paired t, 95 %)")
    print("HANG-TEST " + json.dumps(out))


if __name__ == "__main__":
    main()
