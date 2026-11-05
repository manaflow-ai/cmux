#!/usr/bin/env python3
"""Projection window (cmuxterm-hq#7149 row L10): a worktree's change in a window of the running NIGHTLY.

Leo, 2026-11-05: "It's like a binary. Like, did you hit it? Did you not fucking hit it?" On a fresh home
(fresh_home_launch_smoke.py launches the app, as the nightly gate does), with this checkout as the worktree:

  1. starts the worktree's webviews dev server (`bun run dev`) behind a logging TCP proxy, so every file the
     app fetches for a page is a line with its time (a NIGHTLY has no control method that reads a page);
  2. opens a projection window on it (`action.run debug.projection --server <proxy> --worktree . --page
     settings --test ...`) and waits for the Settings page's document to come through the proxy;
  3. saves a file of the Settings page in the worktree and times save -> the page's first fetch of the
     changed module (Vite HMR, `?t=`, or a full reload's document): `save_to_page_ms`, budget --budget-ms (5000);
  4. checks the main windows were not touched: the same windows as before plus one, and no request through
     the proxy before the projection opened (the main windows read the shipped pages);
  5. runs the one named test (`action.run debug.projection.runTest`), which writes a marker in the worktree;
  6. edits `appearance.theme` and a shortcut in cmux-next.json and reads them back live from the same process
     (`cmux settings get`, `cmux keybinding list`), with no restart.

Prints `L10-STEP {json}` per step and one `L10 {json}` verdict; exit 0 only when every step passed. A NIGHTLY
built before projection windows (#36138) refuses `debug.projection`; the run then says `not-yet` and exits 3.

  projection_check.py (--app APP | --dmg DMG) [--budget-ms 5000] [--out DIR]
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

ROOT = HERE.parent.parent
PAGE = "settings"
EDIT = ROOT / "webviews" / "src" / "pages" / PAGE / "main.tsx"
SHORTCUT_ACTION = "debug.projection.runTest"
SHORTCUT = "cmd+shift+opt+9"  # the app reports modifiers as cmd, shift, opt, ctrl
THEMES = ("Catppuccin Mocha", "Catppuccin Latte")


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Proxy:
    """A TCP proxy on 127.0.0.1:port to the dev server, logging each HTTP request line with its monotonic time.
    Raw bytes pass both ways, so Vite's HMR WebSocket works through it."""

    LINE = re.compile(rb"(?:^|\r\n)(GET|HEAD|POST) (\S+) HTTP/1\.[01]\r\n")

    def __init__(self, port: int, upstream: int):
        self.port, self.upstream = port, upstream
        self.requests: list[tuple[float, str]] = []
        self.lock = threading.Lock()
        self.loop = asyncio.new_event_loop()

    def start(self) -> None:
        ready = threading.Event()

        async def serve():
            server = await asyncio.start_server(self.client, "127.0.0.1", self.port)
            ready.set()
            async with server:
                await server.serve_forever()

        threading.Thread(target=lambda: self.loop.run_until_complete(serve()), daemon=True).start()
        if not ready.wait(10):
            raise RuntimeError("the proxy did not start")

    async def client(self, reader, writer):
        try:
            up_reader, up_writer = await asyncio.open_connection("127.0.0.1", self.upstream)
        except OSError:
            writer.close()
            return

        async def pipe(src, dst, record):
            pending = b""  # an unfinished request line carried to the next read
            try:
                while data := await src.read(65536):
                    if record:
                        scan = pending + data
                        end = 0
                        for match in self.LINE.finditer(scan):
                            end = match.end()
                            with self.lock:
                                self.requests.append((time.monotonic(), match.group(2).decode("latin-1")))
                        # Keep only the tail after the last full line (bounded, so a body or WebSocket frames
                        # never grow it).
                        pending = scan[max(end, len(scan) - 8192):]
                    dst.write(data)
                    await dst.drain()
            except (ConnectionError, OSError):
                pass
            finally:
                dst.close()

        await asyncio.gather(pipe(reader, up_writer, True), pipe(up_reader, writer, False))

    def since(self, t0: float) -> list[tuple[float, str]]:
        with self.lock:
            return [r for r in self.requests if r[0] >= t0]


