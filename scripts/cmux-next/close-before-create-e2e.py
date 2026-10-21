#!/usr/bin/env python3
"""Close before create: a person closes a tab or pane the app is still creating.

Lawrence 2026-10-18: "Also need to be able to close that tab at any point in time, even
before the terminal was created". Each scenario sends a creation key and its close through
`debug.key` (the app's key path, so both are a person's) with no wait in between, 20 times:

  new-tab-page  Cmd-T (the New Tab page, a provisional conversation tab), then Cmd-W
  new-terminal  Ctrl-` (New Terminal Tab, no provisional tab: keys wait for it), then Cmd-W
  split-right   Cmd-D (optimistic split, a provisional pane), then Cmd-W
  split-down    Cmd-Shift-D, then Cmd-W
  split-close-pane  Cmd-D, then Close Pane (`action.run closePane`) on the focused pane

After each run it samples `debug.pane_chrome` for 2 s and records: the window's pane and tab
counts (back to before?), whether any read after the close showed more than before (a tab or
pane that reappeared), the daemon's terminal count (`cmux terminal list`), whether focus is on
a live tab (`debug.focus`), and any close toast. A run that leaves something behind is cleaned
up (its extra tabs and panes closed) so the next starts from the same state.

Attaches to a running tagged app (never launches or quits it); writes runs.json and
verdict.json to --out. Exit 0 when every run of every scenario is clean.
Usage: close-before-create-e2e.py --socket "$NX_APP_SOCKET" --out DIR [--runs 20] [--only NAME]
"""
import argparse, json, os, socket, subprocess, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--runs", type=int, default=20)
parser.add_argument("--sample", type=float, default=2.0)
parser.add_argument("--only", action="append")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
CLI, TAG = os.environ.get("NX_APP_CLI"), os.environ.get("NX_APP_TAG")


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def chrome():
    """[(pane, drawn tab slots)] of the first window, or None."""
    report = rpc("debug.pane_chrome") or {}
    windows = report.get("windows") or [] if isinstance(report, dict) else []
    if not windows:
        return None
    return [(p.get("pane"), len(p.get("tab_slots") or [])) for p in windows[0].get("panes") or []]


def focus():
    """(resolved pane, resolved tab, {pane: [tab ids]}) of the first window."""
    report = rpc("debug.focus") or {}
    windows = report.get("windows") or [] if isinstance(report, dict) else []
    if not windows:
        return None, None, {}
    window = windows[0]
    model = window.get("model") or {}
    topology = {p.get("pane"): [t.rsplit(":", 1)[0] for t in p.get("tabs") or []] for p in window.get("topology") or []}
    return model.get("resolved_pane"), model.get("resolved_tab"), topology


def terminals():
    """The daemon's terminal count (every workspace; the others do not change), or None."""
    if not CLI or not TAG:
        return None
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    try:
        out = subprocess.run([CLI, "--session", "cmux-app-%s" % TAG, "terminal", "list", "--json"], env=env,
                             capture_output=True, text=True, timeout=30).stdout
        reply = json.loads(out)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    rows = reply.get("value", reply) if isinstance(reply, dict) else reply
    if isinstance(rows, dict):
        rows = rows.get("terminals") or []
    return len(rows) if isinstance(rows, list) else None


def toasts():
    return [t for w in (rpc("debug.toast") or {}).get("windows", []) for t in w.get("toasts", []) if t.get("id") == "tab-closed"]


def key(name, *modifiers):
    return rpc("debug.key", {"key": name, "modifiers": list(modifiers)})


