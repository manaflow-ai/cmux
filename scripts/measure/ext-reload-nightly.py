#!/usr/bin/env python3
"""The app half of scripts/measure/ext-reload-nightly.sh: extension hot reload on a published NIGHTLY.

    ext-reload-nightly.py --app APP --pid-file F --customize DIR --config FILE --out DIR [--rounds N]

APP is a running side-instance copy of the NIGHTLY (its own bundle id, data, daemon and customize folder).
Two parts, both with the NIGHTLY's own bundled CLI and control socket, nothing from this checkout's build:

1. Read-back (`readback` in the receipt): `cmux ext dev` (watching, no `--once`) on a copy of
   examples/extensions/activity; after its first reload, a one-line save of its src/main.ts (the section title
   "No agent working" gets " (edited live)"). After the save nothing is asked to build or reload (no
   `ext dev --once`, no `ext shot`, which runs one build and reload itself): the proof only reads the watcher's
   own output, the copy the daemon loads (under `apps-list` `local_dir`) and the window's open views
   (`apps.views`). Passes when the watcher reloaded on its own after the save, the daemon's loaded copy holds
   the edited words, and every view of it the window had open shows them. Broken auto reload fails it.
2. Edit to repaint (`edit_repaint`): scripts/cmux-next/edit-repaint.py attached to the copy in read-back mode
   (a NIGHTLY has no debug.window_snapshot): the customize folder's section, rows and pane saved `--rounds`
   times each, a palette command and a key binding changed as often; each round timed to the save showing in
   the app's open views (`apps.views`, `palette.query`, `keybinding.resolve`), with no build or reload asked.

Prints `EXT_RELOAD_NIGHTLY {json}` (the receipt) and writes it to OUT/receipt.json. Exit 0 only when the
read-back passed and every round of every case was seen.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "examples/extensions/activity"
EDIT_FROM = '"No agent working"'
EDIT_TO = '"No agent working (edited live)"'
DEV_MARKER = ".cmux-ext-dev.json"  # cli/ext/dev.rs MARKER: names the source folder of a copy `ext dev` made


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


hot = load("hot_apply", ROOT / "scripts/cmux-next/hot-apply.py")
bench = load("bench_launch", ROOT / "scripts/cmux-next/bench_launch.py")


def wait_until(what: str, deadline: float, probe):
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.5)
    raise SystemExit(f"ext-reload-nightly: timed out waiting for {what}")


def control_socket(app_pid: int, named: str | None = None) -> str | None:
    """The copy's control socket: the one whose system.identify names the copy's pid (as hot-apply-nightly.py).
    `named` (what `side-instance.sh socket NAME` prints: NAME/control.sock, or its short-path fallback) is
    asked first; the usual places are searched only when it does not answer."""
    import glob
    if named:
        reply = bench.rpc_at(named, "system.identify", timeout=5)
        if isinstance(reply, dict) and reply.get("pid") == app_pid:
            return named
    socks = set(glob.glob("/tmp/cmux-*.sock"))
    for home in dict.fromkeys([bench.account_home(), os.path.expanduser("~")]):
        socks.update(glob.glob(os.path.join(home, ".local/state/cmux/*.sock")))
    tmp = os.environ.get("TMPDIR")
    if tmp:
        socks.update(glob.glob(os.path.join(tmp, "cmux-side-*.sock")))
    for sock in sorted(socks):
        reply = bench.rpc_at(sock, "system.identify", timeout=5)
        if isinstance(reply, dict) and reply.get("pid") == app_pid:
            return sock
    return None


def cli_json(cli: Path, globals_: list[str], args: list[str], timeout: float = 300) -> dict:
    """One CLI call; its exit, ms and JSON answer (or the output's tail)."""
    env = dict(os.environ)
    env["PATH"] = ":".join([os.path.expanduser("~/.bun/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                            env.get("PATH", "/usr/bin:/bin")])
    started = time.monotonic()
    try:
        run = subprocess.run([str(cli), *globals_, *args], capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return {"argv": args, "exit": None, "error": f"no answer in {timeout} s"}
    out = {"argv": args, "exit": run.returncode, "ms": round((time.monotonic() - started) * 1000)}
    try:
        out["json"] = json.loads(run.stdout)
    except ValueError:
        out["output"] = (run.stdout + run.stderr)[-3000:]
    if run.returncode != 0:
        out["stderr"] = run.stderr[-2000:]
    return out


def scene_of(shot: dict) -> list:
    """The scene outline `ext shot --json` printed (its `scene`, wherever it nests)."""
    def find(value):
        if isinstance(value, dict):
            if isinstance(value.get("scene"), list):
                return value["scene"]
            for item in value.values():
                found = find(item)
                if found is not None:
                    return found
        elif isinstance(value, list):
            for item in value:
                found = find(item)
                if found is not None:
                    return found
        return None
    return find(shot.get("json")) or []


def wait_for(probe, wait: float, step: float = 0.2):
    """`probe()` until it answers, for up to `wait` seconds; its last answer (falsy on a timeout)."""
    deadline = time.monotonic() + wait
    while True:
        value = probe()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(step)


def daemon_op(path: str, request: dict, timeout: float = 15) -> dict:
    """One request line on the daemon socket and its reply (event lines skipped). Used for reads only."""
    request = {"id": "ext-reload", **request}
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    try:
        conn.connect(path)
        conn.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while True:
            chunk = conn.recv(1 << 20)
            if not chunk:
                return {"ok": False, "error": "socket closed before a reply"}
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    value = json.loads(line)
                except ValueError:
                    continue
                if isinstance(value, dict) and value.get("id") == request["id"]:
                    return value
    except OSError as error:
        return {"ok": False, "error": f"socket: {error}"}
    finally:
        conn.close()


def find_key(value, key: str):
    """The first value named `key` in `value`, depth first."""
    if isinstance(value, dict):
        if key in value:
            return value[key]
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            found = find_key(item, key)
            if found is not None:
                return found
    return None


def loaded_copy(daemon: str, source: Path) -> Path | None:
    """The folder the daemon loads `source` from: the one under its local folder (`apps-list` `local_dir`)
    whose `ext dev` marker names `source` (cli/ext/dev.rs `sync`). A read: nothing is built or reloaded."""
    local_dir = find_key(daemon_op(daemon, {"cmd": "apps-list"}), "local_dir")
    if not isinstance(local_dir, str) or not os.path.isdir(local_dir):
        return None
    for marker in Path(local_dir).glob(f"*/{DEV_MARKER}"):
        try:
            owner = json.loads(marker.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(owner, dict) and Path(str(owner.get("source", ""))).resolve() == source.resolve():
            return marker.parent
    return None


def copy_holds(copy: Path | None, words: str) -> bool:
    """Whether the daemon's loaded copy of the extension (its built scripts) holds `words`."""
    if copy is None:
        return False
    for path in copy.rglob("*.js"):
        try:
            if words in path.read_text(errors="replace"):
                return True
        except OSError:
            continue
    return False


def open_views(control: str, app: str) -> list[dict]:
    """The window's open views of `app` (`apps.views`: the window's own mirror of each view's scene)."""
    reply = bench.rpc_at(control, "apps.views", {"app": app}, timeout=10)
    found = reply.get("views") if isinstance(reply, dict) else None
    return [{k: v.get(k) for k in ("interface", "preview", "status", "revision", "texts")}
            for v in found or [] if isinstance(v, dict)]


RELOAD_LINES = ("reloaded", "not reloaded", "load failed", "build failed", "manifest invalid",
                "no change to the files", "cmux is not reachable")


def reload_lines(log: Path) -> list[str]:
    """The reload lines `ext dev` printed so far (cli/ext/dev.rs `Outcome::line`), in order."""
    try:
        text = log.read_text(errors="replace")
    except OSError:
        return []
    return [line for line in text.splitlines() if line.startswith(RELOAD_LINES)]


def readback(cli: Path, globals_: list[str], work: Path, daemon: str, control: str) -> dict:
    """`ext dev` left watching a copy of the example, a one-line save, then only reads: the watcher must reload
    on its own, and the daemon's loaded copy (and every view of it the window had open) must show the edit.

    After the save nothing is asked to build or reload: no `ext dev --once`, no `ext shot` (which runs a build
    and a reload of its own), no `apps-reload-local`. A broken watch, build on save or daemon reload fails it:
    `ext dev` prints `reloaded` only after the daemon's own reload answer and a load check of the new script."""
    folder = work / "activity"
    if folder.exists():
        shutil.rmtree(folder)
    # A copy outside the checkout, as a person's would be: `ext dev` builds it with the SDK its own CLI
    # embeds (the NIGHTLY's), not this checkout's.
    shutil.copytree(EXAMPLE, folder, ignore=shutil.ignore_patterns("node_modules", "dist"))
    out: dict = {"folder": str(folder), "method": "ext dev watching; after the save, reads only"}
    main = folder / "src/main.ts"
    text = main.read_text()
    if EDIT_FROM not in text:
        return out | {"error": f"src/main.ts has no {EDIT_FROM} to edit", "ok": False}
    app_id = json.loads((folder / "cmux-app.json").read_text()).get("id") or "local/activity"
    edited, original = EDIT_TO.strip('"'), EDIT_FROM.strip('"')
    log = work / "ext-dev.log"
    env = dict(os.environ)
    env["PATH"] = ":".join([os.path.expanduser("~/.bun/bin"), "/opt/homebrew/bin", "/usr/local/bin",
                            env.get("PATH", "/usr/bin:/bin")])
    with log.open("w") as sink:
        # --no-install: no consent card; --keep: the copy stays loaded when the watcher stops.
        watcher = subprocess.Popen([str(cli), *globals_, "ext", "dev", str(folder), "--no-install", "--keep"],
                                   stdout=sink, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=env)
    try:
        first = wait_for(lambda: reload_lines(log), 300)
        out["first_reload"] = first
        copy = wait_for(lambda: loaded_copy(daemon, folder), 30) if first else None
        out["loaded_copy"] = str(copy) if copy else None
        views_before = open_views(control, app_id)
        out["views_before"] = views_before
        first_ok = bool(first) and first[0].startswith("reloaded") and copy_holds(copy, original) \
            and not copy_holds(copy, edited)
        started = time.monotonic()
        main.write_text(text.replace(EDIT_FROM, EDIT_TO, 1))
        # Reads only from here: the watcher's output, the loaded copy on disk, the window's views.
        seen = len(first or [])
        after = wait_for(lambda: reload_lines(log)[seen:], 120)
        out["save_to_reload_ms"] = round((time.monotonic() - started) * 1000) if after else None
        out["reload_after_save"] = after
        shows = bool(wait_for(lambda: copy_holds(copy, edited), 10))
        open_before = [v for v in views_before if not v.get("preview")]

        def views_show() -> list[dict] | None:
            now = open_views(control, app_id)
            shown = [v for v in now if not v.get("preview")
                     and any(edited in str(t) for t in (v.get("texts") or []))]
            return now if len(shown) >= len(open_before) else None

        views_after = wait_for(views_show, 10) if open_before else None
        out["views_after"] = views_after if views_after is not None else open_views(control, app_id)
        out["checks"] = {
            "watcher_loaded_first": first_ok,
            "watcher_reloaded_on_save": bool(after) and after[0].startswith("reloaded"),
            "loaded_copy_shows_edit": shows,
            # Every view the window already had open shows the edit (none open: nothing to compare).
            "open_views_show_edit": views_after is not None if open_before else True,
        }
        out["open_views_before_save"] = len(open_before)
        out["ok"] = all(out["checks"].values())
    finally:
        if watcher.poll() is None:
            watcher.terminate()  # the watcher this run started, by its own pid
            try:
                watcher.wait(timeout=10)
            except subprocess.TimeoutExpired:
                watcher.kill()
        out["ext_dev_tail"] = log.read_text(errors="replace")[-3000:] if log.exists() else ""
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--customize", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--cases", default="extension,rows,pane,command,shortcut")
    parser.add_argument("--control-socket", help="the copy's control socket (side-instance.sh socket NAME)")
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cli = (app / hot.BIN / "cmux").resolve()
    app_pid = int(Path(args.pid_file).read_text().strip())
    receipt: dict = {"host": os.uname().nodename, "app": str(app), "app_commit": hot.app_commit(app),
                     "version": subprocess.run([str(cli), "--version"], capture_output=True, text=True).stdout.strip()}
    control = wait_until("the copy's control socket", time.monotonic() + 120,
                         lambda: control_socket(app_pid, args.control_socket))
    receipt["control_socket"] = control
    # A workspace with a terminal starts the copy's daemon (a new workspace opens on the native New Tab page).
    bench.rpc_at(control, "action.run", {"action": "workspace.newAtBottom"}, timeout=30)
    bench.rpc_at(control, "action.run", {"action": "newSurface"}, timeout=30)
    daemon = wait_until("the copy's daemon", time.monotonic() + 180, lambda: hot.find_socket(app, cli))
    receipt["daemon_socket"] = daemon
    globals_ = ["--socket", daemon, "--app-socket", control]
    receipt["readback"] = readback(cli, globals_, out, daemon, control)
    print(f"EXT_RELOAD_NIGHTLY readback {json.dumps(receipt['readback'])[:4000]}", flush=True)
    repaint_json = out / "edit-repaint.json"
    run = subprocess.run([sys.executable, str(ROOT / "scripts/cmux-next/edit-repaint.py"),
                          "--attach-socket", control, "--cli", str(cli), "--cli-socket", daemon,
                          "--config", args.config, "--customize", args.customize, "--mode", "readback",
                          "--window", "10", "--rounds", str(args.rounds), "--cases", args.cases,
                          "--out", str(out / "edit-repaint"), "--json", str(repaint_json)])
    try:
        repaint = json.loads(repaint_json.read_text())
    except (OSError, ValueError) as error:
        repaint = {"error": f"no edit-repaint.json: {error}"}
    receipt["edit_repaint_exit"] = run.returncode
    receipt["edit_repaint"] = {case: data.get("summary") for case, data in (repaint.get("cases") or {}).items()}
    receipt["installed"] = repaint.get("installed")
    seen_all = bool(receipt["edit_repaint"]) and all(
        (s or {}).get("n") == args.rounds for s in receipt["edit_repaint"].values())
    receipt["ok"] = bool(receipt["readback"].get("ok")) and seen_all and run.returncode == 0
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2))
    print("EXT_RELOAD_NIGHTLY " + json.dumps(receipt), flush=True)
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
