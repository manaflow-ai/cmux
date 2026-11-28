#!/usr/bin/env python3
"""Does a "New Tab" tab on the published NIGHTLY ever draw the bare agent chat view? (ask-acaf57cddd)

Leo: "for some reason the new tab page is sometimes opening as just [the empty chat view] idk some agent chat
view? some weird conflict situatoin". Downloads the newest signed NIGHTLY (crash-notice-nightly.py's fetch),
runs each sequence in its own fresh private launch through the same registry actions the shortcuts fire
(newTab = Cmd-T, closeTab = Cmd-W, nextSurface = Ctrl-Tab, selectSurfaceByNumber = Cmd-1, newWindow = Cmd-N),
and after every step keeps a window shot plus the selected tab of each pane (snapshot.get) in
.build/newtab-chat-view-nightly/. Ends with the unified-log lines about the New Tab page.
Run: cmux-ci run --class exclusive --label measure --display --script scripts/measure/newtab-chat-view-nightly.sh
  --ref SHA --artifact .build/newtab-chat-view-nightly/report.tgz --timeout 3600
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".build/newtab-chat-view-nightly"

T = ("newTab",)
W = ("closeTab",)
NEXT = ("nextSurface",)
FIRST = ("selectSurfaceByNumber", {"index": 1})
N = ("newWindow",)
CHAT = ("palette.newAgentChat",)

SEQUENCES = {
    "a": [T, T, FIRST],
    "b": [T, T, T, T, T, NEXT, NEXT, NEXT, NEXT, NEXT, NEXT],
    "c": [T, W, T, T, FIRST],
    "d": [CHAT, T, T, ("selectSurfaceByNumber", {"index": 2})],
    "e": [N, T, FIRST],
}


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


crash = module("crash_notice_nightly", ROOT / "scripts/measure/crash-notice-nightly.py")
hv = module("hot_verify", ROOT / "scripts/cmux-next/hot-verify.py")


def panes(sock: str) -> list[dict]:
    """Each visible window's panes: the selected tab's kind and title, and the tab titles."""
    topology = hv.rpc(sock, "snapshot.get", timeout=10).get("topology") or {}
    shown = {w.get("workspace") for w in topology.get("windows") or [] if isinstance(w, dict) and w.get("visible")}
    rows = []
    for workspace in topology.get("workspaces") or []:
        if not isinstance(workspace, dict) or (shown and workspace.get("id") not in shown):
            continue
        for screen in workspace.get("screens") or []:
            for pane in (screen or {}).get("panes") or []:
                tabs = [t for t in (pane or {}).get("tabs") or [] if isinstance(t, dict)]
                sel = next((t for t in tabs if t.get("id") == pane.get("selected_tab")), {})
                rows.append({"selected": {"kind": sel.get("kind"), "title": sel.get("title"), "id": sel.get("id")},
                             "tabs": [f"{t.get('kind')}:{t.get('title')}" for t in tabs]})
    return rows


def shoot(pid: int, path: Path) -> str:
    try:
        return hv.Shooter()(pid, path)
    except Exception as error:  # noqa: BLE001
        subprocess.run(["screencapture", "-x", str(path)], capture_output=True, timeout=30)
        return f"display ({error})"[:200]


def run_sequence(name: str, steps: list, app: Path, env: dict) -> dict:
    work = Path(tempfile.mkdtemp(prefix=f"newtab-{name}-"))
    (work / "state").mkdir()
    (work / "cmux-next.json").write_text(json.dumps({"browser": {"defaultEngine": "webkit"}}) + "\n")
    rows, launch = [], None
    try:
        launch = crash.Launch(app, work, env)
        sock = launch.values["CMUX_NEXT_SOCKET_PATH"]
        time.sleep(6)
        shot = OUT / name / "00-launch.png"
        rows.append({"step": "launch", "shot": str(shot.relative_to(OUT)), "how": shoot(launch.pid, shot),
                     "panes": panes(sock)})
        for index, step in enumerate(steps, 1):
            action, args = step[0], (step[1] if len(step) > 1 else None)
            params = {"action": action, "focus": True, **({"args": args} if args else {})}
            answer = hv.rpc(sock, "action.run", params)
            time.sleep(0.4 if name == "b" and action == "newTab" else 2.0)
            shot = OUT / name / f"{index:02d}-{action}.png"
            rows.append({"step": action, "args": args, "answer": answer, "shot": str(shot.relative_to(OUT)),
                         "how": shoot(launch.pid, shot), "panes": panes(sock)})
        time.sleep(2)
        shot = OUT / name / "99-settled.png"
        rows.append({"step": "settled", "shot": str(shot.relative_to(OUT)), "how": shoot(launch.pid, shot),
                     "panes": panes(sock), "debug_new_tab": hv.rpc(sock, "debug.new_tab", {}, timeout=5)})
        return {"rows": rows, "since": launch.started.isoformat()}
    except Exception as error:  # noqa: BLE001
        return {"rows": rows, "error": f"{type(error).__name__}: {error}"[:300]}
    finally:
        if launch and launch.launcher.poll() is None:
            launch.end(signal.SIGTERM)
        shutil.rmtree(work, ignore_errors=True)  # this run alone made it


def log_lines(since: dt.datetime) -> list[str]:
    start = since.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    reply = subprocess.run(["log", "show", "--style", "compact", "--start", start, "--predicate",
                            'subsystem CONTAINS "cmux"'], capture_output=True, text=True, timeout=300)
    keys = ("newtab", "new tab", "spare", "adopt", "idle", "recycle")
    return [line[:300] for line in reply.stdout.splitlines() if any(k in line.lower() for k in keys)][-400:]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    started = dt.datetime.now(dt.timezone.utc)
    result: dict = {"at": started.strftime("%Y-%m-%dT%H:%M:%SZ")}
    work = Path(tempfile.mkdtemp(prefix="newtab-app-"))
    try:
        app, selected = crash.fetch(work)
        result.update(build=selected["build"], version=selected.get("version"), commit=selected.get("commit"))
        print("NTCV app " + json.dumps(result), flush=True)
        env = module("app_launch_env", ROOT / "scripts/cmux-next/app_launch_env.py").launch_env(os.environ)
        env = {k: v for k, v in env.items()
               if not k.startswith(("CMUX_UITEST_", "CMUX_DOGFOOD_", "CMUX_GITHUB_TEST_", "CMUX_AUTH_"))}
        result["sequences"] = {}
        for name, steps in SEQUENCES.items():
            seq = run_sequence(name, steps, app, env)
            result["sequences"][name] = seq
            for row in seq["rows"]:
                print(f"NTCV {name} {row['step']} {json.dumps(row.get('panes'))[:400]} answer={json.dumps(row.get('answer'))[:120]}",
                      flush=True)
            if seq.get("error"):
                print(f"NTCV {name} error {seq['error']}", flush=True)
        result["log"] = log_lines(started)
        (OUT / "log.txt").write_text("\n".join(result["log"]) + "\n")
    except Exception as error:  # noqa: BLE001
        result["error"] = f"{type(error).__name__}: {error}"[:300]
        print("NTCV error " + result["error"], flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    (OUT / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if not result.get("error") else 2


if __name__ == "__main__":
    raise SystemExit(main())