def wait(probe, seconds: float, every: float = 0.05):
    end = time.monotonic() + seconds
    while True:
        value = probe()
        if value or time.monotonic() >= end:
            return value
        time.sleep(every)


def start_dev_server(port: int, proxy_port: int, out: Path) -> subprocess.Popen:
    web = ROOT / "webviews"
    if not (web / "node_modules").is_dir():
        subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=web, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["bun", "scripts/pages/gen-strings.mjs", "--best-effort"], cwd=web,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    handle = open(out / "dev-server.log", "w")
    # The page's HMR socket goes through the proxy: its CSP allows only the server the app fetches from.
    env = dict(os.environ, CMUX_WEBVIEWS_DEV_PORT=str(port), CMUX_WEBVIEWS_HMR_CLIENT_PORT=str(proxy_port))
    return subprocess.Popen(["bun", "run", "dev"], cwd=web, env=env, stdin=subprocess.DEVNULL, stdout=handle,
                            stderr=subprocess.STDOUT, start_new_session=True)


def answers(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1) as conn:
            conn.sendall(b"GET /agent-pane/index.html HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
            return conn.recv(12).startswith(b"HTTP/1.1 200")
    except OSError:
        return False


def has_binding(answer, binding: str) -> bool:
    """Whether a `keybinding list` answer (any wrapping) has a row whose `key` is `binding`, modifiers in any order."""
    want = binding.lower().split("+")
    want = (frozenset(want[:-1]), want[-1])
    stack = [answer]
    while stack:
        node = stack.pop()
        if isinstance(node, list):
            stack.extend(node)
        elif isinstance(node, dict):
            key = node.get("key")
            if isinstance(key, str) and key:
                parts = key.lower().split("+")
                if (frozenset(parts[:-1]), parts[-1]) == want:
                    return True
            stack.extend(v for v in node.values() if isinstance(v, (list, dict)))
    return False


def config_file(env: dict) -> Path:
    named = env.get("CMUX_NEXT_CONFIG_FILE")
    return Path(named) if named else Path(env["HOME"]) / ".config" / "cmux" / "cmux-next.json"


def write_config(path: Path, edit) -> None:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        data = {}
    edit(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".l10.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(tmp, path)


def check(args) -> int:
    import fresh_home_launch_smoke as smoke
    import stable_next_ui_journey as ui
    from relaunch_restore_check import Instance, call

    result: dict = {"budget_ms": args.budget_ms, "steps": {}}
    out = Path(args.out) if args.out else Path("/tmp/l10")
    out.mkdir(parents=True, exist_ok=True)

    def step(name: str, ok: bool, **fields) -> bool:
        row = {"step": name, "ok": ok, **fields}
        result["steps"][name] = row
        print("L10-STEP " + json.dumps(row, default=str), flush=True)
        return ok

    def journey(process, socket_path, env, app, run_out, report):
        inst = Instance(str(socket_path), str(app), env["HOME"])
        vite_port, proxy_port = free_port(), free_port()
        server = start_dev_server(vite_port, proxy_port, out)
        original = EDIT.read_text()
        marker = ROOT / ".build" / "l10-test-marker"
        marker.unlink(missing_ok=True)
        failures: list[str] = []
        try:
            if not wait(lambda: answers(vite_port), 120, 0.5):
                return ["the worktree's dev server did not answer (dev-server.log)"]
            proxy = Proxy(proxy_port, vite_port)
            proxy.start()
            windows_before = len((inst.topology() or {}).get("windows") or [])

            # 2. open the projection window and wait for its page's document
            t_open = time.monotonic()
            opened = call(inst.sock, "action.run", {"action": "debug.projection", "wait": True, "args": {
                "server": f"http://127.0.0.1:{proxy_port}/", "worktree": str(ROOT), "page": PAGE,
                "test": f"mkdir -p .build && echo l10 > {marker.relative_to(ROOT)}"}}, timeout=20)
            if "error" in opened:
                text = json.dumps(opened)
                if "unknown" in text.lower() or "not found" in text.lower():
                    result["verdict"] = "not-yet"
                step("open", False, error=opened)
                return [f"open: {opened}"]
            doc = wait(lambda: [r for r in proxy.since(t_open) if f"/{PAGE}" in r[1]], 30)
            if not step("open", bool(doc), open_to_page_ms=int((doc[0][0] - t_open) * 1000) if doc else None):
                failures.append("open: the projection window's page never loaded from the worktree")
                return failures

            # 4. the main windows: one more window, nothing through the proxy before the open
            topo = inst.topology() or {}
            windows_after = len(topo.get("windows") or [])
            early = [r for r in proxy.since(0.0) if r[0] < t_open]
            if not step("main-windows", windows_after == windows_before + 1 and not early,
                        windows_before=windows_before, windows_after=windows_after, early_requests=len(early)):
                failures.append("main windows: touched")

            # 3. save a file in the worktree; time to the page's fetch of the change
            # Quiet first: a first load's dependency optimizer may reload the page once on its own.
            def quiet():
                last = proxy.since(0.0)
                return bool(last) and time.monotonic() - last[-1][0] > 3.0
            wait(quiet, 60, 0.25)
            t_save = time.monotonic()
            EDIT.write_text(original + f"\n// l10 {time.time_ns()}\n")
            # The edited module fetched again (HMR `?t=`, or a full reload's import of it).
            changed = wait(lambda: [r for r in proxy.since(t_save) if f"pages/{PAGE}/main.tsx" in r[1]], 15)
            ms = int((changed[0][0] - t_save) * 1000) if changed else None
            if not step("save-to-page", ms is not None and ms < args.budget_ms, save_to_page_ms=ms, path=changed[0][1] if changed else None):
                failures.append(f"save: the change reached the page in {ms} ms (budget {args.budget_ms})")
            result["save_to_page_ms"] = ms

            # 5. one click runs the named test
            t_test = time.monotonic()
            ran = call(inst.sock, "action.run", {"action": "debug.projection.runTest", "wait": True}, timeout=20)
            done = wait(lambda: marker.exists(), 60, 0.25)
            if not step("run-test", "error" not in ran and done, run_test_ms=int((time.monotonic() - t_test) * 1000) if done else None,
                        answer=ran if "error" in ran else None):
                failures.append("run test: the marker never appeared")

            # 6. settings, theme and a shortcut reload live, same process
            pid = process.pid
            current = inst.cmux("settings", "get", "appearance.theme")
            theme = THEMES[1] if THEMES[0] in json.dumps(current) else THEMES[0]
            t_cfg = time.monotonic()
            write_config(config_file(env), lambda d: (d.setdefault("appearance", {}).__setitem__("theme", theme),
                                                      d.setdefault("shortcuts", {}).setdefault("bindings", {}).__setitem__(SHORTCUT_ACTION, SHORTCUT)))
            themed = wait(lambda: theme in json.dumps(inst.cmux("settings", "get", "appearance.theme")), 10, 0.2)
            keyed = wait(lambda: has_binding(inst.cmux("keybinding", "list", "--command", SHORTCUT_ACTION, "--source", "user"), SHORTCUT), 10, 0.2)
            if not step("config-live", bool(themed and keyed) and process.poll() is None and process.pid == pid,
                        theme=bool(themed), shortcut=bool(keyed), config_ms=int((time.monotonic() - t_cfg) * 1000)):
                failures.append(f"config: theme live {bool(themed)}, shortcut live {bool(keyed)}")
            return failures
        finally:
            EDIT.write_text(original)
            try:
                os.killpg(server.pid, 15)
            except OSError:
                pass

    smoke.AFTER_RENDER = journey
    smoke.PREPARE_HOME = ui.login_keychain
    argv = ["--seconds", "1", *(["--dmg", args.dmg] if args.dmg else ["--app", args.app]), "--out", str(out)]
    status = smoke.main(argv)
    passed = status == 0 and len(result["steps"]) == 5 and all(s["ok"] for s in result["steps"].values())
    result.setdefault("verdict", "pass" if passed else "fail")
    (out / "l10.json").write_text(json.dumps(result, indent=2, default=str))
    print("L10 " + json.dumps({k: result.get(k) for k in ("verdict", "save_to_page_ms", "budget_ms")}), flush=True)
    if result["verdict"] == "not-yet":
        return 3
    return 0 if passed else (status if status not in (0, None) else 1)


def main(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app")
    source.add_argument("--dmg")
    parser.add_argument("--budget-ms", type=int, default=5000)
    parser.add_argument("--out")
    return check(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
