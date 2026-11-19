#!/usr/bin/env python3
"""The 429 storm of scripts/cmux-next/acpmux_429_storm.py, on a published cmux NEXT app's own chat pane.

    acpmux-429-storm-gui.py --dmg DMG|--app APP --out DIR [--ocr OCR] [--agents 7] [--interval 15]
        [--storm 600] [--retry-after none|N] [--settle 900] [--quiet 240] [--shot-every 20] [--after 90]

Leo, 2026-11-19: "I hope we aren't getting the f---ing 429s anymore in our f---ing app ... the GUI ones kept
like getting busted". The Linux harness proves what acpmux does; this one reads what the app shows:

  1. The app launches from a fresh home (scripts/ci/fresh_home_launch_smoke.py: its own HOME, socket and
     defaults set aside), with the harness's fake Anthropic endpoint as Claude Code's ANTHROPIC_BASE_URL (the
     app's environment and the fresh home's ~/.claude/settings.json), Claude Code first on PATH, the first-run
     history page marked shown and the chat's folder trusted.
  2. `cmux agents chat new --harness claude --policy approve-all` (the app's own CLI) starts the coordinator
     chat in the GUI, and its workspace is selected. Its first turn starts into the storm: the endpoint answers
     429 for --storm seconds (Retry-After or none).
  3. --agents senders `acpmux send <chat> --from lane-K --no-wait --class question` (the app's bundled acpmux,
     on the app's own daemon) one report each every --interval seconds for the whole storm.
  4. Every --shot-every seconds the app's main window is shot (`screencapture -l`, by the app's window id),
     read with Vision (--ocr, scripts/e2e/ocr.swift) and `cmux agents chat state` is asked: the busy state the
     pane draws and the notice it shows.
  5. After the lift it waits as the harness does (every marker answered, or --quiet seconds with no model
     request), shoots --after seconds more, then reads the whole transcript (`cmux agents chat read`) and
     counts each marker: in the pane's transcript once, missing or more than once.

Output: OUT/result.json is the harness's tally (storm.tally: from the endpoint log and the daemon's journal)
plus `gui`: transcript counts, the busy state per shot, whether the chat was still busy after the lift
(and for how long), the rate-limit notice lines read on screen and when, OUT/shots/*.png and their text.
Prints `STORM-GUI {json}` and one `STORM-GUI row key=value ...` line. Exit 0 when the run measured (whatever
it found), 1 when the driver failed, 3 when it could not run (the launch smoke's could-not-run).
Python 3.9 (the minis' /usr/bin/python3).
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(ROOT / "scripts" / "cmux-next"))
import acpmux_429_storm as storm  # noqa: E402
import fresh_home_launch_smoke as smoke  # noqa: E402

FAKE_KEY = "sk-ant-api03-storm-harness-fake"
# What the pane says while the harness retries or after a refused turn (webviews/src/agent-session/acpmux:
# the live line "The model is busy · retrying (2 of 10) · 429", turn.failure.rateLimited, the error card).
NOTICE = re.compile(r"rate.?limit|model is busy|retrying|\b429\b|out of capacity|try again", re.I)
BUSY_STATES = ("running", "working", "busy", "thinking", "prompting", "waiting", "retrying", "queued", "starting")
FIRST_RUN_KEY = "home.firstRun.historyImportShown"


def log(*parts) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] storm-gui", *parts, flush=True)


def parsed(text: str):
    try:
        return json.loads(text)
    except ValueError:
        return None


def found(value, key: str):
    """The first KEY in a JSON answer, at any depth (the CLI may wrap its result)."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            hit = found(item, key)
            if hit is not None:
                return hit
    return None


def holds(value, text: str) -> bool:
    if isinstance(value, dict):
        return any(holds(v, text) for v in value.values())
    if isinstance(value, list):
        return any(holds(v, text) for v in value)
    return value == text


def rpc(sock_path, method, params=None, timeout=20.0):
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


def window_id(pid: int):
    """PID's largest on-screen layer-0 window (scripts/cmux-next/hot-verify.py window_id; no grant needed)."""
    script = ('ObjC.import("CoreGraphics");'
              'var list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo('
              '$.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0))) || [];'
              f'var mine = list.filter(function (w) {{ return w.kCGWindowOwnerPID === {int(pid)}'
              ' && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Width >= 100 && w.kCGWindowBounds.Height >= 60'
              ' && Math.abs(w.kCGWindowBounds.X) < 20000 && Math.abs(w.kCGWindowBounds.Y) < 20000; });'
              'mine.sort(function (a, b) { return b.kCGWindowBounds.Width * b.kCGWindowBounds.Height'
              ' - a.kCGWindowBounds.Width * a.kCGWindowBounds.Height; });'
              'mine.length ? String(mine[0].kCGWindowNumber) : ""')
    try:
        done = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True,
                              timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    text = done.stdout.strip()
    return int(text) if text.isdigit() else None


