#!/usr/bin/env python3
"""linux-bench.py BINDIR WORKDIR: mux2 vs cmux-tui vs tmux on Linux.

Measures, for each multiplexer, the same things the macOS harness does:
create latency (CLI), server memory and processes per terminal, throughput
of one terminal running `cat` on 256 MB of plain and SGR text, eight such
terminals at once, and query (CPR) reply latency. One JSON line per result.
"""
import json, os, signal, statistics, subprocess, sys, time

BIN, WORK = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
MUX2, CMUX = f"{BIN}/mux2", f"{BIN}/cmux-tui"
TMUX = ["tmux", "-L", "mux2bench", "-f", "/dev/null"]
ENV = dict(os.environ, MUX2_SOCKET=f"{WORK}/mux2.sock")
SERVERS = "mux2d|cmux-tui daemon start --session bench|tmux -L mux2bench"


def sh(argv, check=True, timeout=900, **kw):
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=ENV, **kw)
    if check and p.returncode:
        raise RuntimeError(f"{argv[:5]} rc={p.returncode}: {p.stderr.strip()[:300]}")
    return p.stdout


def emit(rec):
    print(json.dumps(rec), flush=True)


def stop_all():
    subprocess.run([MUX2, "stop"], capture_output=True, env=ENV)
    subprocess.run(TMUX + ["kill-server"], capture_output=True)
    subprocess.run([CMUX, "daemon", "stop", "--session", "bench", "--force", "--end-terminals"], capture_output=True, env=ENV)
    subprocess.run(["pkill", "-f", SERVERS], capture_output=True)
    subprocess.run(["pkill", "-x", "sleep"], capture_output=True)
    # A server still exiting refuses the next start ("server exited
    # unexpectedly" from tmux): wait until every one is gone.
    for _ in range(100):
        if subprocess.run(["pgrep", "-f", SERVERS], capture_output=True).returncode:
            break
        time.sleep(0.05)


def start(kind):
    stop_all()
    if kind == "mux2":
        sh([MUX2, "stats"])
    elif kind == "tmux":
        sh(TMUX + ["new-session", "-d", "-s", "base", "-x", "80", "-y", "24", "sleep 100000"])
    else:
        state = f"{WORK}/cmux-state"
        subprocess.run(["rm", "-rf", state])
        os.makedirs(state)
        subprocess.Popen([CMUX, "daemon", "start", "--session", "bench", "--state", state],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env=ENV, start_new_session=True)
        for _ in range(200):
            if subprocess.run([CMUX, "daemon", "status", "--session", "bench"], capture_output=True, env=ENV).returncode == 0:
                break
            time.sleep(0.05)


