#!/usr/bin/env python3
"""Austin's day, host side: puts Austin's 2026-10-29 load on a running tagged cmux app and measures it.

  driver.py --socket APP_SOCK --app CLONE.app --fixture ROOT --out DIR --seconds N [options]

Run by austins-day.sh on the leased mini (never by hand on a person's Mac). The app runs in a
capture slot; this script talks to it only through its control socket, its bundled CLI and its
acpmux socket, and to the host through sysctl, ps, top and log.

Load (issues #27698, #27702, #27693; Austin: ~80 terminal agents, load 150-252, swap 17 of 18 GB,
one shared .git with 19,110 packs, 25-chat Chief waves):
- --agents terminal agents (default 80), --per-workspace per workspace, each a `claude` run in a
  real cmux terminal through the cmux shim and wrapper (fake_claude.py stands in for Claude Code
  and runs the hooks the wrapper gave it on every tool call and stop, and calls the `cmux` CLI);
  their folders are worktrees of the fixture's partial clone with thousands of packs (packs.py);
- a Chief wave every --wave-period seconds: --wave-size acpmux sessions opened at once on the
  app's acpmux with the acpmux test agent, each with a streamed prompt;
- memory pressure: hog.py grows until swap used is --swap-gb above the start (bounded, it gives
  memory back near the edge, ends at the deadline);
- every --close-every seconds a new workspace is made and closed through the app's own
  closeWorkspace action (the sidebar's close), and the time until the app and the daemon drop it.

Measures, over the load phase (distributions as p50/p95/p99/max and counts):
- app_requests: the app's own daemon requests, send to reply (`debug.daemon_requests`, the app
  probe; absent in builds without it) and the app's "no reply within" timeouts from its log;
- person_cli: a `cmux` CLI read from outside any terminal once a second (time, refusals by code);
- agent hooks, tool calls and CLI calls from the agents' logs (time, refusals by code);
- daemon: server-stats (connections accepted/refused/peak, registry lock wait and hold, writer);
- workspace_close: time to gone in the app's topology and in the daemon's list;
- acpmux: session/new and prompt latency, errors, restarts (daemon pid changes, app log lines);
- memory: RSS and footprint over time for the app, the daemon and acpmux; load average and swap;
- stalls: debug.hangs at the end; every stall over 100 ms with a cmux frame, by its top cmux symbol.
Writes OUT/run.json (all of it) and prints `AUSTINS-DAY {short json}`.
"""
import argparse
import importlib.util
import json
import os
import random
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
STALL_MS = 100.0
ERROR_CODE = re.compile(r'"code"\s*:\s*"([a-z_]+\.[a-z_.]+)"|\b((?:server|session)\.[a-z_]+)\b')

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--socket", required=True, help="the app's control socket")
parser.add_argument("--app", required=True, help="the app bundle the slot runs (its bundled CLI and acpmux)")
parser.add_argument("--fixture", required=True, help="packs.py build ROOT")
parser.add_argument("--out", required=True)
parser.add_argument("--seconds", type=float, default=300, help="load phase length")
parser.add_argument("--agents", type=int, default=80)
parser.add_argument("--per-workspace", type=int, default=4)
parser.add_argument("--tool-gap", type=float, default=3.0, help="mean seconds between an agent's tool calls")
# Main arm (lead 2026-10-30): no agent `cmux` CLI calls. No shipped hook, plugin or status line calls `cmux
# workspace list` per turn (hooks send only session.journal.append), so the old default of one per 3 tool
# calls had no evidence and drove 43 % of the registry lock busy share. `--cli-every 3` is kept as the
# labeled "assumed" sensitivity arm.
parser.add_argument("--cli-every", type=int, default=0, help="an agent `cmux` CLI call every N tool calls (0: none, the main arm)")
parser.add_argument("--wave-size", type=int, default=25)
parser.add_argument("--wave-period", type=float, default=60)
parser.add_argument("--swap-gb", type=float, default=14.0, help="hog target: swap used this much above the start (0: no hog)")
parser.add_argument("--stream-cps", type=float, default=300, help="characters a second each agent streams to its terminal")
parser.add_argument("--cpu", type=float, default=0.15, help="share of one core each agent keeps busy while it thinks")
parser.add_argument("--close-every", type=float, default=30)
parser.add_argument("--baseline", type=float, default=10, help="seconds measured before the load starts")
parser.add_argument("--label", default="")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
T0 = time.time()
LOCK = threading.Lock()
STOP = threading.Event()
SERIES = {"samples": [], "server_stats": [], "holders": [], "locks": [], "person_cli": [], "app_control": [], "closes": [], "waves": [],
          "acpmux_pids": [], "notes": []}


