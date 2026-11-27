#!/usr/bin/env python3
"""Theoretical-optimum floors for acpmux vs raw Claude Code vs raw Codex, on this machine.

Measures (p50 of N runs; the script re-execs itself under `taskset -c 12-15`):
  spawn    fork+exec+wait of /bin/true, a static C and a static Rust no-op, `node -e 0`,
           `bun -e 0`, `python3 -c pass`, and `claude|codex|acpmux --version`
  rss      idle node, idle static Rust, and each harness idle at its handshake (claude -p
           stream-json after `initialize`; codex app-server after thread/start; acpmux daemon
           with 0 sessions, and with 1 and 5 stand-in claude sessions): process-tree RSS, count,
           threads, and idle CPU % over a window (utime+stime from /proc)
  ipc      JSON-line round trip over a unix socketpair and a pipe pair (echo child), vs acpmux's
           own `_acpmux/status` over its daemon socket
  arch     the per-N-chats formula evaluated from the measured units (see FORMULAS)
Harnesses run against the local stand-in model of scripts/cmux-next/acpmux-overhead-bench.py
(imported via importlib: StandIn, env_for, Daemon, Lines, spawn), so no credentials are used.

Run (from the checkout root):
  python3 scripts/measure/acpmux-vs-harness/optimum.py [--runs 30] [--idle-secs 5] [--n-ipc 2000]
Writes .build/acpmux-vs-harness/optimum.json and optimum.md. Cleans up only processes it started.
"""
from __future__ import annotations

import argparse, importlib.util, json, os, shutil, socket, statistics, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / ".build" / "acpmux-vs-harness"
CPUS = "12-15"
TICK = os.sysconf("SC_CLK_TCK")


def load_bench():
    spec = importlib.util.spec_from_file_location("overhead", ROOT / "scripts/cmux-next/acpmux-overhead-bench.py")
    m = importlib.util.module_from_spec(spec)
    sys.modules["overhead"] = m
    spec.loader.exec_module(m)
    return m


def p50(xs):
    return round(statistics.median(xs), 3) if xs else None


def which(n):
    p = os.path.expanduser(f"~/.local/bin/{n}")
    return p if os.path.exists(p) else shutil.which(n)


# ------------------------------------------------------------------ spawn
def spawn_ms(argv, runs):
    xs = []
    for i in range(runs + 2):  # two warmups
        t = time.perf_counter()
        subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL).wait()
        d = (time.perf_counter() - t) * 1000
        if i >= 2:
            xs.append(d)
    return xs


def build_noops(tmp):
    out = {}
    if shutil.which("gcc"):
        (tmp / "n.c").write_text("int main(void){return 0;}")
        if subprocess.run(["gcc", "-O2", "-static", "-o", str(tmp / "noop_c"), str(tmp / "n.c")]).returncode == 0:
            out["static C noop"] = str(tmp / "noop_c")
    if shutil.which("rustc"):
        flags = ["rustc", "-O", "-C", "target-feature=+crt-static"]
        (tmp / "n.rs").write_text("fn main(){}")
        if subprocess.run(flags + ["-o", str(tmp / "noop_rs"), str(tmp / "n.rs")], capture_output=True).returncode == 0:
            out["static Rust noop"] = str(tmp / "noop_rs")
        (tmp / "s.rs").write_text("fn main(){loop{std::thread::sleep(std::time::Duration::from_secs(3600));}}")
        subprocess.run(flags + ["-o", str(tmp / "idle_rs"), str(tmp / "s.rs")], capture_output=True)
    return out


