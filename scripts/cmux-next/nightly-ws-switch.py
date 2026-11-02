#!/usr/bin/env python3
"""Workspace-switch and typing latency of a published cmux NEXT nightly DMG (measurement only).

Launches the DMG's app from a fresh home through scripts/ci/fresh_home_launch_smoke.py (its
private root, release control socket, defaults set aside), and once Home has rendered:

  1. makes WORKSPACES terminal workspaces (workspace.newAtBottom); half run a printing loop,
     one runs `yes | head`, the rest sit at a prompt;
  2. switches between them ROUNDS times with goToWorkspace, then workspace.selectFirst /
     workspace.selectLast / nextSidebarTab, timing each: the action.run reply, and the moment
     snapshot.get shows the target workspace in a visible window (a switch that never shows it
     in 10 s is failed);
  3. types into a prompt terminal (terminal.sendText `: > ROOT/mark-N`) and times until the shell
     ran it (the file exists), with the printing workspaces alive in the background.

A watchdog pings snapshot.get every 250 ms the whole time. Whenever a switch, a typed line or a
ping takes more than 1 s, it runs `/usr/bin/sample PID 3` on the app (then `sudo -n sample`) and
keeps the output (at most SAMPLES per build). Writes report.json and samples to --out.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

SLOW_S = 1.0


def rpc(sock_path, method, params=None, timeout=30.0):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(str(sock_path))
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0])
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))], 1)


class Journey:
    def __init__(self, opts):
        self.opts = opts
        self.samples = []
        self.sample_lock = threading.Lock()
        self.pings = []
        self.stop = threading.Event()
        self.watchers = []

    # -- the app -----------------------------------------------------------------------------
    def action(self, name, args=None, timeout=60.0):
        return rpc(self.sock, "action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"},
                   timeout=timeout)

    def topology(self):
        snap = rpc(self.sock, "snapshot.get", timeout=15)
        return (snap.get("topology") or {}) if isinstance(snap, dict) else {}

    def shown(self):
        topo = self.topology()
        visible = [w.get("workspace") for w in topo.get("windows") or [] if isinstance(w, dict) and w.get("visible")]
        return (topo.get("focus") or {}).get("workspace"), visible

    def wait_shown(self, target, seconds=10.0):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            focus, visible = self.shown()
            if focus == target and target in visible:
                return True
            time.sleep(0.02)  # measurement harness polling the live app
        return False

    # -- sampling ----------------------------------------------------------------------------
    def sample(self, why):
        with self.sample_lock:
            if len(self.samples) >= self.opts.samples:
                return
            index = len(self.samples)
            entry = {"why": why, "at_s": round(time.monotonic() - self.t0, 2), "file": None, "how": None}
            self.samples.append(entry)
        path = self.out / f"sample-{index:02d}.txt"
        for how, cmd in (("sample", ["/usr/bin/sample", str(self.pid), "3", "-mayDie", "-file", str(path)]),
                         ("sudo sample", ["sudo", "-n", "/usr/bin/sample", str(self.pid), "3", "-mayDie", "-file", str(path)])):
            try:
                done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            except (OSError, subprocess.SubprocessError) as error:
                entry.setdefault("errors", []).append(f"{how}: {error}")
                continue
            if done.returncode == 0 and path.exists() and "Call graph" in path.read_text(errors="replace"):
                entry.update(file=path.name, how=how)
                return
            entry.setdefault("errors", []).append(f"{how}: exit {done.returncode} {(done.stderr or done.stdout).strip()[-300:]}")

    def watch_slow(self, label, done_event):
        """Samples the app when the operation behind DONE_EVENT has not finished within SLOW_S."""
        def run():
            if not done_event.wait(SLOW_S):
                self.sample(label)
        thread = threading.Thread(target=run, daemon=True)
        self.watchers.append(thread)
        thread.start()

    def pinger(self):
        while not self.stop.is_set():
            started = time.monotonic()
            done = threading.Event()
            self.watch_slow(f"ping at {started - self.t0:.1f}s", done)
            rpc(self.sock, "snapshot.get", timeout=30)
            done.set()
            self.pings.append(round((time.monotonic() - started) * 1000, 1))
            self.stop.wait(0.25)

    # -- the journey -------------------------------------------------------------------------
    def timed_switch(self, label, run_action, target):
        done = threading.Event()
        self.watch_slow(label, done)
        started = time.monotonic()
        reply = run_action()
        reply_ms = (time.monotonic() - started) * 1000
        ok = self.wait_shown(target) if target else True
        shown_ms = (time.monotonic() - started) * 1000
        done.set()
        error = reply.get("error") if isinstance(reply, dict) else None
        row = {"label": label, "target": target, "reply_ms": round(reply_ms, 1), "shown_ms": round(shown_ms, 1),
               "shown": ok, "error": str(error) if error else None}
        print(f"SWITCH {label}: reply {reply_ms:.0f} ms, shown {shown_ms:.0f} ms{'' if ok else ' FAILED'}"
              f"{' error ' + str(error) if error else ''}", flush=True)
        return row

    def new_workspace(self, ids):
        before = self.shown()[0]
        reply = self.action("workspace.newAtBottom")
        deadline = time.monotonic() + 15
        current = before
        while time.monotonic() < deadline:
            current = self.shown()[0]
            if current and current != before and current not in ids:
                break
            time.sleep(0.05)  # harness: the new workspace takes focus
        if not current or current == before or current in ids:
            print(f"SETUP workspace not created: {reply}", flush=True)
            return None
        time.sleep(1.0)  # harness: let the shell start before typing into it
        return current

    def make_workspaces(self):
        """WORKSPACES switch targets (role print, yes or idle; with --heavy each also gets a split running
        output, a second split, a second terminal tab and a browser tab), then one idle workspace to type in."""
        ids, roles = [], {}
        loop = "while :; do date; ls -la /usr/bin | tail -n 20; sleep 0.05; done\r"
        for index in range(self.opts.workspaces):
            current = self.new_workspace(ids)
            if not current:
                continue
            ids.append(current)
            role = "print" if index % 2 == 0 else ("yes" if index == 1 else "idle")
            roles[current] = role
            self.action("terminal.sendText", {"text": {"print": loop, "yes": "yes | head -n 300000\r",
                                                         "idle": "echo ready\r"}[role]})
            if self.opts.heavy:
                for verb, text in (("splitRight", loop), ("splitDown", "echo ready\r")):
                    self.action(verb)
                    time.sleep(0.6)  # harness: the split's shell starts
                    self.action("terminal.sendText", {"text": text})
                self.action("newSurface")
                time.sleep(0.4)  # harness: the tab opens
                self.action("openBrowser", {"url": "https://example.com"})
                time.sleep(0.4)  # harness: the browser tab opens
        typing = self.new_workspace(ids)
        if typing:
            self.action("terminal.sendText", {"text": "echo ready\r"})
            roles[typing] = "typing"
        return ids, roles, typing

    def typing(self, root, rounds):
        rows = []
        for index in range(rounds):
            mark = root / f"mark-{index}"
            done = threading.Event()
            self.watch_slow(f"type {index}", done)
            started = time.monotonic()
            reply = self.action("terminal.sendText", {"text": f": > {mark}\r"})
            reply_ms = (time.monotonic() - started) * 1000
            deadline = started + 10
            while time.monotonic() < deadline and not mark.exists():
                time.sleep(0.002)  # harness: wait for the shell to run the line
            done.set()
            ran_ms = (time.monotonic() - started) * 1000
            ok = mark.exists()
            rows.append({"reply_ms": round(reply_ms, 1), "ran_ms": round(ran_ms, 1), "ok": ok,
                         "error": str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None})
            print(f"TYPE {index}: reply {reply_ms:.0f} ms, ran {ran_ms:.0f} ms{'' if ok else ' FAILED'}", flush=True)
            time.sleep(0.2)
        return rows

    def __call__(self, process, socket_path, env, app, out, report):
        self.sock, self.pid, self.out = socket_path, process.pid, Path(out)
        self.t0 = time.monotonic()
        root = Path(env["HOME"]).parent
        Path(env["HOME"], ".zshrc").touch()
        pinger = threading.Thread(target=self.pinger, daemon=True)
        pinger.start()
        failures = []
        try:
            ids, roles, prompt = self.make_workspaces()
            report["workspaces"], report["roles"] = ids, roles
            print(f"SETUP {len(ids)} workspaces: {ids}", flush=True)
            time.sleep(2.0)  # harness: the printing loops run before the switches
            switches, failed_in_row = [], 0
            if len(ids) >= 2:
                # Every workspace in turn.
                current = 0
                for i in range(self.opts.rounds):
                    current = (current + 1) % len(ids)
                    if self.shown()[0] == ids[current]:
                        current = (current + 1) % len(ids)
                    target = ids[current]
                    row = self.timed_switch(f"goTo {i}", lambda t=target: self.action("goToWorkspace", {"workspace": t}), target)
                    switches.append(row)
                    failed_in_row = 0 if row["shown"] else failed_in_row + 1
                    if failed_in_row >= 4:
                        print("SWITCH 4 switches in a row failed: the app is stuck, stopping the switches", flush=True)
                        break
                    time.sleep(0.15)
                for i in range(5 if failed_in_row < 4 else 0):
                    switches.append(self.timed_switch(f"selectFirst {i}", lambda: self.action("workspace.selectFirst"), None))
                    time.sleep(0.15)
                    switches.append(self.timed_switch(f"selectLast {i}", lambda: self.action("workspace.selectLast"), prompt or ids[-1]))
                    time.sleep(0.15)
                for i in range(5 if failed_in_row < 4 else 0):
                    switches.append(self.timed_switch(f"nextSidebarTab {i}", lambda: self.action("nextSidebarTab"), None))
                    time.sleep(0.15)
            report["switches"] = switches
            # Type into the idle workspace made for it.
            if failed_in_row >= 4:
                prompt = None  # the app is stuck: typing would only wait out its timeouts
            if prompt:
                self.action("goToWorkspace", {"workspace": prompt})
                self.wait_shown(prompt)
                time.sleep(0.5)
            report["typing"] = self.typing(root, self.opts.typing) if prompt else []
        finally:
            self.stop.set()
            pinger.join(timeout=35)
            for thread in list(self.watchers):
                thread.join(timeout=70)  # a running sample finishes and records its file
        report["pings_ms"] = self.pings
        report["samples"] = self.samples
        report["summary"] = summarize(report)
        print("SUMMARY " + json.dumps(report["summary"]), flush=True)
        return failures


def summarize(report):
    switches = report.get("switches") or []
    go = [s for s in switches if s["label"].startswith("goTo")]
    typing = report.get("typing") or []
    pings = report.get("pings_ms") or []
    return {
        "workspaces": len(report.get("workspaces") or []),
        "goto_shown_ms_p50": pct([s["shown_ms"] for s in go if s["shown"]], 50),
        "goto_shown_ms_p95": pct([s["shown_ms"] for s in go if s["shown"]], 95),
        "goto_shown_ms_max": max((s["shown_ms"] for s in go), default=None),
        "goto_reply_ms_p50": pct([s["reply_ms"] for s in go], 50),
        "goto_reply_ms_max": max((s["reply_ms"] for s in go), default=None),
        "all_switch_reply_ms_max": max((s["reply_ms"] for s in switches), default=None),
        "failed_switches": sum(1 for s in switches if not s["shown"] or s["error"]),
        "switches": len(switches),
        "type_ran_ms_p50": pct([t["ran_ms"] for t in typing if t["ok"]], 50),
        "type_ran_ms_max": max((t["ran_ms"] for t in typing), default=None),
        "type_failed": sum(1 for t in typing if not t["ok"]),
        "ping_ms_p50": pct(pings, 50),
        "ping_ms_p99": pct(pings, 99),
        "ping_ms_max": max(pings, default=None),
        "pings_over_1s": sum(1 for p in pings if p > 1000),
        "samples": len(report.get("samples") or []),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--workspaces", type=int, default=6)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--typing", type=int, default=10)
    parser.add_argument("--samples", type=int, default=6)
    parser.add_argument("--heavy", action="store_true", help="each workspace also gets two splits, a second tab and a browser tab")
    opts = parser.parse_args()
    smoke.AFTER_RENDER = Journey(opts)
    os.makedirs(opts.out, exist_ok=True)
    return smoke.main(["--dmg", opts.dmg, "--out", opts.out, "--seconds", "5", "--startup-timeout", "120"])


if __name__ == "__main__":
    sys.exit(main())