def say(text):
    line = f"[{time.time() - T0:7.1f}s] {text}"
    print(line, flush=True)
    with open(os.path.join(opts.out, "driver.log"), "a") as f:
        f.write(line + "\n")


def note(text):
    with LOCK:
        SERIES["notes"].append(text)
    say(f"NOTE {text}")


def record(key, value):
    with LOCK:
        SERIES[key].append(value)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


build_names = load_module("build_names", os.path.join(HERE, "build_names.py"))


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def sh(argv, timeout=30):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired:
        return "timeout", "", ""
    except OSError as error:
        return "oserror", "", str(error)


# ---- the app, its daemon, its acpmux --------------------------------------------------------

identity = rpc("system.identify", timeout=20)
if not isinstance(identity, dict) or not identity.get("pid"):
    raise SystemExit(f"austins-day: the app does not answer on {opts.socket}: {identity}")
APP_PID = int(identity["pid"])
CLI = os.path.join(opts.app, "Contents", "Resources", "bin", "cmux")
# `client` (and `raw`) are scopes only the cmux-tui name accepts (cli.rs CMUX_TUI_ONLY_SCOPES): `cmux client
# list` is refused as usage.invalid by design. The app bundles cmux-tui beside cmux.
CLI_TUI = os.path.join(opts.app, "Contents", "Resources", "bin", "cmux-tui")


def app_env():
    out = sh(["ps", "eww", "-o", "command=", "-p", str(APP_PID)])[1]
    env = {}
    for word in out.split():
        if "=" in word and re.match(r"^[A-Z_][A-Z0-9_]*=", word):
            key, value = word.split("=", 1)
            env[key] = value
    return env


APP_ENV = app_env()
APP_HOME = APP_ENV.get("HOME") or os.path.expanduser("~")


def processes():
    out = sh(["ps", "axo", "pid=,ppid=,rss=,args="])[1]
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit():
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3]))
    return rows


def daemon_process():
    """The headless cmux-tui daemon the app started (run from its bundle): (pid, socket)."""
    for pid, _, _, args in processes():
        if args.startswith(opts.app + "/") and "--headless" in args:
            found = re.search(r"--socket (\S+)", args)
            if found:
                return pid, found.group(1)
    return None, None


def acpmux_socket_of(home):
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


def acpmux_home():
    try:
        home = build_names.of_app(opts.app, APP_HOME)["acpmux_home"]
    except (ValueError, KeyError, OSError):
        return None
    return home