def spawn_section(runs, tmp, acpmux):
    cases = {"/bin/true": ["/bin/true"]}
    for k, v in build_noops(tmp).items():
        cases[k] = [v]
    for name, argv in (("node -e 0", ["node", "-e", "0"]), ("bun -e 0", ["bun", "-e", "0"]),
                       ("python3 -c pass", ["python3", "-c", "pass"]),
                       ("claude --version", ["claude", "--version"]), ("codex --version", ["codex", "--version"]),
                       ("codex --version (real binary, no guard shim)", ["/usr/local/bin/codex", "--version"]),
                       ("acpmux --version", [acpmux, "--version"])):
        p = which(argv[0]) if not os.path.isabs(argv[0]) else argv[0]
        if p:
            cases[name] = [p] + argv[1:]
    res = {}
    for name, argv in cases.items():
        xs = spawn_ms(argv, runs)
        res[name] = {"p50_ms": p50(xs), "min_ms": round(min(xs), 3), "p90_ms": round(sorted(xs)[int(len(xs) * .9) - 1], 3)}
    return res


# ------------------------------------------------------------------ rss / cpu
def table():
    rows = {}
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
    for l in out.splitlines():
        f = l.split()
        if len(f) == 3:
            rows[int(f[0])] = (int(f[1]), int(f[2]))
    return rows


def tree(root, rows):
    t, i = [root], 0
    while i < len(t):
        t.extend(p for p, (pp, _) in rows.items() if pp == t[i] and p not in t)
        i += 1
    return [p for p in t if p in rows]


def cpu_ticks(pids):
    """{pid: utime+stime ticks} for the pids still alive."""
    n = {}
    for p in pids:
        try:
            f = open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()
            n[p] = int(f[11]) + int(f[12])
        except OSError:
            pass
    return n


def measure_root(roots, secs):
    rows = table()
    allp = []
    for r in roots:
        allp += [p for p in tree(r, rows) if p not in allp]
    s = {"procs": len(allp), "rss_mb": round(sum(rows[p][1] for p in allp) / 1024, 1)}
    s["threads"] = sum(len(os.listdir(f"/proc/{p}/task")) for p in allp if os.path.exists(f"/proc/{p}/task"))
    a, t = cpu_ticks(allp), time.perf_counter()
    time.sleep(secs)
    b = cpu_ticks(allp)  # only pids alive at both ends, so an exiting helper never goes negative
    s["idle_cpu_pct"] = round(sum(b[p] - a[p] for p in b if p in a) / TICK / (time.perf_counter() - t) * 100, 3)
    return s


def rss_section(B, tmp, acpmux, secs):
    res = {}
    stand = B.StandIn()
    threading.Thread(target=stand.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{stand.server_address[1]}"
    scratch = str(tmp / "scratch")
    os.makedirs(scratch)
    env = B.env_for(url, scratch)
    cwd = scratch
    try:
        for name, argv in (("idle node", ["node", "-e", "setInterval(()=>{},1e9)"]),
                           ("idle static Rust", [str(tmp / "idle_rs")])):
            if not os.path.exists(argv[0]) and "Rust" in name:
                continue
            p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, env=env)
            time.sleep(1.0)
            res[name] = measure_root([p.pid], secs)
            p.terminate(); p.wait()
        p = B.spawn(["claude", "-p", "--model", B.MODELS["claude"], "--input-format", "stream-json", "--output-format",
                     "stream-json", "--verbose", "--permission-prompt-tool", "stdio", "--session-id", str(uuid.uuid4())],
                    env, cwd)
        io = B.Lines(p.stdout, p.stdin)
        io.send({"type": "control_request", "request_id": "b1", "request": {"subtype": "initialize", "hooks": {}}})
        io.wait(lambda m: m.get("type") == "control_response")
        time.sleep(3.0)
        res["claude idle (stream-json, initialized)"] = measure_root([p.pid], secs)
        B.stop(p)
        p = B.spawn(["codex", "app-server"], env, cwd)
        io = B.Lines(p.stdout, p.stdin)
        io.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "opt", "version": "1"}}})
        io.wait(lambda m: m.get("id") == 1)
        io.send({"jsonrpc": "2.0", "method": "initialized"})
        io.send({"jsonrpc": "2.0", "id": 2, "method": "thread/start", "params": {"cwd": cwd}})
        io.wait(lambda m: m.get("id") == 2)
        time.sleep(3.0)
        res["codex idle (app-server, thread started)"] = measure_root([p.pid], secs)
        B.stop(p)
        home = str(tmp / "acpmux-home")
        os.makedirs(home, mode=0o700); os.chmod(home, 0o700)
        d = B.Daemon(acpmux, env, home)
        try:
            time.sleep(4.0)
            res["acpmux daemon, 0 sessions"] = measure_root([d.p.pid], secs)
            sids = []
            for n in (1, 5):
                while len(sids) < n:
                    _, r = d.request("session/new", {"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {
                        "harness": "claude", "policy": "approve-all", "model": B.MODELS["claude"]}}})
                    sids.append(r["sessionId"])
                time.sleep(4.0)
                pids = [d.p.pid]
                for s in sids:
                    hp = os.path.join(home, "hosts", f"{s}.json")
                    if os.path.exists(hp):
                        rec = json.load(open(hp))
                        pids += [x for x in (rec.get("host_pid"), rec.get("harness_pid")) if x]
                res[f"acpmux daemon + {n} claude session(s) idle"] = measure_root(pids, secs)
            xs = []
            for _ in range(300):
                t = time.perf_counter()
                d.request("_acpmux/status", {})
                xs.append((time.perf_counter() - t) * 1000)
            res["_acpmux/status ms"] = {"p50": p50(xs), "p90": round(sorted(xs)[269], 3)}
        finally:
            d.close()
    finally:
        stand.shutdown()
    return res


