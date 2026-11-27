#!/usr/bin/env python3
"""The dev-loop ceiling: each loop's measured p50 over its simulated stage-floor bound.

Goal dev-loop-ceiling (cmuxterm-hq goals/dev-loop-ceiling.md). Leo: "Dev loop at its theoretical ceiling: a measured and
simulated bound for edit-to-running (web swap, daemon restart, Swift inject, startup-time loop) published, and the
measured p50 within 2x of that bound".

Reads OUT/<loop>.json (schema dev-loop-ceiling/loop/v1, written by scripts/measure/dev-loop/<loop>.sh) and writes
OUT/report.json (dev-loop-ceiling/report/v1). A loop's bound is the critical path of its stage graph with each stage
at its floor (the work that stage cannot avoid with today's toolchain at its smallest recompile unit). The simulated
bound draws every stage's floor from its samples DRAWS times and takes the median critical path, so stages a perfect
pipeline overlaps count once. ratio = p50(end to end) / simulated bound p50. worst_ratio is the goal's number; it is
null unless every loop measured (an unmeasured loop is never a pass).

  scripts/measure/dev-loop/bound.py OUT [--loops web_swap,daemon_restart,...]
"""
from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
from pathlib import Path

LOOPS = ("web_swap", "daemon_restart", "swift_inject", "startup_loop")
DRAWS = 10_000
SEED = 20261121  # fixed: the same samples give the same bound
UNATTRIBUTED = "unattributed"


def p50(xs: list[float]) -> float | None:
    return round(statistics.median(xs), 3) if xs else None


def order(graph: dict[str, list[str]]) -> list[str]:
    """The stages in dependency order; raises on a cycle or an unknown dependency."""
    seen: dict[str, int] = {}
    out: list[str] = []

    def visit(s: str) -> None:
        if seen.get(s) == 2:
            return
        if seen.get(s) == 1:
            raise ValueError(f"stage graph has a cycle through {s}")
        if s not in graph:
            raise ValueError(f"stage graph names an unknown stage {s}")
        seen[s] = 1
        for d in graph[s]:
            visit(d)
        seen[s] = 2
        out.append(s)

    for s in graph:
        visit(s)
    return out


def critical_path(graph: dict[str, list[str]], stages: list[str], cost: dict[str, float]) -> float:
    finish: dict[str, float] = {}
    for s in stages:
        finish[s] = cost[s] + max((finish[d] for d in graph[s]), default=0.0)
    return max(finish.values(), default=0.0)


