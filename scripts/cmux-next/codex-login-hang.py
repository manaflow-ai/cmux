#!/usr/bin/env python3
"""First-time Codex (ChatGPT) sign-in of a published cmux NEXT nightly, watched for main-thread hangs (measurement only).

Launches the DMG's app from a fresh home through scripts/ci/fresh_home_launch_smoke.py (no CODEX_HOME, an empty
~/.codex: a first-time sign-in), and once Home has rendered:

  1. opens Settings > Accounts (`settings.open`), or with --flow onboarding stays on what a fresh launch shows;
  2. presses "Add Account" under "ChatGPT and Codex" through the accessibility API (ax-press.swift);
  3. waits for the sign-in page (a tab on auth.openai.com in snapshot.get), then presses the card's Cancel.
     Nothing is ever typed into the page: no account is signed in.

A pinger sends snapshot.get every 50 ms the whole time (main-actor socket work); whenever one has been out
for HANG_S, it runs `/usr/bin/sample PID 5` (one at a time, at most --samples). Writes report.json, the samples,
AX dumps and the app's hang files to --out.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

HANG_S = 0.25


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


class Journey:
    def __init__(self, opts):
        self.opts = opts
        self.samples = []
        self.sampling = threading.Lock()
        self.pings = []  # (at_s, ms)
        self.stop = threading.Event()
        self.events = []

    def mark(self, what, **extra):
        at = round(time.monotonic() - self.t0, 3)
        self.events.append({"at_s": at, "what": what, **extra})
        print(f"STEP {at:8.3f}s {what} {json.dumps(extra) if extra else ''}", flush=True)

    def ax(self, *args, timeout=30):
        try:
            done = subprocess.run([self.opts.ax, str(self.pid), *args], capture_output=True, text=True, timeout=timeout)
            return done.returncode, (done.stdout + done.stderr).strip()
        except (OSError, subprocess.SubprocessError) as error:
            return 99, str(error)

    def dump(self, name):
        code, text = self.ax("dump", timeout=60)
        (self.out / f"ax-{name}.txt").write_text(text)
        return text

    def sample(self, why):
        if not self.sampling.acquire(blocking=False):
            return
        try:
            if len(self.samples) >= self.opts.samples:
                return
            index = len(self.samples)
            entry = {"why": why, "at_s": round(time.monotonic() - self.t0, 3)}
            self.samples.append(entry)
            path = self.out / f"sample-{index:02d}.txt"
            for how, cmd in (("sample", ["/usr/bin/sample", str(self.pid), "5", "1", "-mayDie", "-file", str(path)]),
                             ("sudo sample", ["sudo", "-n", "/usr/bin/sample", str(self.pid), "5", "1", "-mayDie", "-file", str(path)])):
                try:
                    done = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                except (OSError, subprocess.SubprocessError) as error:
                    entry.setdefault("errors", []).append(f"{how}: {error}")
                    continue
                if done.returncode == 0 and path.exists():
                    entry.update(file=path.name, how=how)
                    print(f"SAMPLE {index} ({why}) -> {path.name}", flush=True)
                    return
                entry.setdefault("errors", []).append(f"{how}: exit {done.returncode} {(done.stderr or done.stdout).strip()[-300:]}")
        finally:
            self.sampling.release()

    def pinger(self):
        while not self.stop.is_set():
            started = time.monotonic()
            done = threading.Event()

            def watch(started=started, done=done):
                if not done.wait(HANG_S):
                    self.sample(f"snapshot.get out {HANG_S * 1000:.0f} ms at {started - self.t0:.2f}s")
            threading.Thread(target=watch, daemon=True).start()
            rpc(self.sock, "snapshot.get", timeout=60)
            done.set()
            ms = (time.monotonic() - started) * 1000
            self.pings.append((round(started - self.t0, 3), round(ms, 1)))
            if ms > HANG_S * 1000:
                print(f"PING slow {ms:.0f} ms at {started - self.t0:.2f}s", flush=True)
            self.stop.wait(0.05)

    def snapshot_text(self):
        return json.dumps(rpc(self.sock, "snapshot.get", timeout=30))

    def wait_for(self, what, test, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if test():
                self.mark(what)
                return True
            time.sleep(0.1)  # harness polling the live app
        self.mark(what + " TIMEOUT")
        return False

    def __call__(self, process, socket_path, env, app, out, report):
        self.sock, self.pid, self.out = socket_path, process.pid, Path(out)
        self.t0 = time.monotonic()
        self.home = Path(env["HOME"])
        report["codex_home"] = str(self.home / ".codex")
        report["env_path"] = env.get("PATH")
        threading.Thread(target=self.pinger, daemon=True).start()
        try:
            self.mark("rendered", trusted=self.ax("trusted")[1])
            self.dump("start")
            if self.opts.flow == "settings":
                started = time.monotonic()
                reply = rpc(self.sock, "settings.open", {"section": "accounts"})
                if isinstance(reply, dict) and reply.get("error"):
                    self.mark("settings.open accounts refused", error=str(reply["error"]))
                    reply = rpc(self.sock, "settings.open", {})
                self.mark("settings.open replied", ms=round((time.monotonic() - started) * 1000, 1), reply=str(reply)[:200])
                anchor, label = "ChatGPT and Codex", "Add Account"
            else:
                anchor, label = "ChatGPT", "Sign in"
            pressed = self.wait_for("sign-in button found",
                                    lambda: self.ax("has", label)[0] == 0, 40)
            self.dump("before-press")
            if not pressed:
                return ["no sign-in button in the AX tree"]
            code, text = self.ax("press", anchor, label)
            self.mark("pressed", code=code, out=text)
            if code != 0:
                return [f"press failed: {text}"]
            self.wait_for("card shows Cancel", lambda: self.ax("has", "Cancel")[0] == 0, 60)
            opened = self.wait_for("sign-in page tab (auth.openai.com) in snapshot",
                                   lambda: "auth.openai.com" in self.snapshot_text() or "openai.com" in self.snapshot_text(), 60)
            self.dump("after-open")
            report["page_opened"] = opened
            time.sleep(3)  # sleep-ok: watch the app settle with the page up before cancelling
            code, text = self.ax("press", anchor if self.opts.flow == "settings" else "", "Cancel")
            self.mark("cancel pressed", code=code, out=text)
            time.sleep(4)  # sleep-ok: watch the cancel's aftermath for hangs
            self.dump("end")
        finally:
            self.stop.set()
            time.sleep(0.5)
            with self.sampling:
                pass
            report["events"] = self.events
            report["samples"] = self.samples
            report["pings_over_250ms"] = [p for p in self.pings if p[1] > 250]
            report["ping_max_ms"] = max((p[1] for p in self.pings), default=None)
            report["pings"] = len(self.pings)
            hangs = self.out / "hangs"
            hangs.mkdir(exist_ok=True)
            for pattern in (str(self.home / "Library/Logs/com.cmuxterm.app*/hangs/*"),
                            str(self.home / "Library/Logs/com.cmuxterm*/**/hang-*.txt")):
                for path in glob.glob(pattern, recursive=True):
                    shutil.copy(path, hangs / Path(path).name)
            report["hang_files"] = sorted(p.name for p in hangs.iterdir())
            print("SUMMARY " + json.dumps({k: report[k] for k in ("ping_max_ms", "pings", "pings_over_250ms", "hang_files")}
                                          | {"samples": len(self.samples)}), flush=True)
        return []


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--ax", required=True, help="the built ax-press binary")
    parser.add_argument("--flow", choices=("settings", "onboarding"), default="settings")
    parser.add_argument("--extra-path", default="", help="prepended to the app's PATH (where codex is)")
    parser.add_argument("--samples", type=int, default=6)
    opts = parser.parse_args()
    if opts.extra_path:
        original = smoke.fresh_env

        def fresh_env(*args, **kwargs):
            env = original(*args, **kwargs)
            env["PATH"] = opts.extra_path + ":" + env["PATH"]
            return env
        smoke.fresh_env = fresh_env
    smoke.AFTER_RENDER = Journey(opts)
    os.makedirs(opts.out, exist_ok=True)
    return smoke.main(["--dmg", opts.dmg, "--out", opts.out, "--seconds", "5", "--startup-timeout", "120"])


if __name__ == "__main__":
    sys.exit(main())
