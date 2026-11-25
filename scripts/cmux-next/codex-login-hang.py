#!/usr/bin/env python3
"""First-time Codex (ChatGPT) sign-in of a published cmux NEXT nightly, watched for main-thread hangs (measurement only).

Launches the DMG's app from a fresh home through scripts/ci/fresh_home_launch_smoke.py (no CODEX_HOME, an empty
~/.codex: a first-time sign-in), and once Home has rendered:

  1. opens Settings > Accounts (`settings.open`), or with --flow onboarding stays on what a fresh launch shows;
  2. presses "Add Account" under "ChatGPT and Codex" through the accessibility API (ax-press.swift; cua-driver
     when this process has no Accessibility grant, as on a display worker);
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
import pwd
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

HANG_S = 0.25
def account_home():
    """The account's real HOME: a fleet step runs with HOME=<job>/home, where neither cua-driver nor its socket is."""
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        return os.path.expanduser("~")


def driver_env():
    """cua-driver's environment (tab_switch_capture.driver_env): `cua-driver mcp` without its own grant proxies to the
    daemon at $HOME/Library/Caches/cua-driver/cua-driver.sock, which under the step's HOME does not exist, so it
    waits 10 s and exits ("cua-driver mcp ended" in both flows of step f33bfd82a230aaa2bfd62b7c)."""
    env = dict(os.environ)
    env["HOME"] = account_home()
    env.pop("CFFIXED_USER_HOME", None)
    return env