# ------------------------------------------------------------------ ipc floor
def ipc_section(n):
    res = {}
    msg = (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {"x": "y" * 64}}) + "\n").encode()
    for kind in ("unix", "pipe"):
        if kind == "unix":
            a, b = socket.socketpair()
            c = subprocess.Popen(["python3", "-c", "import socket,sys\ns=socket.socket(fileno=int(sys.argv[1]));f=s.makefile('rwb',0)\n"
                                  "for l in f: f.write(l)", str(b.fileno())], pass_fds=[b.fileno()])
            b.close()
            rd = wr = a.makefile("rwb", 0)
        else:
            r1, w1 = os.pipe(); r2, w2 = os.pipe()
            c = subprocess.Popen(["python3", "-c", "import os,sys\nr=os.fdopen(int(sys.argv[1]),'rb',0);w=os.fdopen(int(sys.argv[2]),'wb',0)\n"
                                  "for l in r: w.write(l)", str(r1), str(w2)], pass_fds=[r1, w2])
            os.close(r1); os.close(w2)
            rd, wr = os.fdopen(r2, "rb", 0), os.fdopen(w1, "wb", 0)
        xs = []
        for i in range(n + 200):
            t = time.perf_counter()
            wr.write(msg)
            rd.readline()
            d = (time.perf_counter() - t) * 1000
            if i >= 200:
                xs.append(d)
        res[f"{kind} JSON-line round trip"] = {"p50_ms": p50(xs), "p90_ms": round(sorted(xs)[int(len(xs) * .9)], 4)}
        c.kill(); c.wait()
    return res


# ------------------------------------------------------------------ arch formulas
FORMULAS = """\
Per N chats, K MCP servers. u_h = measured idle RSS of the harness tree, u_m = idle RSS of one MCP server,
u_d = idle daemon RSS, u_s = acpmux's measured per-session extra RSS over a raw claude (host + helpers).
  black-box, no multiplexer, MCP per chat:           procs = N*(1+K)   ; RSS = N*(u_h + K*u_m_node)
  floor: shared MCP (K not K*N) + 1 daemon:          procs = N + K + 1 ; RSS = N*u_h + K*u_m_rust + u_d
  acpmux today (measured marginal procs/chat p, extra u_s): procs = 1 + N*p + K ; RSS = u_d + N*(u_h+u_s) + K*u_m_node
u_m floor = idle static Rust; typical = idle node. A harness is a black box: 1 process per chat is the minimum."""