def server_pid(kind):
    pat = {"mux2": "mux2d", "tmux": "tmux -L mux2bench", "cmux": "cmux-tui daemon start --session bench"}[kind]
    out = subprocess.run(["pgrep", "-of", pat], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def tree(pid):
    rows = {}
    for line in sh(["ps", "-e", "-o", "pid=,ppid=,rss=,comm="]).splitlines():
        p = line.split(None, 3)
        if len(p) == 4:
            rows[int(p[0])] = (int(p[1]), int(p[2]), p[3])
    kids, out, stack = {}, [], [pid]
    for k, (pp, _, _) in rows.items():
        kids.setdefault(pp, []).append(k)
    while stack:
        q = stack.pop()
        if q in rows:
            out.append((q,) + rows[q])
            stack.extend(kids.get(q, []))
    return out


def create(kind, i, argv):
    if kind == "mux2":
        cmd = [MUX2, "new", "--size", "80x24", "--"] + argv
    elif kind == "tmux":
        cmd = TMUX + ["new-window", "-d", "-t", "base", " ".join(argv)]
    else:
        cmd = [CMUX, "--session", "bench", "--json", "workspace", "create", "--name", f"b{i}", "--"] + argv
    t = time.perf_counter()
    sh(cmd)
    return time.perf_counter() - t


def scale(kind, n):
    start(kind)
    root = server_pid(kind)
    base = [r for r in tree(root) if r[0] == root][0][2]
    lat = [create(kind, i, ["/bin/sleep", "1000000"]) for i in range(n)]
    time.sleep(1)
    t = tree(root)
    server = [r for r in t if r[0] == root][0][2]
    helpers = [r for r in t if r[0] != root and r[3] != "sleep"]
    emit({"test": "scale", "kind": kind, "n": n,
          "create_ms_p50": round(1000 * statistics.median(lat), 2),
          "create_ms_p95": round(1000 * sorted(lat)[int(0.95 * (n - 1))], 2),
          "server_rss_kb": server, "server_kb_per_terminal": round((server - base) / n, 1),
          "helper_procs": len(helpers), "helper_rss_kb": sum(r[2] for r in helpers)})


def flood(kind, files):
    """Terminals each `cat` one file at once; aggregate MB/s and server CPU."""
    start(kind)
    root = server_pid(kind)
    cpu0 = cpu_s(root)
    t = time.perf_counter()
    if kind == "mux2":
        procs = [subprocess.Popen([MUX2, "run", "--size", "200x50", "--", "/bin/cat", f], env=ENV) for f in files]
        for p in procs:
            p.wait()
    elif kind == "tmux":
        for i, f in enumerate(files):
            sh(TMUX + ["new-window", "-d", "-t", "base", f"cat {f}; tmux -L mux2bench wait-for -S done{i}"])
        for i in range(len(files)):
            sh(TMUX + ["wait-for", f"done{i}"])
    else:
        terms = []
        for i, f in enumerate(files):
            r = json.loads(sh([CMUX, "--session", "bench", "--json", "workspace", "create", "--name", f"f{i}", "--", "/bin/cat", f]))
            terms.append(r["value"]["terminal_id"])
        for term in terms:
            sh([CMUX, "--session", "bench", "terminal", term, "process", "wait", "--timeout-ms", "900000"])
    dt = time.perf_counter() - t
    total = sum(os.path.getsize(f) for f in files)
    emit({"test": "flood", "kind": kind, "terminals": len(files), "file": os.path.basename(files[0]),
          "seconds": round(dt, 3), "aggregate_mb_s": round(total / dt / 1e6, 1),
          "server_cpu_s": round(cpu_s(root) - cpu0, 2)})


def cpu_s(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    tick = os.sysconf("SC_CLK_TCK")
    # utime + stime of the server and its reaped children (cutime, cstime).
    return sum(int(x) for x in fields[11:15]) / tick


def query(kind):
    start(kind)
    script = f"{HERE}/query-rtt.pl"
    out = f"{WORK}/q-{kind}.txt"
    cmd = ["/bin/sh", "-c", f"/usr/bin/perl {script} 1000 > /dev/tty; true"]
    # Run the probe, then read its JSON line from the screen.
    if kind == "mux2":
        tid = sh([MUX2, "new", "--size", "120x40", "--", "/usr/bin/perl", script, "1000"]).strip()
        sh([MUX2, "wait", tid])
        screen = sh([MUX2, "screen", tid])
    elif kind == "tmux":
        sh(TMUX + ["new-window", "-d", "-t", "base", "-n", "q", f"/usr/bin/perl {script} 1000; tmux -L mux2bench wait-for -S q; sleep 100"])
        sh(TMUX + ["wait-for", "q"])
        screen = sh(TMUX + ["capture-pane", "-p", "-t", "base:q"])
    else:
        r = json.loads(sh([CMUX, "--session", "bench", "--json", "workspace", "create", "--name", "q", "--",
                           "/bin/sh", "-c", f"/usr/bin/perl {script} 1000; sleep 100"]))
        term = r["value"]["terminal_id"]
        for _ in range(600):
            screen = sh([CMUX, "--session", "bench", "terminal", term, "screen", "read"])
            if "query_rtt" in screen or "BAD" in screen:
                break
            time.sleep(0.1)
    line = next((l for l in screen.splitlines() if "query_rtt" in l or "BAD" in l), "")
    emit({"test": "query", "kind": kind, "result": line.strip()})


if __name__ == "__main__":
    plain, sgr = f"{WORK}/c/plain.txt", f"{WORK}/c/sgr.txt"
    for kind in ["mux2", "cmux", "tmux"]:
        try:
            scale(kind, 200)
            flood(kind, [plain])
            flood(kind, [sgr])
            flood(kind, [plain] * 8)
            flood(kind, [sgr] * 8)
            query(kind)
        except Exception as e:  # report and continue with the next kind
            emit({"test": "error", "kind": kind, "error": str(e)[:400]})
    stop_all()