ONBOARDING_STEPS = 8  # welcome steps a fresh launch shows before the agents step, at most
CUA_CANDIDATES = (os.path.join(account_home(), ".local/bin/cua-driver"),
                  "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
CUA = next((p for p in CUA_CANDIDATES if os.access(p, os.X_OK)), None)


class CuaSession:
    """One `cua-driver mcp` stdio session (hover-instant-bench.py's route): `cua-driver call` looks for the daemon's
    socket under HOME, and a fleet step's HOME has none, so every call came back empty (step 14a2d1acaf891719bab01302)."""

    def __init__(self, path):
        # stderr to a file, not a pipe nobody reads: a session that ends must say why.
        self.stderr = tempfile.TemporaryFile()
        self.p = subprocess.Popen([path, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=self.stderr, text=True, env=driver_env())
        self.lines = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()
        self.n = 0
        try:
            self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "codex-login-hang", "version": "1"}})
            self.rpc("notifications/initialized", notify=True)
        except (OSError, RuntimeError) as error:
            said = self.said()
            self.close()
            raise RuntimeError(f"{error}: {said}") from None

    def said(self):
        """cua-driver's own last words on stderr."""
        try:
            self.stderr.seek(0)
            return self.stderr.read().decode("utf-8", "replace").strip()[-300:] or "(nothing on stderr)"
        except (OSError, ValueError):
            return "(stderr unreadable)"

    def read(self):
        for line in self.p.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def rpc(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        while True:  # bounded: 60 s per answer, and an ended driver closes stdout
            try:
                line = self.lines.get(timeout=60)
            except queue.Empty:
                raise RuntimeError(f"cua-driver mcp: no answer to {method} in 60 s") from None
            if not line:
                raise RuntimeError("cua-driver mcp ended")
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if reply.get("id") == self.n:
                return reply

    def call(self, tool, args):
        reply = self.rpc("tools/call", {"name": tool, "arguments": args})
        result = reply.get("result") or {}
        inner = result.get("structuredContent") if isinstance(result.get("structuredContent"), dict) else {}
        if reply.get("error") or not result or result.get("isError"):
            text = " ".join(c.get("text", "") for c in result.get("content") or [] if isinstance(c, dict))
            raise RuntimeError(f"cua-driver {tool}: {(reply.get('error') or text or result)!s}"[-300:])
        return inner or result

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.p.kill()  # the exact PID this script started
            self.p.wait()


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
        self.cua_ready = False
        self.cua_session = None

    def mark(self, what, **extra):
        at = round(time.monotonic() - self.t0, 3)
        self.events.append({"at_s": at, "what": what, **extra})
        print(f"STEP {at:8.3f}s {what} {json.dumps(extra) if extra else ''}", flush=True)

    def ax(self, *args, timeout=30):
        if self.cua_ready and args and args[0] in ("has", "press", "dump"):
            return self.cua_ax(*args)
        try:
            done = subprocess.run([self.opts.ax, str(self.pid), *args], capture_output=True, text=True, timeout=timeout)
            return done.returncode, (done.stdout + done.stderr).strip()
        except (OSError, subprocess.SubprocessError) as error:
            return 99, str(error)

    def cua(self, tool, args):
        """A cua-driver tool's answer through the session; {"error": why} when it failed (kept in the dumps)."""
        try:
            if self.cua_session is None:
                self.cua_session = CuaSession(CUA)
            return self.cua_session.call(tool, args)
        except (OSError, RuntimeError, ValueError) as error:
            return {"error": str(error)[-400:]}

    @staticmethod
    def find(obj, pred, out):
        if pred(obj):
            out.append(obj)
        if isinstance(obj, dict):
            for value in obj.values():
                Journey.find(value, pred, out)
        elif isinstance(obj, list):
            for value in obj:
                Journey.find(value, pred, out)
        return out

    def cua_elements(self):
        """The app's windows' accessibility elements in tree order (web content included), and any driver errors."""
        errors, found = [], []
        wins = self.cua("list_windows", {"pid": self.pid})
        if wins.get("error"):
            errors.append(wins["error"])
        rows = self.find(wins, lambda o: isinstance(o, dict) and "window_id" in o and o.get("pid", self.pid) == self.pid, [])
        rows.sort(key=lambda w: -((w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)))
        for win in rows[:3]:
            state = self.cua("get_window_state", {"pid": self.pid, "window_id": win["window_id"], "include_screenshot": False,
                                                  "max_depth": 80, "max_elements": 8000})
            if state.get("error"):
                errors.append(state["error"])
            found += [dict(e, _window=win["window_id"]) for e in
                      self.find(state, lambda o: isinstance(o, dict) and "role" in o
                                and ("frame" in o or "element_token" in o or "element_index" in o), [])]
        if not rows:
            errors.append("no window for pid in list_windows: " + json.dumps(wins)[:300])
        return errors, found

    @staticmethod
    def names(element, text):
        return any(str(element.get(key, "")).strip() == text for key in ("label", "title", "value", "description"))

    def cua_ax(self, verb, *rest):
        errors, elements = self.cua_elements()
        if verb == "dump":
            return 0, "\n".join([f"ERROR {e}" for e in errors] + [
                f"{e.get('role')} {e.get('label') or e.get('title') or e.get('value') or ''} {json.dumps(e.get('frame'))}"
                for e in elements])
        label = rest[-1]
        anchor = rest[0] if len(rest) > 1 else ""
        start = next((i for i, e in enumerate(elements) if anchor and anchor in str(e.get("label", "")) + str(e.get("value", ""))), 0)
        hits = [e for e in elements[start:] if self.names(e, label) and "button" in str(e.get("role", "")).lower()]
        if not hits:
            return 1, f"no {label!r} button (after {anchor!r}); {'; '.join(errors)[:300]}"
        if verb == "has":
            return 0, "found"
        hit = hits[0]
        if "element_token" in hit or "element_index" in hit:
            key = "element_token" if "element_token" in hit else "element_index"
            reply = self.cua("click", {"pid": self.pid, "window_id": hit["_window"], key: hit[key], "action": "press"})
        else:
            f = hit["frame"]
            w, h = f.get("w", f.get("width", 0)), f.get("h", f.get("height", 0))
            reply = self.cua("click", {"x": f["x"] + w / 2, "y": f["y"] + h / 2, "scope": "desktop"})
        return (2 if reply.get("error") else 0), json.dumps(reply)[:300]

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
            trusted = self.ax("trusted")[1]
            # Untrusted (a display worker's step): cua-driver presses instead, with its own grant.
            self.cua_ready = trusted != "trusted" and CUA is not None
            self.mark("rendered", trusted=trusted, via="cua-driver" if self.cua_ready else "ax-press")
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
                # The agents step's row button reads "Sign In" (onboarding.agents.signIn); a fresh launch opens on
                # the welcome steps, so walk Continue until the ChatGPT row's button is there.
                anchor, label = "ChatGPT", "Sign In"
                for step in range(ONBOARDING_STEPS):
                    if self.ax("has", label)[0] == 0:
                        break
                    code, text = self.ax("press", "", "Continue")
                    self.mark("onboarding continue", step=step + 1, code=code, out=text[:200])
                    time.sleep(1.5)  # sleep-ok: let the next onboarding step render before reading the tree
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
            if self.cua_session is not None:
                self.cua_session.close()
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
