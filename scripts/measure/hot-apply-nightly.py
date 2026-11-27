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
sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'cmux-next'))
try:
    from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)
except ImportError:  # a copy of this script outside scripts/: the same helper (scripts/cmux-next/safe_log.py)
    def safe_print(*args, **kwargs):
        try:
            print(*args, **kwargs)
        except (BrokenPipeError, OSError, ValueError):
            pass

ROOT = Path(__file__).resolve().parents[2]
HOT = ROOT / "scripts/cmux-next/hot-apply.py"
OTHER = "hotapply-other"  # the second session (sessions=1), as a Chief's beside the app's own


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
    """The copy's control socket. lsof does not show it (try-pr-live-code.sh), and a side copy names it
    by its key hash, so every cmux control socket is asked system.identify and the one that answers
    with the copy's pid is it. The step has its own HOME; the copy, opened through Launch Services,
    keeps the account's, so both are searched."""
    import glob
    homes = dict.fromkeys([bench.account_home(), os.path.expanduser("~")])
    socks = set(glob.glob("/tmp/cmux-*.sock"))
    for home in homes:
        socks.update(glob.glob(os.path.join(home, ".local/state/cmux/*.sock")))
    for sock in sorted(socks):
        reply = bench.rpc_at(sock, "system.identify", timeout=5)
        if isinstance(reply, dict) and reply.get("pid") == app_pid:
            return sock
    return None


def explain_miss(app: Path, app_pid: int, control: str) -> None:
    """What the copy started and which unix sockets it holds, so a daemon that was never found can be
    read from the log: every process under the app's own and every cmux-named one, whatever path
    form ps prints for it, and the app's own record of its daemon requests."""
    rows = []
    for line in subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,comm=,command="], capture_output=True,
                               text=True).stdout.splitlines():
        pid, ppid, rest = (line.split(None, 2) + ["", ""])[:3]
        rows.append((pid, ppid, rest))
    tree, grew = {str(app_pid)}, True
    while grew:
        grew = False
        for pid, ppid, _ in rows:
            if ppid in tree and pid not in tree:
                tree.add(pid)
                grew = True
    for pid, ppid, rest in rows:
        if pid in tree or "cmux" in rest.lower():
            held = subprocess.run(["lsof", "-a", "-p", pid, "-U", "-Fn"], capture_output=True, text=True).stdout
            paths = sorted({l[1:] for l in held.splitlines() if l.startswith("n/")})
            print(f"HAN proc {pid} ppid {ppid} {'(app tree) ' if pid in tree else ''}{rest[:300]} sockets {paths}",
                  file=sys.stderr)
    requests = bench.rpc_at(control, "debug.daemon_requests", timeout=10)
    print(f"HAN debug.daemon_requests answered {json.dumps(requests)[:2000]}", file=sys.stderr, flush=True)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_hot(*args: str) -> tuple[int, dict | None]:
    done = subprocess.run([sys.executable, str(HOT), *args], capture_output=True, text=True)
    sys.stderr.write(done.stderr)
    lines = done.stdout.strip().splitlines()
    return done.returncode, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else None)


def version(cli: Path) -> str:
    return subprocess.run([str(cli), "--version"], capture_output=True, text=True).stdout.strip()


HOST_MARKS = ("cmux-tui-host", "__terminal-host", "cmux-holder", "__holder")


def processes() -> list[dict]:
    rows = []
    for line in subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,command="], capture_output=True,
                               text=True).stdout.splitlines():
        pid, ppid, command = (line.split(None, 2) + ["", ""])[:3]
        if pid.isdigit():
            rows.append({"pid": int(pid), "ppid": int(ppid), "command": command})
    return rows


def terminal_hosts(app: Path, terms: list[dict]) -> dict:
    """The copy's terminal-host processes (pid, ppid, command) and the host each shell runs under (its
    parent): a host no shell runs under is the standby spare the daemon keeps for its next terminal."""
    rows = processes()
    hosts = [r for r in rows if str(app) in r["command"] and any(m in r["command"] for m in HOST_MARKS)]
    parent = {r["pid"]: r["ppid"] for r in rows}
    shells = {t["terminal_id"]: {"shell_pid": t["shell_pid"], "host_pid": parent.get(int(t["shell_pid"] or 0))}
              for t in terms}
    serving = {v["host_pid"] for v in shells.values()}
    return {"hosts": [dict(h, command=h["command"][:300], serves_a_shell=h["pid"] in serving) for h in hosts],
            "shells": shells}