def judge(loop: dict) -> dict:
    """One loop's row: end-to-end p50, deterministic and simulated bound, ratio, and each stage beside its floor."""
    if loop.get("error"):
        return {"measured": False, "why": str(loop["error"])}
    rounds = [r for r in loop.get("rounds") or [] if isinstance(r.get("end_to_end_ms"), (int, float))]
    floors = {k: [float(x) for x in v] for k, v in (loop.get("floors_ms") or {}).items() if v}
    if not rounds:
        return {"measured": False, "why": "no measured rounds"}
    observed: list[str] = []  # in the order the rounds name them, which is the order they ran
    for r in rounds:
        observed += [s for s in (r.get("stages_ms") or {}) if s != UNATTRIBUTED and s not in observed]
    graph = loop.get("graph") or {}
    if not graph:  # no graph given: the observed stages in a plain chain, which never overlaps
        graph = {s: observed[i - 1:i] for i, s in enumerate(observed)}
    graph = {s: list(graph.get(s, [])) for s in set(graph) | set(observed)}
    missing = sorted(s for s in graph if s not in floors)
    if missing:
        return {"measured": False, "why": f"stages without a floor: {', '.join(missing)}"}
    stages = order(graph)
    rng = random.Random(SEED)
    draws = sorted(critical_path(graph, stages, {s: rng.choice(floors[s]) for s in stages}) for _ in range(DRAWS))
    sim = statistics.median(draws)
    det = critical_path(graph, stages, {s: statistics.median(floors[s]) for s in stages})
    e2e = statistics.median(r["end_to_end_ms"] for r in rounds)
    per_stage = {}
    for s in stages + ([UNATTRIBUTED] if any(UNATTRIBUTED in (r.get("stages_ms") or {}) for r in rounds) else []):
        seen = [float(r["stages_ms"][s]) for r in rounds if s in (r.get("stages_ms") or {})]
        f = p50(floors.get(s, []))
        sp = p50(seen)
        per_stage[s] = {"p50_ms": sp, "floor_p50_ms": f,
                        "over_floor_ms": round(sp - f, 3) if sp is not None and f is not None else sp}
    return {
        "measured": True,
        "rounds": len(rounds),
        "end_to_end_p50_ms": round(e2e, 3),
        "bound_ms": round(det, 3),
        "simulated_bound_p50_ms": round(sim, 3),
        "simulated_bound_p10_p90_ms": [round(draws[len(draws) // 10], 3), round(draws[len(draws) * 9 // 10], 3)],
        "ratio": round(e2e / sim, 3) if sim > 0 else None,
        "stages": per_stage,
        "biggest_gap": max(per_stage, key=lambda s: per_stage[s]["over_floor_ms"] or 0.0) if per_stage else None,
        "target": loop.get("target"),
        "graph": graph,
        **({"crates_p50_s": crates} if (crates := crate_p50s(loop)) else {}),
    }


def crate_p50s(loop: dict) -> dict:
    """Each rebuilt crate's p50 rustc seconds and start offset across rounds, slowest first (detail.rounds[].crates).

    The compile stage spans every crate the edit reaches, so a ratio alone cannot say which one went slow; this keeps
    the breakdown in report.json beside the stage it explains."""
    seen: dict[str, list[tuple[float, float]]] = {}
    for r in (loop.get("detail") or {}).get("rounds") or []:
        for c in r.get("crates") or []:
            if isinstance(c.get("s"), (int, float)):
                seen.setdefault(f"{c.get('crate')}:{c.get('kind')}", []).append((float(c["s"]), float(c.get("starts_at_s") or 0)))
    rows = {k: {"p50_s": round(statistics.median(s for s, _ in v), 3),
                "starts_at_p50_s": round(statistics.median(t for _, t in v), 3), "rounds": len(v)}
            for k, v in seen.items()}
    return dict(sorted(rows.items(), key=lambda kv: -kv[1]["p50_s"]))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("out", type=Path)
    ap.add_argument("--loops", default=",".join(LOOPS))
    a = ap.parse_args(argv)
    names = [n for n in a.loops.split(",") if n]
    rows, meta = {}, {}
    for name in names:
        path = a.out / f"{name}.json"
        try:
            loop = json.loads(path.read_text())
            rows[name] = judge(loop)
            meta = meta or {k: loop.get(k) for k in ("commit", "host")}
        except (OSError, ValueError, KeyError, TypeError) as e:
            rows[name] = {"measured": False, "why": f"{path.name}: {e}"}
    complete = all(r["measured"] for r in rows.values()) and set(names) == set(LOOPS)
    ratios = {n: r["ratio"] for n, r in rows.items() if r["measured"] and r["ratio"] is not None}
    worst = max(ratios, key=ratios.get) if ratios else None
    report = {
        "schema": "dev-loop-ceiling/report/v1",
        **meta,
        "complete": complete,
        "worst_ratio": ratios[worst] if complete and worst else None,
        "worst_loop": worst,
        "worst_ratio_measured": ratios[worst] if worst else None,
        "loops": rows,
    }
    (a.out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    for n, r in rows.items():
        if r["measured"]:
            print(f"DLC {n}: p50 {r['end_to_end_p50_ms']:.0f} ms, bound {r['simulated_bound_p50_ms']:.0f} ms, "
                  f"ratio {r['ratio']}x, biggest gap {r['biggest_gap']}")
        else:
            print(f"DLC {n}: UNMEASURED ({r['why']})")
    print(f"DLC-WORST-RATIO {report['worst_ratio'] if complete else 'UNMEASURED'}")
    return 0 if complete else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
