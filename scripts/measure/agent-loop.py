#!/usr/bin/env python3
"""The agent loop on a real cmux NEXT NIGHTLY (hq#7149 L8): a scripted UI change, applied live, probed.

    agent-loop.py --dmg DMG|--app APP --tree DIR --out DIR [--ocr OCR]

What an agent does with `scripts/cmux-next/live-apply.py`, with no full build and no person:

  1. The published app launches from a fresh home (scripts/ci/fresh_home_launch_smoke.py: its own
     HOME, socket and defaults set aside), with its web overlay, settings file and Debug Settings
     (`webDev.override` on) in this run's folder. Settings opens (`settings.open`).
  2. Base: the marker is not in the app (the probe must discriminate).
  3. Edit: the "agent" appends a few lines to the Settings page's entry (webviews/src/pages/
     settings/main.tsx in TREE, a checkout at the app's CMUXCommit): a banner with a nonce, and a
     console.warn of the same nonce.
  4. Apply: live-apply.py --repo TREE --base CMUXCommit --probe "this script's probe": it sorts the
     change (web-live), builds TREE's web bundles, swaps them into the overlay (the app reloads the
     page) and asks the probe until it passes.
  5. Rollback: a second edit whose probe asks for a nonce that never appears; live-apply.py must
     roll back, and the first nonce must show again.
  6. The app is the same process throughout (pid and start time), and still answers.

The probe reads the real app: `errors.list` (a Release method) collects the page's console output
from the app's own log, so the nonce there means the new bundle's code ran in that page. A
screenshot read with Vision (--ocr, scripts/e2e/ocr.swift) also looks for the banner on screen;
that is evidence only (a runner without the Screen Recording grant reads nothing).

Writes OUT/result.json (`cmux.agent-loop/1`): pass, rung, applied, probe, seconds, rolled_back, the
two live-apply verdicts, pid checks, the app's version and commit. Exit 0 when the loop passed,
1 when it failed, 3 when it could not run.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import shlex
import socket
import string
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

ENTRY = "webviews/src/pages/settings/main.tsx"
MARK = "cmux-live-apply"


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


def nonce() -> str:
    # Letters only: the error journal folds digits into its template, and Vision reads words better.
    return "".join(random.choice(string.ascii_lowercase) for _ in range(10))


def logged(sock_path, word: str, since_ms: float | None = None) -> bool | None:
    """Whether a page logged `cmux-live-apply WORD` (console.warn, harvested from the app's log),
    since SINCE_MS (unix ms) when given; None when the app did not answer."""
    params = {"source": "page", "text": f"{MARK} {word}", "level": "warning", "limit": 20}
    params.update({"since_ms": since_ms} if since_ms is not None else {"since": "10m"})
    found = rpc(sock_path, "errors.list", params, timeout=15)
    if not isinstance(found, dict) or "error" in found:
        return None
    return any(f"{MARK} {word}" in str(e.get("sample", "")) for e in found.get("entries") or [])


def on_screen(ocr: Path | None, shot: Path, word: str) -> bool | None:
    """Whether the banner reads on screen; None when there is no reader or no screenshot."""
    if ocr is None or not ocr.exists():
        return None
    try:
        if subprocess.run(["screencapture", "-x", str(shot)], capture_output=True, timeout=20).returncode != 0:
            return None
        text = subprocess.run([str(ocr), str(shot)], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return word.upper() in text.upper().replace(" ", "")


def probe_main(argv: list[str]) -> int:
    """`agent-loop.py probe --socket S --word W`: 0 when the page logged W, 1 when not."""
    parser = argparse.ArgumentParser(prog="agent-loop.py probe")
    parser.add_argument("--socket", required=True)
    parser.add_argument("--word", required=True)
    args = parser.parse_args(argv)
    return 0 if logged(args.socket, args.word) else 1  # None (no answer) asks again too


def snippet(word: str) -> str:
    return (f"\n// {MARK}: hq#7149 L8's scripted change (scripts/measure/agent-loop.py), never committed.\n"
            f'console.warn("{MARK} {word}");\n'
            "{\n"
            '  const banner = document.createElement("div");\n'
            f'  banner.textContent = "LIVEAPPLY {word.upper()}";\n'
            '  banner.style.cssText = "position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:2147483647;'
            'font:700 36px -apple-system,sans-serif;color:#000;background:#ff0;padding:6px 16px";\n'
            "  document.body.appendChild(banner);\n"
            "}\n")


class Loop:
    def __init__(self, opts):
        self.opts = opts
        self.tree = Path(opts.tree).resolve()
        self.result = {"schema": "cmux.agent-loop/1", "pass": False, "failures": [], "steps": []}
        self.work = None

    # The fresh home: this run's overlay, settings file and Debug Settings with the overlay toggle on.
    def prepare(self, env: dict) -> None:
        home = Path(env["HOME"])
        config = home / ".config" / "cmux" / "cmux-next.json"
        overlay = home / "Library" / "Application Support" / "cmux-next" / "web-overlay"
        tunables = home / "agent-loop" / "debug-tunables.json"
        for path in (config.parent, overlay, tunables.parent):
            path.mkdir(parents=True, exist_ok=True)
        tunables.write_text('{"version": 1, "values": {"webDev.override": true}}\n')
        env.update(CMUX_NEXT_CONFIG_FILE=str(config), CMUX_WEB_OVERLAY_DIR=str(overlay),
                   CMUX_NEXT_DEBUG_TUNABLES_FILE=str(tunables))
        self.overlay_env = {k: env[k] for k in ("CMUX_NEXT_CONFIG_FILE", "CMUX_WEB_OVERLAY_DIR")}

    def step(self, name: str, ok: bool, **detail) -> bool:
        self.result["steps"].append(dict(step=name, ok=ok, **detail))
        smoke.log(f"agent-loop {name}: {'ok' if ok else 'FAILED'} {json.dumps(detail)[:400]}")
        if not ok:
            self.result["failures"].append(name)
        return ok

    def identity(self) -> tuple:
        ident = rpc(self.sock, "system.identify") or {}
        pid = ident.get("pid")
        started = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() \
            if isinstance(pid, int) else None
        return pid, started

    def apply(self, word: str, expect: str, probe_seconds: float) -> dict:
        """Edits the entry with WORD, then live-apply.py with a probe that waits for EXPECT."""
        entry = self.tree / ENTRY
        subprocess.run(["git", "-C", str(self.tree), "checkout", "--", ENTRY], check=True)
        with entry.open("a") as handle:
            handle.write(snippet(word))
        probe = shlex.join([sys.executable, str(Path(__file__).resolve()), "probe", "--socket", str(self.sock),
                            "--word", expect])
        env = dict(os.environ, **self.overlay_env)
        log = self.out / f"live-apply-{word}.log"  # agent-loop.sh clears live-apply-*.log
        try:
            # stderr to the log as it runs, so a hung bundle build still leaves its output.
            with log.open("w") as stderr:
                done = subprocess.run([sys.executable, str(ROOT / "scripts/cmux-next/live-apply.py"), "--repo",
                                       str(self.tree), "--base", self.commit, "--probe", probe,
                                       "--probe-seconds", str(probe_seconds)],
                                      env=env, stdout=subprocess.PIPE, stderr=stderr, text=True, timeout=900)
        except subprocess.TimeoutExpired:
            return {"error": "live-apply.py ran past 900 s", "stderr": log.read_text(errors="replace")[-2000:]}
        done.stderr = log.read_text(errors="replace")
        try:
            return json.loads(done.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return {"error": f"live-apply.py exited {done.returncode} with no verdict", "stderr": done.stderr[-2000:]}

    def __call__(self, process, socket_path, env, app, out, report):
        """The smoke's AFTER_RENDER: the failures, never an exception (that would read as could-not-run)."""
        try:
            return self.loop(process, socket_path, app, out)
        except Exception as error:  # noqa: BLE001 - any harness error is this run's failure, with its reason
            self.step("harness", False, error=f"{type(error).__name__}: {error}")
            return [f"agent loop: {name}" for name in self.result["failures"]]

    def loop(self, process, socket_path, app, out):
        self.sock, self.out = socket_path, Path(out)
        info = smoke.plistlib.loads((Path(app) / "Contents" / "Info.plist").read_bytes())
        self.commit = info.get("CMUXCommit") or ""
        self.result["app"] = {"bundle_id": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"),
                              "build": info.get("CFBundleVersion"), "commit": self.commit, "pid": process.pid}
        tree_head = subprocess.run(["git", "-C", str(self.tree), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        # A nightly stamps the commit's first 7 hex; the tree holds the full one, which live-apply.py gets.
        if not self.step("tree", len(self.commit) >= 7 and tree_head.startswith(self.commit), tree=tree_head,
                         app_commit=self.commit):
            return self.result["failures"]
        self.commit = tree_head
        before = self.identity()
        opened = rpc(self.sock, "settings.open", {}, timeout=30)
        time.sleep(3)  # harness: the Settings page loads
        self.step("settings", isinstance(opened, dict) and "error" not in opened, reply=opened)

        first, never = nonce(), nonce()
        self.step("base", logged(self.sock, first) is False, word=first)
        t0 = time.monotonic()
        applied = self.apply(first, first, self.opts.probe_seconds)
        self.result["apply"] = applied
        ok = applied.get("rung") == "R0" and applied.get("applied") and applied.get("probe") == "pass"
        self.step("apply", bool(ok), seconds=applied.get("seconds"), phases=applied.get("phases"),
                  verdict=applied.get("verdict"), probe=applied.get("probe"))
        self.result["edit_to_probe_s"] = round(time.monotonic() - t0, 2)
        self.result["on_screen"] = on_screen(self.ocr, self.out / "applied.png", first)

        # A second change whose probe waits for a word no page ever logs: live-apply.py must roll back to
        # the first change's generation, so the page loads it again and logs the first word anew.
        second = nonce()
        since = time.time() * 1000
        rolled = self.apply(second, never, 10.0)
        self.result["rollback"] = rolled
        reloaded, deadline = False, time.monotonic() + self.opts.probe_seconds
        while time.monotonic() < deadline and not reloaded:
            reloaded = bool(logged(self.sock, first, since))
            time.sleep(0.5)  # harness: the page reloads onto the restored generation
        self.step("rollback", rolled.get("probe") == "fail" and rolled.get("rolled_back") is True and reloaded,
                  rolled_back=rolled.get("rolled_back"), probe=rolled.get("probe"), first_back=reloaded,
                  seconds=(rolled.get("phases") or {}).get("rollback"))

        after = self.identity()
        self.step("same-process", before[0] == after[0] == process.pid and before[1] == after[1] and process.poll() is None,
                  before=before, after=after)
        subprocess.run(["git", "-C", str(self.tree), "checkout", "--", ENTRY], check=False)
        self.result["pass"] = not self.result["failures"]
        self.result.update(rung=applied.get("rung"), applied=applied.get("applied"), probe=applied.get("probe"),
                           seconds=applied.get("seconds"), rolled_back=rolled.get("rolled_back"))
        return [f"agent loop: {name}" for name in self.result["failures"]]


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["probe"]:
        return probe_main(argv[1:])
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--dmg")
    source.add_argument("--app")
    parser.add_argument("--tree", required=True, help="a cmux checkout at the app's CMUXCommit (webviews installed)")
    parser.add_argument("--out", required=True)
    parser.add_argument("--ocr", help="a compiled scripts/e2e/ocr.swift (evidence only)")
    parser.add_argument("--probe-seconds", type=float, default=45.0)
    opts = parser.parse_args(argv)
    out = Path(opts.out)
    out.mkdir(parents=True, exist_ok=True)
    loop = Loop(opts)
    loop.ocr = Path(opts.ocr) if opts.ocr else None
    smoke.PREPARE_HOME = loop.prepare
    smoke.AFTER_RENDER = loop
    started = time.time()
    code = smoke.main([f"--{'dmg' if opts.dmg else 'app'}", opts.dmg or opts.app, "--out", str(out),
                       "--seconds", "5", "--startup-timeout", "120"])
    result = loop.result
    result["total_s"] = round(time.time() - started, 2)
    result["smoke_exit"] = code
    if code != 0 and not result["failures"]:
        result["failures"].append(f"launch smoke exit {code}")
    result["pass"] = code == 0 and not result["failures"]
    (out / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print("AGENT-LOOP " + json.dumps({k: result.get(k) for k in ("pass", "rung", "applied", "probe", "seconds",
                                                                  "rolled_back", "edit_to_probe_s", "on_screen", "failures")}))
    if code == smoke.CANNOT_RUN:
        return 3
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
