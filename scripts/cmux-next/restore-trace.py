#!/usr/bin/env python3
"""Traces a relaunch restore: what each restored pane shows, step by step, and which pane re-runs caused it.

Usage: restore-trace.py --app "cmux DEV <tag>.app" --out DIR [--seconds 15] [--panes 3]

It uses perf-gate.py's app driver: one launch, the perf gate's 16-pane grid, a quit that ends the
sessions, a relaunch on the same tag. Then, every 0.05 s for --seconds, it reads the grid workspace's
tabs and the app's debug.layout_counters (not reset). Each read that differs from the last one is
one line of DIR/restore-trace.jsonl: the time since the relaunch, the first --panes panes' tabs (all
fields), every pane's tabs in short, the selected tab per pane, the focus, and the counter sources that moved since the last line
(for example "snapshot later items.title PaneController.swift:108": the snapshot fields that re-run
changed, "unchanged" when it changed nothing). The last line is the whole sources map. A tool for
a restore bead (cx-8w027.23); the perf gate's relaunch scenario budgets the restore.
"""
import argparse, importlib.util, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_gate", os.path.join(HERE, "perf-gate.py"))
pg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pg)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="a Debug `cmux DEV <tag>.app` (not running); use a fresh tag")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/cmux-next-restore-trace")
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--panes", type=int, default=3)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    app = pg.App(os.path.abspath(args.app), args.out)

    class Options:
        only, frames, lag = "relaunch", "auto", 3

    gate = pg.Gate(app, Options())
    path = os.path.join(args.out, "restore-trace.jsonl")
    with open(path, "w") as out:
        def read():
            topo = app.topology()
            panes = [p for w in topo.get("workspaces") or [] if w.get("id") == gate.grid_workspace
                     for s in w.get("screens") or [] for p in s.get("panes") or []]
            full = [{"pane": p.get("id"), "selected": p.get("selected_tab"), "tabs": p.get("tabs")} for p in panes[:args.panes]]
            # Every pane, short: per tab id tail, surface, kind, dead, has a terminal id, title.
            short = [[p.get("id", "")[-4:], (p.get("selected_tab") or "")[-4:]]
                     + ["%s/%s/%s%s%s/%s" % (t.get("id", "")[-4:], t.get("surface"), t.get("kind"), "/dead" if t.get("dead") else "",
                                             "/term" if t.get("terminal") else "", (t.get("title") or "")[:16]) for t in p.get("tabs") or []]
                     for p in panes]
            return {"pane_count": len(panes), "panes": full, "short": short, "focus": topo.get("focus")}

        try:
            app.launch()
            gate.build_grid()
            app.quiet_counters()
            app.relaunch()
            start = time.monotonic()
            app.action("goToWorkspace", {"workspace": gate.grid_workspace})
            last, last_sources = None, {}
            interval = 0.05
            while time.monotonic() - start < args.seconds:
                now = read()
                layout = app.rpc("debug.layout_counters", {"reset": False}) or {}
                sources = layout.get("sources") or {}
                moved = {k: v - last_sources.get(k, 0) for k, v in sources.items() if v != last_sources.get(k, 0)}
                if now != last or moved:
                    counters = {k: layout.get(k) for k in ("pane_snapshots", "topology_sends", "workspace_applies")}
                    out.write(json.dumps({"t": round(time.monotonic() - start, 2), "counters": counters,
                                          "moved": moved, **({"state": now} if now != last else {})}) + "\n")
                    out.flush()
                    last, last_sources = now, sources
                time.sleep(interval)  # test script: the gap between two reads
            out.write(json.dumps({"sources": last_sources}) + "\n")
        finally:
            app.stop()
    print(f"restore-trace: wrote {path}", flush=True)


if __name__ == "__main__":
    main()