def arch_section(rss):
    g = lambda k: (rss.get(k) or {}).get("rss_mb")
    uh = {"claude": g("claude idle (stream-json, initialized)") or 0, "codex": g("codex idle (app-server, thread started)") or 0}
    um_floor, um_node = g("idle static Rust") or 1.0, g("idle node") or 40.0
    ud = g("acpmux daemon, 0 sessions") or 0
    one = rss.get("acpmux daemon + 1 claude session(s) idle") or {}
    five = rss.get("acpmux daemon + 5 claude session(s) idle") or {}
    us = round((five["rss_mb"] - one["rss_mb"]) / 4 - uh["claude"], 1) if five and one else None
    pcs = round((five["procs"] - one["procs"]) / 4, 2) if five and one else None
    K = 3
    out = {"K": K, "u_h": uh, "u_m_floor_mb": um_floor, "u_m_node_mb": um_node, "u_d_mb": ud,
           "u_s_extra_mb_per_chat_vs_raw_claude": us, "acpmux_procs_per_chat_measured": pcs, "rows": []}
    for N in (1, 5, 20):
        for h in ("claude", "codex"):
            u = uh[h]
            out["rows"].append({
                "N": N, "harness": h, "blackbox_procs": N * (1 + K), "blackbox_rss_mb": round(N * (u + K * um_node), 1),
                "floor_procs": N + K + 1, "floor_rss_mb": round(N * u + K * um_floor + ud, 1),
                "acpmux_procs": round(1 + N * pcs + K, 1) if pcs else None,
                "acpmux_rss_mb": round(ud + N * (uh["claude"] + us) + K * um_node, 1) if us is not None and h == "claude" else None})
    return out


