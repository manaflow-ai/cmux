#!/usr/bin/env python3
"""The app half of scripts/measure/ext-reload-nightly.sh: extension hot reload on a published NIGHTLY.

    ext-reload-nightly.py --app APP --pid-file F --customize DIR --config FILE --out DIR [--rounds N]

APP is a running side-instance copy of the NIGHTLY (its own bundle id, data, daemon and customize folder).
Two parts, both with the NIGHTLY's own bundled CLI and control socket, nothing from this checkout's build:

1. Read-back (`readback` in the receipt): `cmux ext dev --once --json` on a copy of
   examples/extensions/activity, then `cmux ext shot --json`, then a one-line save of its src/main.ts (the
   section title "No agent working" gets " (edited live)"), then `cmux ext shot --json` again. Passes when the
   first load is ok and the second scene differs from the first and holds the edited words.
2. Edit to repaint (`edit_repaint`): scripts/cmux-next/edit-repaint.py attached to the copy in read-back mode
   (a NIGHTLY has no debug.window_snapshot): the customize folder's section, rows and pane saved `--rounds`
   times each, a palette command and a key binding changed as often; each round timed to the save showing in
   the app (`apps.views`, `palette.query`, `keybinding.resolve`).

Prints `EXT_RELOAD_NIGHTLY {json}` (the receipt) and writes it to OUT/receipt.json. Exit 0 only when the
read-back passed and every round of every case was seen.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXAMPLE = ROOT / "examples/extensions/activity"
EDIT_FROM = '"No agent working"'
EDIT_TO = '"No agent working (edited live)"'


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


def control_socket(app_pid: int) -> str | None:
    """The copy's control socket: the one whose system.identify names the copy's pid (as hot-apply-nightly.py)."""
    import glob
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


def readback(cli: Path, globals_: list[str], work: Path) -> dict:
    """`ext dev --once --json`, `ext shot --json`, a one-line save, `ext shot --json`: the scene must change."""
    folder = work / "activity"
    if folder.exists():
        shutil.rmtree(folder)
    # A copy outside the checkout, as a person's would be: `ext dev` builds it with the SDK its own CLI
    # embeds (the NIGHTLY's), not this checkout's.
    shutil.copytree(EXAMPLE, folder, ignore=shutil.ignore_patterns("node_modules", "dist"))
    out: dict = {"folder": str(folder)}
    out["dev"] = cli_json(cli, globals_, ["ext", "dev", str(folder), "--once", "--json"])
    out["shot_before"] = cli_json(cli, globals_, ["ext", "shot", str(folder), "--json", "--out",
                                                  str(work / "shot-before.png")])
    main = folder / "src/main.ts"
    text = main.read_text()
    if EDIT_FROM not in text:
        out["error"] = f"src/main.ts has no {EDIT_FROM} to edit"
        out["ok"] = False
        return out
    started = time.monotonic()
    main.write_text(text.replace(EDIT_FROM, EDIT_TO, 1))
    out["shot_after"] = cli_json(cli, globals_, ["ext", "shot", str(folder), "--json", "--out",
                                                 str(work / "shot-after.png")])
    out["save_to_shot_ms"] = round((time.monotonic() - started) * 1000)
    before, after = scene_of(out["shot_before"]), scene_of(out["shot_after"])
    out["scene_before"], out["scene_after"] = before[:40], after[:40]
    edited = EDIT_TO.strip('"')
    out["checks"] = {
        "dev_ok": out["dev"].get("exit") == 0,
        "scene_before": bool(before),
        "scene_changed": bool(after) and after != before,
        "scene_shows_edit": any(edited in json.dumps(line) for line in after),
    }
    out["ok"] = all(out["checks"].values())
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
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cli = (app / hot.BIN / "cmux").resolve()
    app_pid = int(Path(args.pid_file).read_text().strip())
    receipt: dict = {"host": os.uname().nodename, "app": str(app), "app_commit": hot.app_commit(app),
                     "version": subprocess.run([str(cli), "--version"], capture_output=True, text=True).stdout.strip()}
    control = wait_until("the copy's control socket", time.monotonic() + 120, lambda: control_socket(app_pid))
    receipt["control_socket"] = control
    # A workspace with a terminal starts the copy's daemon (a new workspace opens on the native New Tab page).
    bench.rpc_at(control, "action.run", {"action": "workspace.newAtBottom"}, timeout=30)
    bench.rpc_at(control, "action.run", {"action": "newSurface"}, timeout=30)
    daemon = wait_until("the copy's daemon", time.monotonic() + 180, lambda: hot.find_socket(app, cli))
    receipt["daemon_socket"] = daemon
    globals_ = ["--socket", daemon, "--app-socket", control]
    receipt["readback"] = readback(cli, globals_, out)
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
