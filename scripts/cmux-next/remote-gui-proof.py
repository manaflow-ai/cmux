#!/usr/bin/env python3
"""cmux NEXT Remote over SSH, driven in the app's GUI on a throwaway Mac (remote-gui-proof.yml).

    remote-gui-proof.py --app APP --tag TAG --host-dir DIR --out OUT [--drop-seconds S]

Leo, 2026-11-10: "we're not a terminal-first app anymore. cmux-next is a gui." This launches the NEXT DEV
app on its own control socket, in light mode, and walks a person's Remote journey through the app's own
UI: every press is a synthesized key or mouse event in the app's window (debug.key, debug.mouse,
debug.page click/type), never a CLI shortcut, except where a step says it fell back and why.

  1. add the SSH host: Add Device > Add Machine, the field `e2ehost` (remote-gui-proof-host.sh's alias for
     rhost@127.0.0.1), Return; until the card's run says ready
  2. a new chat on that host: the composer's environment picker, the host, a prompt; the stand-in claude
     answers PONG. Timed: pick host -> first reply
  3. move a started chat there and back (Move to...)
  4. drop the network (pf on lo0 for the sshd's port), wait, restore it, send again. Timed: restore ->
     the chat answers again (and drop -> answer)

Each step saves the app window (debug.window_snapshot, which needs no Screen Recording grant) as
OUT/NN-step.png. OUT/evidence.json has every step (ok, ms, detail, and the exact text of anything that
went wrong: a snag); OUT/summary.md is the run summary. Exit 0 when every step passed.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--host-dir", required=True, help="remote-gui-proof-host.sh's DIR")
parser.add_argument("--out", required=True)
parser.add_argument("--alias", default="e2ehost")
parser.add_argument("--drop-seconds", type=float, default=30)
args = parser.parse_args()

HERE = Path(__file__).resolve().parent
OUT = Path(args.out)
OUT.mkdir(parents=True, exist_ok=True)
APP = Path(args.app).resolve()
CLI = APP / "Contents/Resources/bin/cmux"
SOCK = f"/tmp/cmux-rgp-{args.tag}.sock"
ENV = {**os.environ, "CMUX_NEXT_SOCKET_PATH": SOCK}
PROMPT = "Reply with exactly: PONG"
REPLY = "PONG"
T0 = time.monotonic()
evidence: dict = {"tag": args.tag, "app": str(APP), "alias": args.alias, "steps": [], "snags": [], "times_ms": {}}
shot_no = [0]


def now_ms() -> int:
    return round((time.monotonic() - T0) * 1000)


def log(*parts) -> None:
    print(f"[{now_ms() / 1000:8.1f}s]", *parts, flush=True)


def save() -> None:
    (OUT / "evidence.json").write_text(json.dumps(evidence, indent=2))


def snag(text: str, **extra) -> None:
    """A finding: an error message, a loading state, a slow step. Its exact text and the time."""
    row = {"at_ms": now_ms(), "text": str(text)[:2000], **extra}
    evidence["snags"].append(row)
    log("SNAG", json.dumps(row)[:600])
    save()


def step(name: str, ok: bool, **detail) -> bool:
    row = {"step": name, "ok": ok, "at_ms": now_ms(), **detail}
    evidence["steps"].append(row)
    log("STEP", "ok" if ok else "FAIL", json.dumps(row)[:800])
    save()
    return ok


def rpc(method: str, params: dict | None = None, timeout: float = 30) -> dict:
    """One request on the app's control socket: its result, or {"error": ...}."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(SOCK)
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = sock.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0])
    except (OSError, ValueError) as error:
        return {"error": f"{type(error).__name__}: {error}"}
    if reply.get("ok") is False or reply.get("error"):
        return {"error": reply.get("error")}
    result = reply.get("result")
    return result if isinstance(result, dict) else {"value": result}