def wait(check, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def totals(read):
    return (len(read), sum(count for _, count in read)) if read else (None, None)


def cleanup(base_panes, base_tabs):
    """Closes what a run left behind (extra panes, extra tabs), so the next run starts clean."""
    _, _, topology = focus()
    for pane, tabs in topology.items():
        if pane not in base_panes:
            rpc("action.run", {"action": "closePane", "target": "pane:%s" % pane, "wait": True})
            continue
        for tab in tabs:
            if tab not in base_tabs:
                rpc("action.run", {"action": "closeTab", "target": "tab:%s" % tab, "wait": True})
    time.sleep(1.0)  # test harness: the closes settle


def close_pane():
    return rpc("action.run", {"action": "closePane"})


SCENARIOS = [
    ("new-tab-page", lambda: key("t", "cmd"), lambda: key("w", "cmd")),
    ("new-terminal", lambda: key("`", "ctrl"), lambda: key("w", "cmd")),
    ("split-right", lambda: key("d", "cmd"), lambda: key("w", "cmd")),
    ("split-down", lambda: key("d", "cmd", "shift"), lambda: key("w", "cmd")),
    ("split-close-pane", lambda: key("d", "cmd"), close_pane),
]

if not wait(chrome, 90):
    sys.exit("no window answered debug.pane_chrome")
rpc("action.run", {"action": "workspace.newAtBottom"})
wait(lambda: (p := chrome()) and len(p) == 1 and p, 15)
time.sleep(3.0)  # test harness: the new workspace's terminal starts and takes focus
runs, summary = [], {}
for name, create, close in SCENARIOS:
    if opts.only and name not in opts.only:
        continue
    clean, growth, wrong = 0, 0, 0
    for index in range(opts.runs):
        before = chrome()
        _, _, topology = focus()
        base_panes, base_tabs = set(topology), {t for tabs in topology.values() for t in tabs}
        panes0, tabs0 = totals(before)
        terminals0, toasts0 = terminals(), len(toasts())
        samples, stop = [], threading.Event()

        def probe():
            while not stop.is_set():
                read = chrome()
                if read is not None:
                    samples.append((time.time(), totals(read)))

        poller = threading.Thread(target=probe)
        poller.start()
        t0 = time.time()
        created = create()
        closed = close()
        t1 = time.time()
        time.sleep(opts.sample)  # test harness: watch the window for a reappearing tab
        stop.set()
        poller.join()
        after = chrome()
        panes1, tabs1 = totals(after)
        resolved_pane, resolved_tab, topology = focus()
        # A read after the window first came back to its count that shows more again: something reappeared.
        back = next((i for i, (t, c) in enumerate(samples) if t >= t1 and c == (panes0, tabs0)), None)
        reappeared = [round((t - t1) * 1000) for t, c in samples[back:] if c[0] > panes0 or c[1] > tabs0] if back is not None else []
        peak = max((c for t, c in samples if t >= t0), default=(None, None))
        time.sleep(0.5)  # test harness: a terminal the close ended leaves the daemon's list
        terminals1 = terminals()
        record = {
            "scenario": name, "run": index, "keys_ms": round((t1 - t0) * 1000, 1),
            "create": created, "close": closed,
            "before": [panes0, tabs0], "after": [panes1, tabs1], "peak": list(peak),
            "reappeared_ms_after_close": reappeared,
            "never_back_to_before": back is None,
            "terminals": [terminals0, terminals1],
            "focus": [resolved_pane, resolved_tab],
            "focus_live": resolved_pane in topology and resolved_tab in topology.get(resolved_pane, []),
            "close_toasts": len(toasts()) - toasts0,
            # The tabs that were there before the creation are all still there (the close took the new one).
            "kept_tabs_before": base_tabs <= {t for tabs in topology.values() for t in tabs},
            "back_ms_after_close": round((samples[back][0] - t1) * 1000, 1) if back is not None else None,
        }
        # Terminals are reported, not judged here: a close after the creation landed (New Terminal
        # Tab's held Cmd-W) detaches its terminal for Reopen Closed, and the daemon reaps it later.
        record["terminal_growth"] = (terminals1 - terminals0) if terminals0 is not None and terminals1 is not None else None
        record["clean"] = (panes1, tabs1) == (panes0, tabs0) and not reappeared and record["focus_live"] and record["kept_tabs_before"]
        clean += record["clean"]
        growth += record["terminal_growth"] or 0
        wrong += not record["kept_tabs_before"]
        runs.append(record)
        print(json.dumps(record)[:600], flush=True)
        if (panes1, tabs1) != (panes0, tabs0):
            cleanup(base_panes, base_tabs)
    summary[name] = {"runs": opts.runs, "clean": clean, "terminal_growth": growth, "closed_an_older_tab": wrong,
                     "reappeared_runs": sum(1 for r in runs if r["scenario"] == name and r["reappeared_ms_after_close"])}
    print("scenario %s: %d/%d clean, %d closed an older tab, terminals +%d" % (name, clean, opts.runs, wrong, growth), flush=True)

with open(os.path.join(opts.out, "runs.json"), "w") as handle:
    json.dump(runs, handle, indent=1)
verdict = {"scenarios": summary, "all_clean": all(s["clean"] == s["runs"] for s in summary.values())}
with open(os.path.join(opts.out, "verdict.json"), "w") as handle:
    json.dump(verdict, handle, indent=1)
print("verdict:", json.dumps(verdict), flush=True)
sys.exit(0 if verdict["all_clean"] else 1)