def acpmux_pid(home):
    try:
        return int(open(os.path.join(home, "daemon.pid")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def cli(*args, timeout=30, sock=None, binary=None):
    """The bundled CLI on the daemon socket, --json: (ms, parsed or None, error code or None)."""
    sock = sock or DAEMON_SOCK
    env = {"HOME": APP_HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    start = time.monotonic()
    try:
        done = subprocess.run([binary or CLI, "--socket", sock, "--json", *args], capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return (time.monotonic() - start) * 1000, None, "timeout"
    ms = (time.monotonic() - start) * 1000
    try:
        parsed = json.loads(done.stdout) if done.stdout.strip() else None
    except ValueError:
        parsed = None
    code = None
    if done.returncode != 0:
        found = ERROR_CODE.search(done.stdout + done.stderr)
        code = (found.group(1) or found.group(2)) if found else f"exit{done.returncode}"
    return ms, parsed, code


def value(parsed):
    return parsed.get("value", parsed) if isinstance(parsed, dict) else {}


DAEMON_PID, DAEMON_SOCK = None, None
for _ in range(60):
    DAEMON_PID, DAEMON_SOCK = daemon_process()
    if DAEMON_SOCK:
        break
    time.sleep(1)
if not DAEMON_SOCK:
    raise SystemExit("austins-day: no cmux-tui daemon of this app found")
ACPMUX_HOME = acpmux_home()
say(f"app pid {APP_PID}, daemon pid {DAEMON_PID} socket {DAEMON_SOCK}, acpmux home {ACPMUX_HOME}")


def server_stats():
    ms, parsed, code = cli("server", "stats", timeout=20)
    return {"t": round(time.time() - T0, 2), "ms": round(ms, 1), "code": code, "stats": value(parsed) if parsed else None}


# ---- host sampling ----------------------------------------------------------------------------

def sysctl(name):
    return sh(["sysctl", "-n", name], timeout=10)[1].strip()


def swap_used_mb():
    found = re.search(r"used = ([0-9.]+)M", sysctl("vm.swapusage"))
    return float(found.group(1)) if found else None


def loadavg():
    found = re.findall(r"[0-9.]+", sysctl("vm.loadavg"))
    return float(found[0]) if found else None


def footprints(pids):
    """phys footprint (MB) per pid from `top -l 1` (its MEM column)."""
    argv = ["top", "-l", "1", "-s", "0", "-stats", "pid,mem"]
    for pid in pids:
        argv += ["-pid", str(pid)]
    out = sh(argv, timeout=30)[1]
    result = {}
    for line in out.splitlines():
        found = re.match(r"^\s*(\d+)\s+([0-9.]+)([KMGB])\+?-?\s*$", line)
        if found:
            scale = {"K": 1 / 1024, "M": 1, "G": 1024, "B": 1 / (1 << 20)}[found.group(3)]
            result[int(found.group(1))] = round(float(found.group(2)) * scale, 1)
    return result


def open_fds(pid):
    """Open file descriptors of `pid` (`lsof -p`, one line per fd after the header); None when unknown."""
    rc, out, _ = sh(["lsof", "-n", "-P", "-p", str(pid)], timeout=30)
    if rc not in (0, 1) or not out:
        return None
    return sum(1 for line in out.splitlines()[1:] if re.match(r"^\S+\s+\d+\s+\S+\s+\d+", line))


def client_list_entries(parsed):
    """The connections in `cmux --json client list`'s output: the daemon's resource result is a bare array
    (resource_client_list), which the CLI prints as it is; a dict envelope ({"value": [...]} or a "clients"
    or "items" list) is read too. None when there is no list (the call failed)."""
    if isinstance(parsed, list):
        return parsed
    if isinstance(parsed, dict):
        for key in ("value", "clients", "items"):
            if isinstance(parsed.get(key), list):
                return parsed[key]
    return None


def connection_holders(rows, ask_daemon=True):
    """Who holds or waits for the daemon's connections now: the daemon's own client list (`cmux-tui client list`:
    each connection's name, kind, transport and age) by name and kind, and the live client processes on the
    host by role (hook helpers, `cmux` CLI calls, the app). A `cmux` process here is one of the bundle's CLI
    or hook binaries; each holds at most one connection or is waiting for one."""
    # `cmux-tui client list` (the resource operation client.list; `client` is a cmux-tui-only scope): one
    # object per connection with name, client_kind, transport and connected_seconds. Asked only after the
    # load (ask_daemon): during it this sample counts processes only, as in the A/As.
    if ask_daemon:
        _, parsed, code = cli("client", "list", timeout=15, binary=CLI_TUI)
        clients = client_list_entries(parsed)
    else:
        parsed, code, clients = None, "not asked during the load", None
    by_label = {}
    ages = {}
    for client in clients or []:
        if not isinstance(client, dict):
            continue
        label = f"{client.get('client_kind') or client.get('kind') or '-'}/{client.get('name') or '-'}/{client.get('transport') or '-'}"
        by_label[label] = by_label.get(label, 0) + 1
        try:
            ages.setdefault(label, []).append(float(client.get("connected_seconds")))
        except (TypeError, ValueError):
            pass
    roles = {"hook_helper": 0, "cli": 0, "other_bundle": 0}
    # What each role's processes are: their arguments after the binary, by count (the main-arm A/A of
    # 2026-10-30 had a median of 48 'cli' processes with no agent CLI calls, and the role alone did not say
    # what they run). From the same `ps` read: no extra command on the host.
    kinds = {"hook_helper": {}, "cli": {}}
    for _, _, _, args in rows:
        role = None
        if "cmux-tui-hook" in args or "__agent-hook" in args:
            role = "hook_helper"
        elif args.startswith(CLI + " ") or args == CLI:
            role = "cli"
        elif args.startswith(opts.app + "/") and "--headless" not in args:
            roles["other_bundle"] += 1
        if role:
            roles[role] += 1
            # The binary's name, then the command words without --socket VALUE, --json and ids.
            # The app path has spaces ("cmux DEV <tag>.app"): replace it before splitting (review of 59ea3fdb421).
            rest = (args[len(CLI):] if role == "cli" else args).replace(opts.app + "/", "<app>/")
            words, skip = [], False
            for w in rest.split():
                if skip:
                    skip = False
                    continue
                if w == "--socket":
                    skip = True
                    continue
                if w == "--json" or re.match(r"^(term|ws|pane|tab|session|machine)_[0-9a-f]{8,}$", w):
                    continue
                words.append(w)
            shape = (("cmux " if role == "cli" else "") + " ".join(words[:4]))[:120]
            kinds[role][shape] = kinds[role].get(shape, 0) + 1
    return {"list_code": code, "listed": len(clients) if clients is not None else None, "by_label": by_label,
            "max_age_s": {k: max((a for a in v if isinstance(a, (int, float))), default=None) for k, v in ages.items()},
            "processes": roles,
            "process_kinds": {role: dict(sorted(k.items(), key=lambda kv: -kv[1])[:8]) for role, k in kinds.items()}}


def sampler():
    tick = 0
    while not STOP.is_set():
        rows = processes()
        rss = {pid: kb / 1024 for pid, _, kb, _ in rows}
        apid = acpmux_pid(ACPMUX_HOME) if ACPMUX_HOME else None
        dpid = daemon_process()[0]
        watched = {"app": APP_PID, "daemon": dpid, "acpmux": apid}
        sample = {"t": round(time.time() - T0, 2), "load1": loadavg(), "swap_used_mb": swap_used_mb(),
                  "memory_level": int(sysctl("kern.memorystatus_level") or 0),
                  "procs": len(rows), "phase": PHASE["name"]}
        for name, pid in watched.items():
            sample[f"{name}_pid"] = pid
            sample[f"{name}_rss_mb"] = round(rss.get(pid, 0), 1) if pid else None
        if tick % 3 == 0:
            fp = footprints([p for p in watched.values() if p])
            for name, pid in watched.items():
                sample[f"{name}_footprint_mb"] = fp.get(pid) if pid else None
                sample[f"{name}_fds"] = open_fds(pid) if pid else None
        record("samples", sample)
        if tick % 3 == 0:
            record("server_stats", {**server_stats(), "phase": PHASE["name"]})
            # During the load only the process count (as in the A/As): the daemon's own client list is read
            # once, right after the load (connection_holders(rows, ask_daemon=True) in main), so this sample
            # adds no connection, registry-lock acquisition or wait to the measured window.
            record("holders", {"t": round(time.time() - T0, 2), "phase": PHASE["name"], **connection_holders(rows, ask_daemon=False)})
        tick += 1
        STOP.wait(5)


def person_cli_probe():
    """A person's `cmux` read from outside every terminal, once a second."""
    while not STOP.is_set():
        ms, _, code = cli("workspace", "list", timeout=15)
        record("person_cli", {"t": round(time.time() - T0, 2), "ms": round(ms, 2), "code": code, "phase": PHASE["name"]})
        start = time.monotonic()
        answer = rpc("system.identify", timeout=15)
        record("app_control", {"t": round(time.time() - T0, 2), "ms": round((time.monotonic() - start) * 1000, 2),
                               "error": answer.get("error") if isinstance(answer, dict) else "bad", "phase": PHASE["name"]})
        STOP.wait(1)


PHASE = {"name": "setup"}


# ---- terminal agents --------------------------------------------------------------------------

AGENT_DIR = os.path.join(opts.out, "agents")
os.makedirs(AGENT_DIR, exist_ok=True)
FAKEBIN = os.path.join(opts.out, "fakebin")
os.makedirs(FAKEBIN, exist_ok=True)
shutil.copy(os.path.join(HERE, "fake_claude.py"), os.path.join(FAKEBIN, "claude"))
os.chmod(os.path.join(FAKEBIN, "claude"), 0o755)
LAUNCHER = os.path.join(FAKEBIN, "ad-agent.sh")
with open(LAUNCHER, "w") as f:
    f.write(r'''#!/bin/sh
# ad-agent.sh WORKTREE: start `claude` the way a person does in a cmux terminal. The fake Claude's
# folder goes right after the cmux shim folder, so the shim and wrapper run, find it as the real
# Claude and give it the hooks (a folder named .../shims stays first).
fake=$(cd "$(dirname "$0")" && pwd)
shims=""; rest=""
IFS=:
for d in $PATH; do
  case "$d" in */shims) shims="${shims:+$shims:}$d" ;; *) rest="${rest:+$rest:}$d" ;; esac
done
unset IFS
PATH="${shims:+$shims:}$fake:$rest"; export PATH
cd "$1" || exit 1
exec claude --dangerously-skip-permissions
''')
os.chmod(LAUNCHER, 0o755)
AGENTS = []  # {"index", "workspace", "terminal", "log"}


def worktrees():
    found = sorted(d for d in os.listdir(opts.fixture) if d.startswith("wt-"))
    return [os.path.join(opts.fixture, d) for d in found] or [os.path.join(opts.fixture, "clone")]


def make_terminals(deadline):
    trees = worktrees()
    workspaces = (opts.agents + opts.per_workspace - 1) // opts.per_workspace
    for w in range(workspaces):
        _, parsed, code = cli("workspace", "create", "--name", f"ad-{w}", timeout=60)
        made = value(parsed)
        if not made.get("terminal_id"):
            note(f"workspace ad-{w} not made: {code} {json.dumps(parsed)[:200]}")
            continue
        terminals = [made["terminal_id"]]
        for _ in range(opts.per_workspace - 1):
            if len(AGENTS) + len(terminals) >= opts.agents:
                break
            _, parsed, code = cli("tab", "create", "terminal", "--workspace", made["workspace_id"], "--pane", made["pane_id"], timeout=60)
            tab = value(parsed)
            if tab.get("terminal_id"):
                terminals.append(tab["terminal_id"])
            else:
                note(f"terminal tab in ad-{w} not made: {code}")
        for term in terminals:
            index = len(AGENTS)
            log = os.path.join(AGENT_DIR, f"agent-{index}.jsonl")
            AGENTS.append({"index": index, "workspace": made["workspace_id"], "terminal": term, "log": log,
                           "tree": trees[index % len(trees)]})
        if len(AGENTS) >= opts.agents:
            break
    say(f"made {len(AGENTS)} agent terminals in {workspaces} workspaces")


def start_agents(deadline):
    env = (f"AD_AGENT_DEADLINE={deadline:.0f} AD_TOOL_GAP={opts.tool_gap} AD_CLI_EVERY={opts.cli_every} "
           f"AD_STREAM_CPS={opts.stream_cps} AD_CPU={opts.cpu}")
    for agent in AGENTS:
        line = f"{env} AD_AGENT_LOG={shlex.quote(agent['log'])} sh {shlex.quote(LAUNCHER)} {shlex.quote(agent['tree'])}\n"
        _, _, code = cli("terminal", agent["terminal"], "write", "--text", line, timeout=30)
        if code:
            note(f"agent {agent['index']}: start write refused: {code}")
        time.sleep(0.05)


# ---- Chief waves on acpmux ----------------------------------------------------------------------

def configure_acpmux():
    if ACPMUX_HOME and not os.path.exists(acpmux_socket_of(ACPMUX_HOME)):
        # The app starts its acpmux on first use: open one agent chat, as a person's first chat.
        say(f"acpmux not running; palette.newAgentChat -> {json.dumps(rpc('action.run', {'action': 'palette.newAgentChat'}, timeout=60))[:160]}")
        bound = time.monotonic() + 60
        while time.monotonic() < bound and not os.path.exists(acpmux_socket_of(ACPMUX_HOME)):
            time.sleep(1)
    if not ACPMUX_HOME or not os.path.exists(acpmux_socket_of(ACPMUX_HOME)):
        note(f"no acpmux socket for home {ACPMUX_HOME}: Chief waves do not run")
        return False
    path = os.path.join(ACPMUX_HOME, "config.json")
    try:
        config = json.load(open(path))
    except (OSError, ValueError):
        config = {}
    config.setdefault("harnesses", {})["ad-fake"] = {"argv": ["python3", os.path.join(opts.out, "fake_agent.py")]}
    with open(path + ".ad", "w") as f:
        json.dump(config, f, indent=2)
    os.replace(path + ".ad", path)
    answer = acpmux_call([("_acpmux/reload_config", {})], timeout=30)
    say(f"acpmux reload_config -> {json.dumps(answer)[:200]}")
    return True


def acpmux_call(calls, timeout=60):
    """One connection, initialize, then each (method, params) in order: [(ms, message)]; a list of the
    answers (each {"ms", "error", "result"}). `params` may be a function of the answers so far."""
    answers = []
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        start = time.monotonic()
        conn.connect(acpmux_socket_of(ACPMUX_HOME))
        buf = b""
        rid = 0
        for method, params in [("initialize", {"protocolVersion": 1, "clientInfo": {"name": "austins-day"}})] + calls:
            rid += 1
            if callable(params):
                params = params(answers)
                if params is None:
                    break
            begin = time.monotonic()
            conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
            message = None
            first_chunk_ms = None
            while message is None:
                while b"\n" in buf and message is None:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        parsed = json.loads(line)
                    except ValueError:
                        continue
                    if parsed.get("id") == rid and ("result" in parsed or "error" in parsed):
                        message = parsed
                    elif (first_chunk_ms is None and parsed.get("method") == "session/update"
                          and ((parsed.get("params") or {}).get("update") or {}).get("sessionUpdate") == "agent_message_chunk"):
                        # The agent's first answer text for this request (#28442: time to first answer).
                        first_chunk_ms = round((time.monotonic() - begin) * 1000, 2)
                if message is None:
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        raise OSError("closed")
                    buf += chunk
            answers.append({"method": method, "ms": round((time.monotonic() - begin) * 1000, 2),
                            "first_chunk_ms": first_chunk_ms,
                            "error": (message.get("error") or {}).get("message") if message.get("error") else None,
                            "result": message.get("result")})
        conn.close()
        _ = start
    except (OSError, socket.timeout) as error:
        answers.append({"method": "connection", "ms": None, "error": f"{type(error).__name__}: {error}", "result": None})
    return answers


def one_chat(wave, index, out):
    def prompt(answers):
        sid = ((answers[-1].get("result") or {}) if answers else {}).get("sessionId")
        if not sid:
            return None
        return {"sessionId": sid, "prompt": [{"type": "text", "text": "slow"}],
                "_meta": {"acpmux": {"promptId": f"ad-{wave}-{index}"}}}
    answers = acpmux_call([("session/new", {"cwd": worktrees()[index % len(worktrees())], "mcpServers": [],
                                            "_meta": {"acpmux": {"harness": "ad-fake"}}}),
                           ("session/prompt", prompt)], timeout=120)
    # Drop the initialize answer by its method (index 0 is a failed connection when the connect is refused or
    # initialize never answers; that entry stays: it is this chat's failed open). Never an empty chat.
    chat = [a for a in answers if a["method"] != "initialize"]
    out.append(chat or [{"method": "connection", "ms": None, "error": "no answer", "result": None}])


def waves(deadline):
    if not configure_acpmux():
        return
    wave = 0
    while not STOP.is_set() and time.time() < deadline:
        wave += 1
        results = []
        threads = [threading.Thread(target=one_chat, args=(wave, i, results), daemon=True) for i in range(opts.wave_size)]
        start = time.time()
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=150)
        # A chat still running when the wave stops waiting is recorded as such (it got no answer in 150 s);
        # before, it was left out (review of bcbeee46824: survivor bias for the slowest chats).
        # Snapshot the finished chats first, then count the threads still alive: a late chat appends to
        # `results` after this point, which this wave's record never reads again (it is a copy).
        finished = [list(chat) for chat in list(results)]
        still_running = opts.wave_size - len(finished)
        chats = finished + [[{"method": "connection", "ms": None, "error": "still running at the 150 s wave limit",
                              "result": None}] for _ in range(still_running)]
        flat = [a for chat in chats for a in chat]
        # `chats`: one list per chat attempt (its first entry is its session/new, or the failed connection).
        record("waves", {"t": round(start - T0, 2), "wave": wave, "chats": chats, "answers": flat,
                         "took_s": round(time.time() - start, 2)})
        errors = [a["error"] for a in flat if a.get("error")]
        say(f"wave {wave}: {len(flat)} answers, {len(errors)} errors in {time.time() - start:.1f}s")
        STOP.wait(max(0, opts.wave_period - (time.time() - start)))


def acpmux_watch():
    last = None
    while not STOP.is_set():
        pid = acpmux_pid(ACPMUX_HOME) if ACPMUX_HOME else None
        if pid != last:
            record("acpmux_pids", {"t": round(time.time() - T0, 2), "pid": pid})
            last = pid
        STOP.wait(2)


# ---- workspace close ----------------------------------------------------------------------------

def topology_ids():
    snap = rpc("snapshot.get", timeout=20)
    topo = snap.get("topology") if isinstance(snap, dict) else None
    if not isinstance(topo, dict):
        return None
    return {w.get("id") for w in topo.get("workspaces", [])}


def closes(deadline):
    n = 0
    # A close takes at most about 125 s (create up to 60 s, show up to 20 s, the action up to 30 s and the
    # watchers' 30 s bound from the same start, joined within 15 s more): one starts only when that fits
    # before the load's deadline, so the end of the run never cuts a close (re-reviews of 2b7fd104fdc and
    # a84ddb0e414).
    while not STOP.is_set():
        STOP.wait(opts.close_every)
        if STOP.is_set() or time.time() + 125 > deadline:
            break
        n += 1
        _, parsed, code = cli("workspace", "create", "--name", f"ad-close-{n}", timeout=60)
        ws = value(parsed).get("workspace_id")
        if not ws:
            record("closes", {"t": round(time.time() - T0, 2), "n": n, "made": False, "code": code})
            continue
        # Wait until the app shows it (bounded), then close it as the sidebar's close does.
        shown_by = time.monotonic() + 20
        while time.monotonic() < shown_by and ws not in (topology_ids() or set()):
            time.sleep(0.1)
        # The app's and the daemon's views are polled in their own threads from the moment the action is
        # sent: a slow `cmux workspace list` under load must not delay the app's reading, and the action's
        # own reply (up to its 2 s deadline) must not delay either (review of aa7c09ebaed, finding 1).
        gone = {}
        start = time.monotonic()
        bound = start + 30

        def watch(name, still_there):
            while time.monotonic() < bound:
                if still_there() is False:
                    gone[name] = (time.monotonic() - start) * 1000
                    return
                time.sleep(0.1)

        def app_has():
            ids = topology_ids()
            return None if ids is None else ws in ids

        def daemon_has():
            _, listed, _ = cli("workspace", "list", timeout=10)
            return None if listed is None else ws in json.dumps(listed)

        watchers = [threading.Thread(target=watch, args=("app", app_has), daemon=True),
                    threading.Thread(target=watch, args=("daemon", daemon_has), daemon=True)]
        for thread in watchers:
            thread.start()
        answer = rpc("action.run", {"action": "closeWorkspace", "target": f"workspace:{ws}", "args": {"confirm": True}}, timeout=30)
        acted_ms = (time.monotonic() - start) * 1000
        for thread in watchers:
            thread.join(timeout=max(0.0, bound - time.monotonic()) + 15)
        app_gone, daemon_gone = gone.get("app"), gone.get("daemon")
        record("closes", {"t": round(time.time() - T0, 2), "n": n, "made": True, "action_ms": round(acted_ms, 1),
                          "action_error": answer.get("error") if isinstance(answer, dict) else None,
                          "app_gone_ms": app_gone and round(app_gone, 1), "daemon_gone_ms": daemon_gone and round(daemon_gone, 1)})


# ---- end of run: stalls, app log, agents ----------------------------------------------------------

def cmux_image(image):
    return bool(image) and ("cmux" in image.lower())


def demangle(symbols):
    names = [s for s in symbols if s]
    if not names:
        return {}
    for tool in (["xcrun", "swift-demangle", "--simplified"], ["swift-demangle", "--simplified"]):
        try:
            done = subprocess.run(tool, input="\n".join(names) + "\n", capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            continue
        lines = done.stdout.splitlines()
        if done.returncode == 0 and len(lines) == len(names):
            return dict(zip(names, lines))
    return {name: name for name in names}


def stalls(hangs):
    """Each stall over 100 ms, named by its top cmux symbol: the first frame in a cmux image whose
    symbol is cmux's own code (a CmuxNext module); else the first frame in a cmux image (a stdlib or
    framework generic specialized into it)."""
    records = (hangs or {}).get("records") or []
    long = [r for r in records if (r.get("duration_ms") or 0) > STALL_MS]
    every = {f["symbol"] for r in long for f in r.get("frame_details") or [] if cmux_image(f.get("image")) and f.get("symbol")}
    names = demangle(every)
    tops = []
    for r in long:
        frames = [f for f in r.get("frame_details") or [] if cmux_image(f.get("image")) and f.get("symbol")]
        own = next((f for f in frames if "CmuxNext" in names.get(f["symbol"], f["symbol"])), None)
        tops.append(own or (frames[0] if frames else None))
    out = []
    for r, top in zip(long, tops):
        # The app's own cause and fault counts when it reports them (debug.hangs from
        # fix/stall-hang-wait-split on); summarize.py classifies older records from cpu_ms / duration_ms.
        out.append({"duration_ms": r.get("duration_ms"), "cpu_ms": r.get("cpu_ms"), "kind": r.get("kind"),
                    "cause": r.get("cause"), "task_faults": r.get("task_faults"), "task_pageins": r.get("task_pageins"),
                    "fault_window_ms": r.get("fault_window_ms"),
                    "cmux_frame": bool(top), "symbol": names.get(top["symbol"], top["symbol"]) if top else None,
                    "image": top.get("image") if top else None})
    return out


def app_log(seconds):
    predicate = (f"processID == {APP_PID} AND (eventMessage CONTAINS[c] 'no reply within' OR eventMessage CONTAINS[c] 'server.busy' "
                 "OR (category == 'daemon' AND eventMessage CONTAINS[c] 'failed') "
                 "OR eventMessage CONTAINS[c] 'session.busy' OR eventMessage CONTAINS[c] 'no_answer' "
                 "OR eventMessage CONTAINS[c] 'stopped answering' OR eventMessage CONTAINS[c] 'unresponsive' "
                 "OR eventMessage CONTAINS[c] 'timed out')")
    rc, out, err = sh(["log", "show", "--last", f"{int(seconds) + 30}s", "--style", "compact", "--predicate", predicate], timeout=240)
    lines = [l for l in out.splitlines() if l and not l.startswith(("Timestamp", "Filtering"))]
    with open(os.path.join(opts.out, "app-log.txt"), "w") as f:
        f.write(out if rc == 0 else f"log show failed: {rc} {err}")
    no_reply = [l for l in lines if "no reply within" in l]
    by_cmd = {}
    for l in no_reply:
        found = re.search(r"([a-z][a-z0-9-]+) \(no reply within", l)
        key = found.group(1) if found else "?"
        by_cmd[key] = by_cmd.get(key, 0) + 1
    return {"ok": rc == 0, "lines": len(lines), "no_reply_within": len(no_reply), "no_reply_by_cmd": by_cmd,
            "server_busy": sum("server.busy" in l for l in lines), "session_busy": sum("session.busy" in l for l in lines),
            "daemon_failed": sum(" failed" in l for l in lines),
            "acpmux_unresponsive": sum(("stopped answering" in l or "unresponsive" in l.lower()) for l in lines)}


def agent_records():
    records = []
    for agent in AGENTS:
        try:
            with open(agent["log"]) as f:
                for line in f:
                    try:
                        records.append(json.loads(line))
                    except ValueError:
                        pass
        except OSError:
            pass
    return records


# ---- the run ------------------------------------------------------------------------------------

def main():
    shutil.copy(os.path.join(HERE, "fake_agent.py"), os.path.join(opts.out, "fake_agent.py"))
    hog = None
    threads = [threading.Thread(target=sampler, daemon=True), threading.Thread(target=person_cli_probe, daemon=True),
               threading.Thread(target=acpmux_watch, daemon=True)]
    for thread in threads:
        thread.start()
    record("server_stats", {**server_stats(), "phase": "start"})
    app_probe_start = rpc("debug.daemon_requests", timeout=20)
    rpc("debug.hangs", {"clear": True}, timeout=20)
    load_end = time.time() + opts.baseline + 90 + opts.seconds  # agent deadline: covers setup and the load phase
    make_terminals(load_end)
    PHASE["name"] = "baseline"
    STOP.wait(opts.baseline)
    PHASE["name"] = "load"
    load_start = time.time()
    deadline = load_start + opts.seconds
    start_agents(deadline)
    if opts.swap_gb > 0:
        hog = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "hog.py"), "--swap-gb", str(opts.swap_gb),
                                "--deadline", f"{deadline:.0f}", "--log", os.path.join(opts.out, "hog.jsonl")],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    load_threads = [threading.Thread(target=waves, args=(deadline,), daemon=True),
                    threading.Thread(target=closes, args=(deadline,), daemon=True)]
    for thread in load_threads:
        thread.start()
    try:
        while time.time() < deadline:
            time.sleep(1)
    finally:
        PHASE["name"] = "end"
        if hog and hog.poll() is None:
            hog.terminate()  # our own child: it frees its memory and exits
            try:
                hog.wait(timeout=30)
            except subprocess.TimeoutExpired:
                hog.kill()
                hog.wait(timeout=30)
    record("server_stats", {**server_stats(), "phase": "end"})
    # Stop the samplers and probes first, so the end read stays the last server-stats sample and no sample
    # falls in the post-load calls below (review of 3bf19c209e0, note 1).
    STOP.set()
    for thread in load_threads + threads:
        thread.join(timeout=30)
    # After the load (outside every measured window): the daemon's lock detail (server-stats `locks`: the
    # registry lock and mux.state, the top 20 sites by total hold and by p99 hold, counted since the daemon
    # started, so setup and the baseline are in them; #28147 and later), and its own client list.
    _, locks, locks_code = cli("raw", "command", "--request-json",
                               json.dumps({"id": 1, "cmd": "server-stats", "include": ["locks"]}), timeout=30, binary=CLI_TUI)
    record("locks", {"t": round(time.time() - T0, 2), "code": locks_code,
                     "locks": locks.get("locks") if isinstance(locks, dict) else None})
    record("holders", {"t": round(time.time() - T0, 2), "phase": "end", **connection_holders(processes(), ask_daemon=True)})
    hangs = rpc("debug.hangs", timeout=60)
    app_probe_end = rpc("debug.daemon_requests", timeout=20)
    log_summary = app_log(time.time() - load_start)
    agents = agent_records()
    with open(os.path.join(opts.out, "debug-hangs.json"), "w") as f:
        json.dump(hangs, f)
    run = {"schema": 1, "label": opts.label, "app_pid": APP_PID, "daemon_pid": DAEMON_PID, "acpmux_home": ACPMUX_HOME,
           "host": socket.gethostname(), "opts": vars(opts), "load_start_s": round(load_start - T0, 2),
           "load_seconds": opts.seconds, "agents": opts.agents, "agents_made": len(AGENTS), "series": SERIES, "agent_records": agents,
           "app_probe": {"start": app_probe_start, "end": app_probe_end}, "app_log": log_summary,
           "stalls": stalls(hangs), "hangs_summary": {k: v for k, v in (hangs or {}).items() if k not in ("records", "over_budget")}
           if isinstance(hangs, dict) else hangs}
    with open(os.path.join(opts.out, "run.json"), "w") as f:
        json.dump(run, f)
    short = {"agents": len(AGENTS), "hooked": sum(1 for r in agents if r.get("kind") == "start" and r.get("hooked")),
             "hooks": sum(1 for r in agents if r.get("kind") == "hook"), "app_no_reply": log_summary["no_reply_within"],
             "stalls_cmux": sum(1 for s in run["stalls"] if s["cmux_frame"])}
    print("AUSTINS-DAY " + json.dumps(short), flush=True)


for _sig in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(_sig, lambda *_: sys.exit(1))
main()
