#!/usr/bin/env python3
"""The app half of scripts/measure/hot-apply-nightly.sh: apply SHA's Rust part to a running nightly
copy, check it, roll it back, check again, and print one receipt.

    hot-apply-nightly.py --app APP --sha SHA --pid-file F --out DIR

The copy's daemon gets two shells (one in each of two new workspaces). After the apply and after
the rollback, each must resolve as running with the same shell pid (`echo $$`), still show the
marker written before the apply, and echo new input; the app keeps its pid; bin/cmux hashes to
the published sha256 after the apply and to the nightly's own after the rollback. Exit 0 only when
every check passed.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOT = ROOT / "scripts/cmux-next/hot-apply.py"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


hot = load("hot_apply", HOT)
rust_live = load("rust_live", ROOT / "scripts/cmux-next/rust-live.py")
request, wait_until, shell_pid = rust_live.request, rust_live.wait_until, rust_live.shell_pid
bench = load("bench_launch", ROOT / "scripts/cmux-next/bench_launch.py")


def control_socket(app_pid: int) -> str | None:
    """The copy's control socket: a unix socket the app process holds under ~/.local/state/cmux (or
    its /tmp name) that answers system.ping. A side copy names it by its key hash, so it is read
    from the process, not computed."""
    held = subprocess.run(["lsof", "-a", "-p", str(app_pid), "-U", "-Fn"], capture_output=True, text=True).stdout
    for name in sorted({entry[1:] for entry in held.splitlines() if entry.startswith("n/")}):
        if name.endswith(".sock") and ("/.local/state/cmux/" in name or name.startswith("/tmp/cmux")):
            reply = bench.rpc_at(name, "system.ping", timeout=3)
            if not (isinstance(reply, dict) and reply.get("unreachable")):
                return name
    return None


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_hot(*args: str) -> tuple[int, dict | None]:
    done = subprocess.run([sys.executable, str(HOT), *args], capture_output=True, text=True)
    sys.stderr.write(done.stderr)
    lines = done.stdout.strip().splitlines()
    return done.returncode, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else None)


def version(cli: Path) -> str:
    return subprocess.run([str(cli), "--version"], capture_output=True, text=True).stdout.strip()


def shells_survive(sock: str, terms: list[dict], token: str) -> dict:
    """Each shell still runs (same shell pid), its marker is on screen, and new input echoes."""
    out = {}
    for t in terms:
        t["surface"] = wait_until("terminal", time.monotonic() + 40, lambda t=t: (
            x := request(Path(sock), {"cmd": "resolve-terminal", "terminal_id": t["terminal_id"]}))
            and x.get("lifecycle") == "running" and x.get("surface"))
        screen = request(Path(sock), {"cmd": "read-screen", "surface": t["surface"]}).get("text") or ""
        kept = t["marker"] in screen
        request(Path(sock), {"cmd": "send", "surface": t["surface"], "text": f"echo {token}-$((1+1)); echo PID1=$$\n"})
        screen = wait_until("echo", time.monotonic() + 15, lambda t=t: (
            s := request(Path(sock), {"cmd": "read-screen", "surface": t["surface"]}).get("text") or "")
            and f"{token}-2" in s and shell_pid(s, "PID1") and s)
        out[t["terminal_id"]] = {"same_shell": shell_pid(screen, "PID1") == t["shell_pid"], "marker_kept": kept}
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    cli = (app / hot.BIN / "cmux").resolve()
    receipt: dict = {"app_commit": hot.app_commit(app), "sha": args.sha, "checks": {}}
    t0 = time.monotonic()
    app_pid = int(Path(args.pid_file).read_text().strip())
    # A fresh copy starts its terminal daemon with its first terminal: open a workspace for one.
    control = wait_until("the copy's control socket", time.monotonic() + 120, lambda: control_socket(app_pid))
    opened = bench.rpc_at(control, "action.run", {"action": "workspace.newAtBottom"}, timeout=30)
    receipt["opened_workspace"] = not (isinstance(opened, dict) and opened.get("error"))
    try:
        sock = wait_until("the copy's daemon", time.monotonic() + 180, lambda: hot.find_socket(app, cli))
    except TimeoutError:
        # What ran from the copy and which sockets it held, so a miss can be read from the log.
        listing = subprocess.run(["ps", "-axww", "-o", "pid=,comm=,command="], capture_output=True, text=True).stdout
        print("HAN copy processes:\n" + "\n".join(l for l in listing.splitlines() if str(app) in l), file=sys.stderr)
        for pid in hot.app_pids(app):
            held = subprocess.run(["lsof", "-a", "-p", pid, "-U", "-Fn"], capture_output=True, text=True).stdout
            print(f"HAN pid {pid} unix sockets: {held.split()}", file=sys.stderr)
        raise
    receipt["daemon_ready_secs"] = round(time.monotonic() - t0, 1)
    receipt["nightly_sha256"] = before = sha256(cli)
    receipt["nightly_version"] = version(cli)

    terms = []
    for i in range(2):
        made = request(Path(sock), {"cmd": "run", "argv": ["/bin/sh"], "new_workspace": True})
        terms.append({"terminal_id": made["terminal_id"], "surface": made["surface"], "marker": f"hot-apply-{os.getpid()}-{i}"})
    for t in terms:
        request(Path(sock), {"cmd": "send", "surface": t["surface"], "text": f"echo {t['marker']}; echo PID$((0))=$$\n"})
    for t in terms:
        screen = wait_until("marker", time.monotonic() + 15, lambda t=t: (
            s := request(Path(sock), {"cmd": "read-screen", "surface": t["surface"]}).get("text") or "")
            and t["marker"] in s and shell_pid(s, "PID0") and s)
        t["shell_pid"] = shell_pid(screen, "PID0")

    code, applied = run_hot("apply", args.sha, "--app", str(app), "--socket", sock, "--parts", "rust")
    receipt["apply"] = applied
    rust = (applied or {}).get("steps", {}).get("rust", {})
    receipt["applied_version"] = version(cli)
    receipt["checks"]["apply_exit_0"] = code == 0
    receipt["checks"]["applied_rust"] = "rust" in (applied or {}).get("applied", [])
    receipt["checks"]["bin_is_published_sha"] = sha256(cli) == rust.get("to") and rust.get("to") != before
    receipt["checks"]["new_daemon_owner"] = bool(rust.get("new_pid")) and rust.get("new_pid") != rust.get("old_pid")
    receipt["after_apply_shells"] = shells_survive(sock, terms, "applied")

    code, rolled = run_hot("rollback", "--app", str(app), "--socket", sock)
    receipt["rollback"] = rolled
    back = (rolled or {}).get("steps", {}).get("rust", {})
    receipt["rolled_back_version"] = version(cli)
    receipt["checks"]["rollback_exit_0"] = code == 0
    receipt["checks"]["bin_is_nightly_sha_again"] = sha256(cli) == before
    receipt["checks"]["rollback_new_daemon_owner"] = bool(back.get("new_pid")) and back.get("new_pid") != back.get("old_pid")
    receipt["after_rollback_shells"] = shells_survive(sock, terms, "rolledback")

    for stage in ("after_apply_shells", "after_rollback_shells"):
        receipt["checks"][f"{stage}_kept"] = all(v["same_shell"] and v["marker_kept"] for v in receipt[stage].values())
    try:
        os.kill(app_pid, 0)
        receipt["checks"]["same_app_pid"] = True
    except OSError:
        receipt["checks"]["same_app_pid"] = False
    receipt["ok"] = all(receipt["checks"].values())
    receipt["seconds"] = round(time.monotonic() - t0, 1)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("HAN RECEIPT " + json.dumps(receipt))
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