def busy(state) -> bool:
    status = str(found(state, "status") or found(state, "state") or "").lower()
    return any(word in status for word in BUSY_STATES)


class Run:
    def __init__(self, a):
        self.a = a
        self.out = Path(a.out)
        self.ocr = Path(a.ocr) if a.ocr else None
        self.failures: list[str] = []
        self.shots: list[dict] = []
        self.sent: list[dict] = []
        self.lock = threading.Lock()
        self.ep = None
        self.server = None
        self.procs: list[subprocess.Popen] = []

    # The fresh home (the smoke's PREPARE_HOME, inside its defaults set-aside).
    def prepare(self, env: dict) -> None:
        smoke.login_keychain(env)
        home = Path(env["HOME"])
        self.work = home / "work"
        self.work.mkdir(parents=True, exist_ok=True)
        retry = None if self.a.retry_after in (None, "none") else int(self.a.retry_after)
        self.ep = storm.Endpoint(self.out / "endpoint.ndjson", retry)  # storm_until is inf: 429 until lift_at
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), storm.make_handler(self.ep))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        base_url = f"http://127.0.0.1:{self.server.server_address[1]}"
        # The smoke's copy of the app under its private root (the outermost .app, not a helper inside it).
        apps = [p for p in Path(env["HOME"]).parent.glob("**/*.app") if (p / "Contents" / "Info.plist").is_file()]
        app = min(apps, key=lambda p: len(p.parts)) if apps else None
        app_bin = str(app / "Contents" / "Resources" / "bin") if app else ""
        claude_bin = shutil.which("claude") or ""
        path = [d for d in (os.path.dirname(claude_bin), app_bin) if d]
        env.update({
            "PATH": ":".join([*path, env.get("PATH") or "/usr/bin:/bin:/usr/sbin:/sbin"]),
            "ANTHROPIC_BASE_URL": base_url, "ANTHROPIC_API_KEY": FAKE_KEY,
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1",
        })
        # Claude Code reads its env and onboarding from the fresh home whatever the daemon passes on.
        (home / ".claude").mkdir(parents=True, exist_ok=True)
        (home / ".claude" / "settings.json").write_text(json.dumps({"env": {
            "ANTHROPIC_BASE_URL": base_url, "ANTHROPIC_API_KEY": FAKE_KEY, "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}}) + "\n")
        (home / ".claude.json").write_text(json.dumps({
            "hasCompletedOnboarding": True, "bypassPermissionsModeAccepted": True,
            "customApiKeyResponses": {"approved": [FAKE_KEY[-20:]], "rejected": []},
            "projects": {str(self.work): {"hasTrustDialogAccepted": True}},
        }))
        # The chat's folder trusted (pr_capture folder_trust.py's rule), so the first prompt waits on nothing.
        config = home / ".config" / "cmux" / "cmux-next.json"
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps({"agents": {"trust": {"autoTrust": True, "projectRoots": [str(self.work)]}}}) + "\n")
        env["CMUX_NEXT_CONFIG_FILE"] = str(config)
        if app:
            bundle_id = plistlib.loads((app / "Contents" / "Info.plist").read_bytes()).get("CFBundleIdentifier")
            if bundle_id:  # the account's defaults store is the one the app reads; the smoke puts it back after
                subprocess.run(["/usr/bin/defaults", "write", bundle_id, FIRST_RUN_KEY, "-bool", "true"],
                               capture_output=True, timeout=30)
        log("endpoint", base_url, "claude", claude_bin or "(none on PATH)", "app bin", app_bin)

    def cli(self, *args, timeout=60) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.cmux), "--app-socket", str(self.sock), *args],
                              env={**self.env, "CMUX_NEXT_SOCKET_PATH": str(self.sock)}, cwd=self.env["HOME"],
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)

    def acpmux(self, *args, timeout=60) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.acpmux_bin), *args], env=self.aenv, capture_output=True, text=True,
                              timeout=timeout, stdin=subprocess.DEVNULL)

    # The smoke's AFTER_RENDER: the failures, never an exception (that would read as could-not-run).
    def __call__(self, process, socket_path, env, app, out, report):
        try:
            self.drive(process, socket_path, env, Path(app))
        except Exception as error:  # noqa: BLE001 - a driver error is this run's failure, with its reason
            self.failures.append(f"driver: {type(error).__name__}: {error}")
            log("driver error", repr(error))
        finally:
            for p in reversed(self.procs):
                if p.poll() is None:
                    p.terminate()
                    try:
                        p.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        p.kill()
            if self.server is not None:
                self.server.shutdown()
        return list(self.failures)

    def acpmux_home(self, chat: str):
        """The app's acpmux home (shared ~/.acpmux for a NIGHTLY, else ~/.acpmux/builds/<key>): the one that
        holds the chat's session."""
        root = Path(self.env["HOME"]) / ".acpmux"
        for _ in range(120):
            for home in [root, *sorted((root / "builds").glob("*"))]:
                if (home / "sessions" / chat).is_dir():
                    return home
            time.sleep(0.5)
        return root

    def drive(self, process, socket_path, env, app: Path) -> None:
        a, out = self.a, self.out
        self.env, self.sock, self.pid = env, socket_path, process.pid
        self.cmux = app / "Contents" / "Resources" / "bin" / "cmux"
        self.acpmux_bin = app / "Contents" / "Resources" / "bin" / "acpmux"
        info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
        self.app_info = {"bundle_id": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"),
                         "build": info.get("CFBundleVersion"), "commit": info.get("CMUXCommit")}
        (out / "shots").mkdir(parents=True, exist_ok=True)
        t0 = time.time()
        self.t0, self.lift = t0, t0 + a.storm
        self.ep.lift_at(self.lift)
        made = self.cli("agents", "chat", "new", "--name", "coord", "--harness", "claude", "--policy", "approve-all",
                        "--cwd", str(self.work), "--", "plan the day", timeout=120)
        answer = parsed(made.stdout)
        chat = found(answer, "chat")
        (out / "chat-new.json").write_text(json.dumps({"exit": made.returncode, "stdout": made.stdout[-4000:],
                                                       "stderr": made.stderr[-4000:]}, indent=1))
        if made.returncode != 0 or not isinstance(chat, str) or not chat:
            self.failures.append(f"chat new exit {made.returncode}: {(made.stdout + made.stderr)[-400:]}")
            return
        self.chat = chat
        log("coord chat", chat)
        workspace = found(answer, "workspace")
        for _ in range(20):
            if isinstance(workspace, str) and workspace:
                break
            topology = (rpc(socket_path, "snapshot.get") or {}).get("topology") or {}
            workspace = next((w["id"] for w in topology.get("workspaces") or []
                              if isinstance(w, dict) and w.get("id") and holds(w.get("screens"), chat)), None)
            time.sleep(0.5)
        shown = self.cli("agents", "workspace", "select", workspace) if workspace else None
        self.shown = bool(shown and shown.returncode == 0)
        log("workspace", workspace, "selected" if self.shown else "NOT selected")
        home = self.acpmux_home(chat)
        self.acpmux_home_path = home
        self.aenv = {**env, "ACPMUX_HOME": str(home)}
        log("acpmux home", home, self.acpmux("--version").stdout.strip())

        # The attached client, as the harness has it: the chat's events the whole run.
        tail = subprocess.Popen([str(self.acpmux_bin), "session", "tail", chat, "-f"], env=self.aenv,
                                stdout=(out / "attached-client.ndjson").open("w"),
                                stderr=(out / "attached-client.err").open("w"), stdin=subprocess.DEVNULL)
        self.procs.append(tail)
        stop = threading.Event()
        shooter = threading.Thread(target=self.shoot_loop, args=(stop,), daemon=True)
        shooter.start()
        senders = [threading.Thread(target=self.sender, args=(k,)) for k in range(a.agents)]
        for t in senders:
            t.start()
        for t in senders:
            t.join()
        log(f"sends done: {len(self.sent)}; lift in {max(0, self.lift - time.time()):.0f} s")
        time.sleep(max(0, self.lift - time.time()))
        lifted = time.time()
        markers = [s["marker"] for s in self.sent]
        deadline, quiet_since, seen_n = lifted + a.settle, time.time(), -1
        while time.time() < deadline:
            if set(markers) <= storm.received(list(self.ep.requests)):
                break
            n = len(self.ep.requests)
            if n != seen_n:
                seen_n, quiet_since = n, time.time()
            if time.time() - quiet_since > a.quiet and time.time() - lifted > a.quiet:
                log(f"no model request for {a.quiet} s; stopping the wait")
                break
            time.sleep(2)
        settled = time.time()
        log(f"settled {settled - lifted:.0f} s after the lift; shooting {a.after} s more")
        time.sleep(a.after)
        stop.set()
        shooter.join(timeout=120)
        self.shoot("final")
        (out / "sent.json").write_text(json.dumps(self.sent, indent=1))
        meta = {"label": a.label, "acpmux": self.acpmux("--version").stdout.strip(), "harness": "claude",
                "agents": a.agents, "interval_s": a.interval, "storm_s": a.storm, "retry_after": a.retry_after,
                "session": chat, "t0": t0, "lifted": lifted, "settled": settled, "end": time.time(),
                "attached_client_alive": tail.poll() is None, "daemon_alive": self.acpmux("--json", "ls").returncode == 0,
                "app": self.app_info}
        (out / "meta.json").write_text(json.dumps(meta, indent=1))
        # The daemon's journal of the chat, beside the run (storm.tally reads OUT/acpmux-home), before cleanup.
        for f in home.glob(f"sessions/{chat}/events/*.ndjson"):
            dest = out / "acpmux-home" / "sessions" / chat / "events" / f.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(f, dest)
        res = storm.tally(out)
        res["gui"] = self.gui_counts(markers, lifted, settled)
        res["app"] = self.app_info
        (out / "result.json").write_text(json.dumps(res, indent=2))

    def sender(self, k: int) -> None:
        a, i = self.a, 0
        nxt = self.t0 + 1 + k * a.interval / a.agents
        while nxt < self.lift:
            time.sleep(max(0, nxt - time.time()))
            marker = f"STORM-{k}-{i}"
            at = time.time()
            r = self.acpmux("--json", "send", self.chat, "--from", f"lane-{k}", "--no-wait", "--class", "question",
                            f"{marker}: report {i} from lane-{k}")
            with self.lock:
                self.sent.append({"marker": marker, "at": at, "rc": r.returncode, "out": r.stdout.strip()[-300:],
                                  "err": r.stderr.strip()[-300:]})
            i += 1
            nxt += a.interval

    def shoot_loop(self, stop: threading.Event) -> None:
        n = 0
        while not stop.is_set():
            self.shoot(f"t{n:03d}")
            n += 1
            stop.wait(self.a.shot_every)

    def shoot(self, name: str) -> None:
        at = time.time()
        row = {"name": name, "t": round(at - self.t0, 1), "storm": at < self.lift}
        state = self.cli("agents", "chat", "state", self.chat, timeout=30)
        row["state"] = parsed(state.stdout) if state.returncode == 0 else (state.stdout + state.stderr)[-300:]
        row["busy"] = busy(row["state"])
        wid = window_id(self.pid)
        path = self.out / "shots" / f"{name}.png"
        if wid is not None and subprocess.run(["screencapture", "-x", "-o", f"-l{wid}", str(path)],
                                              capture_output=True, timeout=30).returncode == 0 and path.exists():
            subprocess.run(["sips", "-Z", "1600", str(path)], capture_output=True, timeout=60)
            row["shot"] = path.name
            if self.ocr is not None and self.ocr.exists():
                text = subprocess.run([str(self.ocr), str(path)], capture_output=True, text=True, timeout=120).stdout
                (self.out / "shots" / f"{name}.txt").write_text(text)
                lines = [line.strip() for line in text.splitlines() if line.strip()]
                row["notice"] = [line for line in lines if NOTICE.search(line)][:8]
        else:
            row["shot_error"] = f"window {wid}"
        with self.lock:
            self.shots.append(row)
        log("shot", name, "t", row["t"], "busy" if row["busy"] else "idle", "notice", row.get("notice"))

    def transcript(self) -> list:
        items, after = [], 0
        for _ in range(100):
            page = parsed(self.cli("agents", "chat", "read", self.chat, "--after", str(after), "--limit", "200",
                                   timeout=60).stdout)
            got = found(page, "items") or []
            items += [i for i in got if isinstance(i, dict)]
            nxt = found(page, "next_after")
            if not got or not isinstance(nxt, int) or nxt <= after:
                break
            after = nxt
        return items

    def gui_counts(self, markers: list, lifted: float, settled: float) -> dict:
        items = self.transcript()
        (self.out / "transcript.json").write_text(json.dumps(items, indent=1)[:20_000_000])
        seen: dict[str, int] = {}
        for item in items:
            if item.get("role") == "assistant":
                continue  # the model's "ack STORM-..." replies name markers too
            for x in set(f"STORM-{k}-{i}" for k, i in storm.MARK.findall(json.dumps(item))):
                seen[x] = seen.get(x, 0) + 1
        once = [m for m in markers if seen.get(m) == 1]
        missing = [m for m in markers if not seen.get(m)]
        dup = [m for m in markers if seen.get(m, 0) > 1]
        after = [s for s in self.shots if self.t0 + s["t"] >= lifted]
        busy_after = [s for s in after if s["busy"]]
        # Stuck: still busy in the last shot, taken AFTER seconds past the settle (no model request left).
        last = self.shots[-1] if self.shots else {}
        notices = [s for s in self.shots if s.get("notice")]
        still_busy_from = None
        for s in after:
            if s["busy"] and still_busy_from is None:
                still_busy_from = s["t"]
            elif not s["busy"]:
                still_busy_from = None
        return {
            "transcript_items": len(items), "pane_once": len(once), "pane_missing": len(missing),
            "pane_duplicated": len(dup), "pane_missing_markers": missing[:20], "pane_duplicated_markers": dup[:20],
            "chat_shown": self.shown, "shots": len(self.shots),
            "busy_shots_after_lift": len(busy_after),
            "busy_after_lift_until_s": round(max((self.t0 + s["t"] for s in busy_after), default=lifted) - lifted, 1),
            "settled_after_lift_s": round(settled - lifted, 1),
            "stuck_busy_at_end": bool(last.get("busy")),
            "stuck_busy_for_s": round(last["t"] - still_busy_from, 1) if last.get("busy") and still_busy_from else 0,
            "notice_seen": bool(notices), "notice_in_storm": any(s["storm"] for s in notices),
            "notice_after_lift": any(not s["storm"] for s in notices),
            "notice_first_t": notices[0]["t"] if notices else None,
            "notice_lines": list(dict.fromkeys(line for s in notices for line in s["notice"]))[:12],
            "per_shot": [{k: s.get(k) for k in ("name", "t", "storm", "busy", "notice", "shot")} for s in self.shots],
        }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--dmg")
    source.add_argument("--app")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ocr", help="a compiled scripts/e2e/ocr.swift")
    ap.add_argument("--label", default="gui")
    ap.add_argument("--agents", type=int, default=7)
    ap.add_argument("--interval", type=float, default=15)
    ap.add_argument("--storm", type=float, default=600)
    ap.add_argument("--retry-after", default="none")
    ap.add_argument("--settle", type=float, default=900)
    ap.add_argument("--quiet", type=float, default=240)
    ap.add_argument("--shot-every", type=float, default=20)
    ap.add_argument("--after", type=float, default=90, help="seconds of shots after the chat settled")
    a = ap.parse_args(argv)
    os.umask(0o022)  # acpmux refuses a state folder under a group-writable one
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    run = Run(a)
    smoke.PREPARE_HOME = run.prepare
    smoke.AFTER_RENDER = run
    code = smoke.main([f"--{'dmg' if a.dmg else 'app'}", a.dmg or a.app, "--out", str(out), "--seconds", "5",
                       "--startup-timeout", "120"])
    result_path = out / "result.json"
    res = json.loads(result_path.read_text()) if result_path.exists() else {}
    res.update(smoke_exit=code, failures=run.failures)
    result_path.write_text(json.dumps(res, indent=2))
    gui = res.get("gui") or {}
    print("STORM-GUI " + json.dumps({k: v for k, v in res.items() if k not in ("gui",) and not k.endswith("_gaps_s")}))
    print("STORM-GUI gui " + json.dumps({k: v for k, v in gui.items() if k != "per_shot"}))
    row = {k: res.get(k) for k in ("label", "sent", "reached_model", "lost", "duplicated", "model_requests_in_storm",
                                   "first_reply_after_lift_s")}
    row.update({k: gui.get(k) for k in ("pane_once", "pane_missing", "pane_duplicated", "stuck_busy_at_end",
                                        "stuck_busy_for_s", "notice_seen", "busy_after_lift_until_s")})
    print("STORM-GUI row " + " ".join(f"{k}={str(v).replace(' ', '_')}" for k, v in row.items()))
    if code == smoke.CANNOT_RUN:
        return 3
    return 0 if gui else 1


if __name__ == "__main__":
    sys.exit(main())