def render(R):
    S, Rs, I, A = R["spawn"], R["rss"], R["ipc"], R["arch"]
    f = lambda k, f2="p50_ms": (S.get(k) or {}).get(f2)
    floor = min([v for v in (f("static C noop"), f("static Rust noop"), f("/bin/true")) if v] or [None])
    c1, x1 = Rs.get("claude idle (stream-json, initialized)", {}), Rs.get("codex idle (app-server, thread started)", {})
    d0, d1 = Rs.get("acpmux daemon, 0 sessions", {}), Rs.get("acpmux daemon + 1 claude session(s) idle", {})
    L = ["# acpmux vs Claude Code vs Codex: theoretical optimum", "",
         f"host: {R['host']}, CPUs {CPUS}, load at start {R['load']}, versions {R['versions']}; p50 over {R['runs']} runs; "
         "noise: shared VM, min is the cleaner floor.", "", "## Floors", "",
         "| metric | floor | formula / source | claude | codex | acpmux |", "|---|---|---|---|---|---|",
         f"| spawn ms (`--version`) | {floor} | posix_spawn+wait of a static no-op | {f('claude --version')} | {f('codex --version')} | {f('acpmux --version')} |",
         f"| runtime start ms | node {f('node -e 0')} / bun {f('bun -e 0')} / py {f('python3 -c pass')} | `-e 0` | - | - | - |",
         f"| idle RSS MB per chat | {Rs.get('idle static Rust', {}).get('rss_mb')} (static Rust) / {Rs.get('idle node', {}).get('rss_mb')} (node) | idle process | {c1.get('rss_mb')} | {x1.get('rss_mb')} | {d1.get('rss_mb')} (daemon+1 chat; daemon alone {d0.get('rss_mb')}) |",
         f"| processes per chat | 1 | black-box harness = 1 proc | {c1.get('procs')} | {x1.get('procs')} | {A.get('acpmux_procs_per_chat_measured')} marginal |",
         f"| IPC op ms | unix {I['unix JSON-line round trip']['p50_ms']} / pipe {I['pipe JSON-line round trip']['p50_ms']} | echo child, JSON line | - | - | status {Rs.get('_acpmux/status ms', {}).get('p50')} |",
         f"| idle CPU % | 0 | no timers | {c1.get('idle_cpu_pct')} | {x1.get('idle_cpu_pct')} | {d0.get('idle_cpu_pct')} daemon0 / {d1.get('idle_cpu_pct')} with 1 chat |",
         "", "## Architectural floor (K=3 MCP servers)", "", "```", FORMULAS, "```", "",
         "| N | harness | black-box procs | black-box RSS MB | floor procs | floor RSS MB | acpmux procs | acpmux RSS MB |", "|---|---|---|---|---|---|---|---|"]
    for r in A["rows"]:
        L.append(f"| {r['N']} | {r['harness']} | {r['blackbox_procs']} | {r['blackbox_rss_mb']} | {r['floor_procs']} | {r['floor_rss_mb']} | {r['acpmux_procs']} | {r['acpmux_rss_mb']} |")
    L += ["", "## Headroom for acpmux (source files)", "",
          "- Marginal processes per chat above the 1 a black-box harness needs: agent host + harness + tools helper (3 measured). "
          "Fold the host into the daemon or the harness wrapper: cmux-tui/crates/acpmux/src/agent_host/host.rs, agent_tools.rs, tools_mcp.rs.",
          "- Marginal RSS per chat above a raw claude (u_s in the arch table): host + tools-mcp tokio runtimes; single-thread runtime, lazy start: agent_tools.rs, tools_mcp.rs.",
          "- Daemon idle RSS and ~40 threads at 0 sessions (floor: a few MB, ~4 threads): server/mod.rs, hub/ (runtime worker count, eager caches).",
          "- `_acpmux/status` p50 vs the pipe/unix floor: it locks child mutexes and may wait on a host-pressure sample: hub/views.rs (audit finding 16).",
          "- Idle wakeups scale with chats (watch polling 400 ms, wait 1 s, reader try_wait 500 ms): hub/watch.rs, server/wait.rs, agent.rs (audit finding 5).",
          "- session/new spawns before replying (~38 ms in the audit): hub/ session start path, finding 6. MCP servers per chat instead of shared K: agent_tools.rs (finding 10).",
          "", "## Raw numbers", "", "```json", json.dumps({k: R[k] for k in ("spawn", "rss", "ipc")}, indent=1), "```"]
    return "\n".join(L) + "\n"


def main():
    if os.environ.get("OPTIMUM_PINNED") != "1" and shutil.which("taskset"):
        os.execvpe("taskset", ["taskset", "-c", CPUS, sys.executable] + sys.argv, dict(os.environ, OPTIMUM_PINNED="1"))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--runs", type=int, default=30)
    ap.add_argument("--idle-secs", type=float, default=5)
    ap.add_argument("--n-ipc", type=int, default=2000)
    ap.add_argument("--acpmux", default=which("acpmux"))
    a = ap.parse_args()
    B = load_bench()
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="opt-", dir="/tmp"))
    try:
        R = {"host": " ".join(os.uname()[:1] + os.uname()[2:3]), "load": os.getloadavg(), "runs": a.runs, "versions": {}}
        for n in ("claude", "codex", "acpmux"):
            p = a.acpmux if n == "acpmux" else which(n)
            R["versions"][n] = subprocess.run([p, "--version"], capture_output=True, text=True).stdout.strip()
        R["spawn"] = spawn_section(a.runs, tmp, a.acpmux)
        R["ipc"] = ipc_section(a.n_ipc)
        R["rss"] = rss_section(B, tmp, a.acpmux, a.idle_secs)
        R["arch"] = arch_section(R["rss"])
        (OUT / "optimum.json").write_text(json.dumps(R, indent=1))
        (OUT / "optimum.md").write_text(render(R))
        print((OUT / "optimum.md").read_text())
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