def cli(*words: str, timeout: float = 120) -> tuple[int, str, str]:
    try:
        done = subprocess.run([str(CLI), *words], env=ENV, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired as error:
        return 124, (error.stdout or b"").decode(errors="replace") if isinstance(error.stdout, bytes) else (error.stdout or ""), f"timed out after {timeout}s"


def action(name: str, action_args: dict | None = None) -> dict:
    params: dict = {"action": name, "focus": True}
    if action_args:
        params["args"] = action_args
    return rpc("action.run", params, timeout=60)


def shot(name: str) -> str | None:
    shot_no[0] += 1
    path = OUT / f"{shot_no[0]:02d}-{name}.png"
    reply = rpc("debug.window_snapshot", {"path": str(path)}, timeout=30)
    if reply.get("error") or not path.exists():
        snag(f"still {name}: {reply.get('error') or reply}")
        return None
    log("still", path.name)
    return path.name


def page(page_id: str | None, act: str, **params) -> dict:
    body = {"action": act, **params}
    if page_id:
        body["page"] = page_id
    return rpc("debug.page", body, timeout=95 if act == "wait" else 30)


def key(name: str, modifiers: list[str] | None = None) -> dict:
    reply = rpc("debug.key", {"key": name, "modifiers": modifiers or []})
    time.sleep(0.15)  # harness: the key lands
    return reply


def host_sh(cmd: str) -> None:
    subprocess.run([str(HERE / "remote-gui-proof-host.sh"), cmd, args.host_dir], check=True)


def wait_until(what: str, probe, timeout: float, interval: float = 0.25):
    """probe() -> truthy value when done. Returns (value, ms) or (None, ms) at the deadline."""
    start = time.monotonic()
    while True:
        value = probe()
        if value:
            return value, round((time.monotonic() - start) * 1000)
        if time.monotonic() - start > timeout:
            return None, round((time.monotonic() - start) * 1000)
        time.sleep(interval)  # harness: the app has no push channel for a script


# --- launch -------------------------------------------------------------------------------------------------

def launch() -> bool:
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    subprocess.Popen(["/usr/bin/open", "-n", "--env", f"CMUX_NEXT_SOCKET_PATH={SOCK}", str(APP)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pong, ms = wait_until("socket", lambda: (lambda r: r if not r.get("error") else None)(rpc("system.ping", timeout=5)), 180, 1)
    if not pong:
        return step("launch", False, ms=ms, error=rpc("system.ping").get("error"))
    step("launch", True, ms=ms)
    appearance = rpc("debug.appearance", {"mode": "light"})
    if appearance.get("error"):
        snag(f"debug.appearance light: {appearance['error']}")
    time.sleep(2)  # harness: the first window settles
    shot("launched")
    return True


def dump_state(label: str) -> None:
    """What the app shows now, for the findings: windows and every live page's visible text."""
    windows = rpc("debug.window_list")
    (OUT / f"state-{label}-windows.json").write_text(json.dumps(windows, indent=2)[:200000])
    pages = {}
    for pid in ("cmux.serverCards", "cmux.server-cards", "cmux.agent", "cmux.newTab", "cmux.home", None):
        state = page(pid, "state")
        pages[str(pid)] = {k: state.get(k) for k in ("page", "id", "url", "fragment", "text", "error") if k in state}
    (OUT / f"state-{label}-pages.json").write_text(json.dumps(pages, indent=2)[:400000])


# --- 1. add the host ----------------------------------------------------------------------------------------

def add_host() -> bool:
    start = time.monotonic()
    reply = action("device.add")
    if reply.get("error"):
        snag(f"action device.add: {reply['error']}")
    time.sleep(1.5)
    shot("add-device")
    dump_state("add-device")
    reply = action("machine.add", {"destination": args.alias})
    if reply.get("error"):
        snag(f"action machine.add: {reply['error']}")
    time.sleep(1.5)
    shot("add-machine-filled")
    dump_state("add-machine")
    key("return")
    time.sleep(1)
    shot("add-machine-running")

    def connected():
        code, out, _ = cli("acp", "host", "ls", "--json", timeout=20)
        if code == 0 and args.alias in out and '"connected"' in out:
            return out
        return None

    out, ms = wait_until("host connected", connected, 300, 1)
    shot("add-machine-done")
    dump_state("add-machine-done")
    code, ls_out, ls_err = cli("acp", "host", "ls", "--json", timeout=20)
    (OUT / "acp-host-ls.json").write_text(ls_out or ls_err)
    total = round((time.monotonic() - start) * 1000)
    evidence["times_ms"]["add_host"] = total
    return step("add host (Add Machine card)", bool(out), ms=total, host_ls=(ls_out or ls_err)[:1500])


def main() -> int:
    save()
    try:
        if not launch():
            return 1
        add_host()
        # Recon for the later steps: the CLI's surface on this build.
        for words in (("--version",), ("acp", "--help"), ("acp", "host", "--help"), ("setup", "machine", "--help")):
            code, out, err = cli(*words, timeout=30)
            (OUT / ("cli-" + "-".join(w.strip("-") for w in words) + ".txt")).write_text(f"exit {code}\n{out}\n{err}")
    finally:
        lines = ["## Remote GUI proof", "", "| step | ok | ms |", "| --- | --- | --- |"]
        lines += [f"| {s['step']} | {'yes' if s['ok'] else 'no'} | {s.get('ms', '')} |" for s in evidence["steps"]]
        lines += ["", "Times (ms): `" + json.dumps(evidence["times_ms"]) + "`", "", "### Snags", ""]
        lines += [f"- {s['at_ms'] / 1000:.1f}s: `{s['text'][:300]}`" for s in evidence["snags"]] or ["- none"]
        (OUT / "summary.md").write_text("\n".join(lines) + "\n")
        save()
        rpc("action.run", {"action": "quitEndEverything"}, timeout=20)
    return 0 if evidence["steps"] and all(s["ok"] for s in evidence["steps"]) else 1


if __name__ == "__main__":
    sys.exit(main())