def same_hosts(before: dict, after: dict) -> bool:
    """Every shell runs under the host it ran under before, and that host is still up."""
    up = {h["pid"] for h in after["hosts"]}
    return all(after["shells"].get(t, {}).get("host_pid") == v["host_pid"] and v["host_pid"] in up
               for t, v in before["shells"].items())


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
    parser.add_argument("--prefetch", action="store_true", help="run `hot-apply.py prefetch SHA` before the apply")
    parser.add_argument("--sessions", action="store_true",
                        help="a second session's daemon from the copy's bin (as a Chief's) with a shell, and "
                             "`apply --restart-sessions`: it must be handed over and back with its shell kept")
    args = parser.parse_args()
    app, out = Path(args.app), Path(args.out)
    cli = (app / hot.BIN / "cmux").resolve()
    receipt: dict = {**hot.app_commit_receipt(app), "sha": args.sha, "checks": {}}
    t0 = time.monotonic()
    app_pid = int(Path(args.pid_file).read_text().strip())
    # A fresh copy starts its terminal daemon with its first terminal. A new workspace opens on the
    # New Tab page, which is native, so a terminal tab is asked for in it (as live-mode-swift.py seeds).
    control = wait_until("the copy's control socket", time.monotonic() + 120, lambda: control_socket(app_pid))
    opened = bench.rpc_at(control, "action.run", {"action": "workspace.newAtBottom"}, timeout=30)
    safe_print(f"HAN workspace.newAtBottom answered {json.dumps(opened)[:400]}", file=sys.stderr, flush=True)
    workspace = next((str(i) for i in (opened or {}).get("created") or [] if str(i).startswith("ws_")), None) \
        if isinstance(opened, dict) else None
    went = bench.rpc_at(control, "action.run", {"action": "goToWorkspace", "args": {"workspace": workspace}},
                        timeout=30) if workspace else {"error": "workspace.newAtBottom created no workspace"}
    safe_print(f"HAN goToWorkspace answered {json.dumps(went)[:400]}", file=sys.stderr, flush=True)
    surface = bench.rpc_at(control, "action.run", {"action": "newSurface"}, timeout=30)
    safe_print(f"HAN newSurface answered {json.dumps(surface)[:400]}", file=sys.stderr, flush=True)
    replies = (opened, went, surface)
    receipt["checks"]["opened_terminal"] = all(isinstance(r, dict) and "error" not in r for r in replies)
    receipt["opened_replies"] = {"workspace": opened, "went": went, "terminal": surface}
    try:
        sock = wait_until("the copy's daemon", time.monotonic() + 180, lambda: hot.find_socket(app, cli))
    except TimeoutError:
        explain_miss(app, app_pid, control)
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

    other = None
    if args.sessions:
        # Another session's owner from the same bin, as the app runs its Chief's: started by the copy's CLI.
        ensured = subprocess.run([str(cli), "--session", OTHER, "--json", "server", "ensure"], capture_output=True,
                                 text=True, timeout=60)
        started = json.loads(ensured.stdout or "{}")
        other = {"socket": started.get("socket"), "pid": started.get("pid")}
        receipt["other_session"] = dict(other)
        receipt["checks"]["other_session_started"] = bool(other["socket"] and other["pid"])
        made = request(Path(other["socket"]), {"cmd": "run", "argv": ["/bin/sh"], "new_workspace": True})
        other["terms"] = [{"terminal_id": made["terminal_id"], "surface": made["surface"],
                           "marker": f"hot-apply-{os.getpid()}-other"}]
        for t in other["terms"]:
            request(Path(other["socket"]), {"cmd": "send", "surface": t["surface"],
                                            "text": f"echo {t['marker']}; echo PID$((0))=$$\n"})
            screen = wait_until("marker", time.monotonic() + 15, lambda t=t: (
                s := request(Path(other["socket"]), {"cmd": "read-screen", "surface": t["surface"]}).get("text") or "")
                and t["marker"] in s and shell_pid(s, "PID0") and s)
            t["shell_pid"] = shell_pid(screen, "PID0")

    def handed(done: dict | None) -> dict:
        """The other session's row in a receipt's rust step: handed to a new owner, with its time."""
        rows = [r for r in ((done or {}).get("steps", {}).get("rust", {}).get("sessions") or [])
                if r.get("socket") == other["socket"]]
        return rows[0] if rows else {}

    receipt["terminal_hosts"] = {"before_apply": terminal_hosts(app, terms)}
    if args.prefetch:
        # As once CI publishes SHA: everything apply needs is fetched and checked first, so the apply only swaps.
        code, fetched = run_hot("prefetch", args.sha, "--app", str(app))
        receipt["prefetch"] = {"exit": code, "seconds": (fetched or {}).get("seconds"),
                               "phases": (fetched or {}).get("phases")}
    code, applied = run_hot("apply", args.sha, "--app", str(app), "--socket", sock, "--parts", "rust",
                            *(["--restart-sessions"] if other else []))
    receipt["apply"] = applied
    rust = (applied or {}).get("steps", {}).get("rust", {})
    receipt["applied_version"] = version(cli)
    receipt["checks"]["apply_exit_0"] = code == 0
    receipt["checks"]["applied_rust"] = "rust" in (applied or {}).get("applied", [])
    receipt["checks"]["bin_is_published_sha"] = sha256(cli) == rust.get("to") and rust.get("to") != before
    receipt["checks"]["new_daemon_owner"] = bool(rust.get("new_pid")) and rust.get("new_pid") != rust.get("old_pid")
    receipt["after_apply_shells"] = shells_survive(sock, terms, "applied")
    receipt["terminal_hosts"]["after_apply"] = terminal_hosts(app, terms)
    receipt["checks"]["apply_keeps_each_shell_s_host"] = same_hosts(receipt["terminal_hosts"]["before_apply"],
                                                                    receipt["terminal_hosts"]["after_apply"])
    if other:
        row = handed(applied)
        receipt["other_session_apply"] = row
        receipt["checks"]["other_session_handed_over"] = bool(row.get("new_pid")) and row.get("new_pid") != other["pid"]
        receipt["after_apply_other_shells"] = shells_survive(other["socket"], other["terms"], "applied")

    code, rolled = run_hot("rollback", "--app", str(app), "--socket", sock)
    receipt["rollback"] = rolled
    back = (rolled or {}).get("steps", {}).get("rust", {})
    receipt["rolled_back_version"] = version(cli)
    receipt["checks"]["rollback_exit_0"] = code == 0
    receipt["checks"]["bin_is_nightly_sha_again"] = sha256(cli) == before
    receipt["checks"]["rollback_new_daemon_owner"] = bool(back.get("new_pid")) and back.get("new_pid") != back.get("old_pid")
    receipt["after_rollback_shells"] = shells_survive(sock, terms, "rolledback")
    receipt["terminal_hosts"]["after_rollback"] = terminal_hosts(app, terms)
    receipt["checks"]["rollback_keeps_each_shell_s_host"] = same_hosts(receipt["terminal_hosts"]["before_apply"],
                                                                       receipt["terminal_hosts"]["after_rollback"])
    if other:
        row = handed(rolled)
        receipt["other_session_rollback"] = row
        receipt["checks"]["other_session_handed_back"] = bool(row.get("new_pid")) and \
            row.get("new_pid") != (receipt["other_session_apply"] or {}).get("new_pid")
        receipt["after_rollback_other_shells"] = shells_survive(other["socket"], other["terms"], "rolledback")
        subprocess.run([str(cli), "--session", OTHER, "server", "stop", "--end-terminals"], capture_output=True,
                       timeout=60)

    for stage in ("after_apply_shells", "after_rollback_shells") + (
            ("after_apply_other_shells", "after_rollback_other_shells") if other else ()):
        receipt["checks"][f"{stage}_kept"] = all(v["same_shell"] and v["marker_kept"] for v in receipt[stage].values())
    try:
        os.kill(app_pid, 0)
        receipt["checks"]["same_app_pid"] = True
    except OSError:
        receipt["checks"]["same_app_pid"] = False
    receipt["ok"] = all(receipt["checks"].values())
    receipt["seconds"] = round(time.monotonic() - t0, 1)
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    safe_print("HAN RECEIPT " + json.dumps(receipt))
    return 0 if receipt["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
