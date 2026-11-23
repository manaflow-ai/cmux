#!/usr/bin/env python3
"""Opening and closing tabs, and opening a lot of terminals: key to visible, and whether it stays as fast as tabs pile up
(ask-8a0837950b; Leo, 2026-11-10: "opening up a lot of terminals isn't super fast? opening/closing tabs was p important
to lawrence ... we defo need to encode and warn sometimes if those get slow").

Launches the tagged app itself (bench_launch.BenchApp: no activation, scratch config) and, in one terminal workspace:

  1. open_close@1   `--cycles` times: Cmd-T (`debug.new_tab bench_open`: the pane shows the New Tab page and its strip
                    shows the tab), then Cmd-W on it (`bench_close`). The pane holds one terminal.
  2. new_terminal   `--terminals` Ctrl-` presses in a row (`debug.new_tab bench_create new_terminal`), none undone, each
                    0.4 s after the last so its shell starts. The first third and the last third are reported apart,
                    and `growth` is the last third's p50 over the first third's: 1.0 means the 30th terminal opens as
                    fast as the 1st.
  3. open_close@N   step 1 again with the pane holding N = 1 + `--terminals` tabs.
  4. close_terminal Cmd-W on each burst terminal (`debug.key`), timed from the key to the pane's selected tab changing in
                    `debug.focus` (the socket read every 2 ms: an upper bound of a few ms over the app's own time, no frame).

Every timed open and close goes through the real key path (`debug.key`, in the app). The app reports `visible_ms`, the
display frame at which the result shows, and `key_ms`, the key's synchronous main-thread time. Each step's rows have
p50/p95/max of those; perf-budgets.py (group `terminal_burst`) maps them to rows `terminal_burst.*` and their budgets.
The group is opt-in (perf-budgets.py OPT_IN_BENCHES: the default suite, which stable-next gates, never runs it); the
perf cron's `tabs` part is to add it to its --only, so the cron's regression issue warns when these rows slow down.

Usage: tab-churn-bench.py --tag TAG --app PATH [--cycles 12] [--terminals 30] [--out DIR] [--json FILE]
Fleet: through perf-budgets.py: scripts/measure/split-spring.sh --suite=budgets --only=terminal_burst
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def stat(values):
    """{n, missed, p50, p95, max} of a list where None is a run that never showed its result."""
    return {"n": len(values), "missed": sum(v is None for v in values),
            "p50": pct(values, .5), "p95": pct(values, .95), "max": pct(values, 1)}


def thirds(values):
    """The first and the last third of a burst (at least one value each)."""
    size = max(1, len(values) // 3)
    return values[:size], values[-size:]


def growth(values):
    """The last third's p50 over the first third's: how much slower the Nth terminal opens than the first."""
    first, last = thirds(values)
    a, b = pct(first, .5), pct(last, .5)
    return round(b / a, 3) if a and b is not None else None


def summarize(steps):
    """The report's `summary` from {step: [result rows]}: one stat per step and metric, and the burst's thirds."""
    out = {}
    for step, rows in steps.items():
        entry = {"visible_ms": stat([r.get("visible_ms") for r in rows]), "key_ms": stat([r.get("key_ms") for r in rows]),
                 "errors": sorted({str(r["error"]) for r in rows if r.get("error")})}
        if step == "new_terminal":
            visible = [r.get("visible_ms") for r in rows]
            first, last = thirds(visible)
            entry.update({"first": stat(first), "last": stat(last), "growth": growth(visible)})
        out[step] = entry
    return out


# ---------- the app ----------

class Churn:
    def __init__(self, app, window):
        # debug.key takes the window's id; debug.new_tab takes an index into the main windows (0: the bench's only one).
        self.app, self.window = app, window

    def rpc(self, method, params=None, timeout=30):
        reply = self.app.rpc(method, params, timeout=timeout)
        return reply if isinstance(reply, dict) else {"error": f"no reply: {reply!r}"}

    def focused_pane(self):
        for window in self.rpc("debug.focus").get("windows") or []:
            for pane in window.get("topology") or []:
                if pane.get("pane") == window.get("layout_focused_pane"):
                    return pane
            panes = window.get("topology") or []
            if len(panes) == 1:
                return panes[0]
        return None

    def wait(self, check, seconds, step=0.25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:  # bench harness: a bounded poll of the app's socket
            try:
                value = check()
            except Exception:  # noqa: BLE001  the app may be mid-change
                value = None
            if value:
                return value
            time.sleep(step)  # bench harness: the poll interval
        return None

    def focused_kind(self):
        for window in self.rpc("debug.surfaces").get("windows") or []:
            for pane in window.get("panes") or []:
                if pane.get("focused"):
                    return pane.get("kind")
        return None

    def terminal_workspace(self):
        if self.focused_kind() == "terminal":
            return True
        self.rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "tab-churn"}, "wait": True})
        ok = self.wait(lambda: self.focused_kind() == "terminal", 30)
        time.sleep(1)  # bench harness: the shell prompt
        return ok

    def timed(self, step, action, index, **params):
        result = self.rpc("debug.new_tab", {"action": action, "window": 0, **params}, timeout=20)
        result.update({"step": step, "run": index})
        print(f"{step} #{index}: key={result.get('key_ms')} visible={result.get('visible_ms')} err={result.get('error')}",
              flush=True)
        return result

    def open_close(self, step, cycles):
        opens, closes = [], []
        for index in range(cycles):
            opens.append(self.timed(f"{step}/open", "bench_open", index))
            time.sleep(0.3)  # bench harness: the New Tab page settles before its close
            closes.append(self.timed(f"{step}/close", "bench_close", index))
            time.sleep(0.3)  # bench harness: the close lands before the next open
        return opens, closes

    def burst(self, count):
        rows = []
        for index in range(count):
            rows.append(self.timed("new_terminal", "bench_create", index, command="new_terminal"))
            time.sleep(0.4)  # bench harness: the new terminal's shell starts before the next press
        return rows

    def close_terminals(self, count):
        rows = []
        for index in range(count):
            pane = self.focused_pane() or {}
            before, tabs = pane.get("selected"), pane.get("tab_count")
            start = time.monotonic()
            self.rpc("debug.key", {"key": "w", "modifiers": ["command"], "window": self.window})
            moved = self.wait(lambda: (lambda p: p.get("selected") != before and (p.get("tab_count") or 0) < (tabs or 0))(
                self.focused_pane() or {}), 3, step=0.002)
            ms = round((time.monotonic() - start) * 1000, 2) if moved else None
            rows.append({"step": "close_terminal", "run": index, "visible_ms": ms,
                         **({} if moved else {"error": f"tab {before} still selected after 3 s"})})
            print(f"close_terminal #{index}: state={ms}", flush=True)
            if not moved:
                break  # a close that never lands (a dialog, a hang): the rest would measure nothing
            time.sleep(0.2)  # bench harness: the close's teardown before the next key
        return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tag", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--cycles", type=int, default=12, help="Cmd-T then Cmd-W cycles at each tab count")
    ap.add_argument("--terminals", type=int, default=30, help="Ctrl-` presses in the burst")
    ap.add_argument("--out", default="/tmp")
    ap.add_argument("--json")
    opts = ap.parse_args(argv)
    sys.path.insert(0, HERE)
    from bench_launch import BenchApp  # noqa: E402  macOS-only at launch; the helpers above run anywhere

    os.makedirs(opts.out, exist_ok=True)
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1200, 900), screen=None)
    try:
        app.launch(timeout=120)
        window = ((app.rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")
        churn = Churn(app, window)
        if not churn.terminal_workspace():
            sys.exit("tab-churn: no focused terminal")
        steps = {}
        steps["open@1"], steps["close@1"] = churn.open_close("open_close@1", opts.cycles)
        steps["new_terminal"] = churn.burst(opts.terminals)
        many = 1 + opts.terminals
        steps[f"open@{many}"], steps[f"close@{many}"] = churn.open_close(f"open_close@{many}", opts.cycles)
        steps["close_terminal"] = churn.close_terminals(opts.terminals)
    finally:
        app.stop()
    result = {"tag": opts.tag, "host": os.uname().nodename, "cycles": opts.cycles, "terminals": opts.terminals,
              "many": many, "summary": summarize(steps), "runs": steps}
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    burst = result["summary"]["new_terminal"]
    print(f"HEADLINE tab-churn new_terminal first p50 {burst['first']['p50']} ms, last p50 {burst['last']['p50']} ms, "
          f"growth {burst['growth']}", flush=True)
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(result, handle, indent=1)
    return 0 if all(not s["visible_ms"]["missed"] for s in result["summary"].values()) else 1


if __name__ == "__main__":
    sys.exit(main())
