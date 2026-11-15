#!/usr/bin/env python3
"""Settings, History and Cloud first open, and idle memory: the page spare made at launch vs made on intent (CMUX-571).

The app parked a Settings spare page (WebKit, about 106 MB with its processes) at launch, so the first Settings,
History or Cloud open was warm. Now no spare exists until a sign of intent (a menu or palette open, ⌘ alone, a pointer
on their sidebar item: PageHostPool.noteIntent), and an idle limit frees it. Both arms run in this one build and step:

  before   CMUX_NEXT_BENCH_PAGE_SPARE_AT_LAUNCH=1: the spare made at launch's first idle moment and kept (the
           behavior before this change, PageHostPool.noteLikely)
  after    no spare at launch; `as_is` opens with no sign first, `intent` opens `lead` ms after one (each of `--leads`)

Each open is the first of a fresh launch (BenchApp: an empty saved session), `--settle` s after the window showed,
through `debug.page_open_bench` (PageOpenBench.swift): the page's action to the first display frame that shows it
painted (`drawn_ms`). Each launch also samples the idle app's memory before the open (bench_memory.sample: the app's
processes and the WebKit processes it owns). Rounds interleave the arms, so host drift shows in both. A last launch of
the after arm checks the idle limit: a sign of intent, the spare loaded, then freed after `--idle-limit` s.

Usage: page-spare-bench.py --app APP --out DIR [--json PATH] [--rounds 3] [--leads 150,300] [--settle 20]
Fleet: scripts/measure/split-spring.sh --suite=page-spare [--arg=--rounds=N]
Prints PAGE-SPARE-OPEN and PAGE-SPARE-MEMORY lines per launch, then PAGE-SPARE-SUMMARY lines (p50/p95/max).
"""
import argparse, json, os, statistics, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

PAGES = ("settings", "history", "cloud")
BEFORE_ENV = {"CMUX_NEXT_BENCH_PAGE_SPARE_AT_LAUNCH": "1"}


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--leads", default="150,300")
    parser.add_argument("--settle", type=float, default=20.0, help="seconds after launch before the memory sample and open")
    parser.add_argument("--idle-limit", type=float, default=5.0)
    opts, _unknown = parser.parse_known_args(argv)
    return opts


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 1)


def launch(opts, env):
    import bench_memory
    # The app starts as this script's child, so macOS holds this script responsible for its WebKit processes: they count
    # as the app's when they did not run before the launch (bench_memory.launch does the same).
    bench_memory._direct_launch = True
    bench_memory._webkit_before.update(p for p, _, cmd in bench_memory.process_table() if "com.apple.WebKit." in cmd)
    app = BenchApp(opts.app, out=opts.out, env=env, window=(40, 40, 1440, 900))
    app.launch(timeout=180)
    return app


def memory(app, label):
    import bench_memory
    got = bench_memory.sample(app.process.pid, app.app, label, 1)
    row = {"label": label, "total_footprint_mb": got["total_footprint_mb"],
           "kinds": {k: v["footprint_mb"] for k, v in got["kinds"].items()}, "processes": len(got["processes"])}
    print("PAGE-SPARE-MEMORY " + json.dumps(row), flush=True)
    return row


def pool(app, action=None):
    return app.rpc("debug.page_host_pool", {"action": action} if action else {}, timeout=30) or {}


def one(opts, arm, page, mode, lead):
    app = launch(opts, BEFORE_ENV if arm == "before" else {})
    try:
        time.sleep(opts.settle)  # bench pacing: past the launch settle and the before arm's idle-moment spare
        state = pool(app)
        mem = memory(app, f"{arm}-idle")
        params = {"page": page, "mode": mode}
        if lead is not None:
            params["lead_ms"] = lead
        reply = app.rpc("debug.page_open_bench", params, timeout=60) or {}
        row = {"arm": arm, "page": page, "mode": mode, "lead_ms": lead, "pool_at_rest": {k: state.get(k) for k in ("host_count", "spare_ready", "likely")},
               "idle_mb": mem["total_footprint_mb"], "idle_kinds": mem["kinds"], **reply}
        print("PAGE-SPARE-OPEN " + json.dumps(row), flush=True)
        return row
    finally:
        app.stop()


def idle_limit_check(opts):
    app = launch(opts, {})
    try:
        time.sleep(opts.settle)  # bench pacing: past the launch settle
        rows = [memory(app, "after-at-rest")]
        app.rpc("debug.page_open_bench", {"idle_limit_s": opts.idle_limit})
        pool(app, "intent")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not pool(app).get("spare_ready"):
            time.sleep(0.25)  # bench pacing: the spare loads
        time.sleep(3)  # bench pacing: the spare's processes settle
        rows.append(memory(app, "after-intent-spare-made"))
        time.sleep(opts.idle_limit + 10)  # bench pacing: past the idle limit and the freed processes' wind-down
        rows.append(memory(app, "after-idle-limit"))
        rows.append({"label": "pool-after-idle-limit", **pool(app)})
        return rows
    finally:
        app.stop()


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    leads = [float(x) for x in opts.leads.split(",") if x]
    conditions = [("before", "as_is", None), ("after", "as_is", None)] + [("after", "intent", lead) for lead in leads]
    report = {"runs": [], "summary": [], "idle_limit": []}
    try:
        for index in range(opts.rounds):
            order = conditions if index % 2 == 0 else list(reversed(conditions))
            for page in PAGES:
                for arm, mode, lead in order:
                    report["runs"].append(one(opts, arm, page, mode, lead))
        for page in PAGES:
            for arm, mode, lead in conditions:
                runs = [r for r in report["runs"] if (r["arm"], r["page"], r["mode"], r["lead_ms"]) == (arm, page, mode, lead)]
                drawn = [r.get("drawn_ms") for r in runs]
                entry = {"page": page, "arm": arm, "mode": mode, "lead_ms": lead, "n": len(runs),
                         "drawn_ms": {"p50": pct(drawn, 0.5), "p95": pct(drawn, 0.95), "max": pct(drawn, 1.0)},
                         "took_spare": sum(1 for r in runs if r.get("spare")), "not_drawn": sum(1 for d in drawn if d is None),
                         "intent_ready_ms": [r.get("intent_ready_ms") for r in runs] if mode == "intent" else None}
                report["summary"].append(entry)
                print("PAGE-SPARE-SUMMARY " + json.dumps(entry), flush=True)
        for arm in ("before", "after"):
            idle = [r["idle_mb"] for r in report["runs"] if r["arm"] == arm]
            entry = {"arm": arm, "idle_mb_median": round(statistics.median(idle), 1) if idle else None,
                     "idle_mb_min": min(idle, default=None), "idle_mb_max": max(idle, default=None), "n": len(idle)}
            report["summary"].append(entry)
            print("PAGE-SPARE-SUMMARY " + json.dumps(entry), flush=True)
        report["idle_limit"] = idle_limit_check(opts)
        print("PAGE-SPARE-IDLE-LIMIT " + json.dumps(report["idle_limit"]), flush=True)
    finally:
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
    failed = any(r.get("drawn_ms") is None or r.get("error") for r in report["runs"])
    return 1 if failed or not report["runs"] else 0


if __name__ == "__main__":
    sys.exit(main())
