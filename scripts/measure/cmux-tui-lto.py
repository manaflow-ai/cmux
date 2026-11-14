#!/usr/bin/env python3
"""Helper of scripts/measure/cmux-tui-lto.sh (see there).

  cmux-tui-lto.py members      the workspace crates in cmux-tui's aarch64-apple-darwin graph, one per
                               line (from cmux-tui/), minus the zig and go build-script crates
  cmux-tui-lto.py measure ...  sizes, cargo timings, startup and bench; writes OUT/report.json and
                               prints LTO-* lines
"""

import argparse
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time

TARGET = "aarch64-apple-darwin"
KEEP_BUILT = {"ghostty-vt-sys", "cmux-tailnet"}


def members():
    meta = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1", "--locked", "--filter-platform", TARGET]))
    ws = set(meta["workspace_members"])
    names = {p["id"]: p["name"] for p in meta["packages"]}
    nodes = {n["id"]: n for n in meta["resolve"]["nodes"]}
    root = next(i for i in ws if names[i] == "cmux-tui")
    seen, todo = set(), [root]
    while todo:
        i = todo.pop()
        if i in seen:
            continue
        seen.add(i)
        for d in nodes[i]["deps"]:
            if any(k.get("kind") in (None, "build") for k in d["dep_kinds"]):
                todo.append(d["pkg"])
    for name in sorted({names[i] for i in seen & ws} - KEEP_BUILT):
        print(name)


def pct(values, q):
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(q * (len(s) - 1)))))
    return s[k]


def dist(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {"n": len(values), "p50": round(statistics.median(values), 2), "p95": round(pct(values, 0.95), 2),
            "min": round(min(values), 2), "max": round(max(values), 2), "mean": round(statistics.fmean(values), 2)}


def timings(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"const UNIT_DATA = (\[.*?\]);", text, re.S)
    units = json.loads(m.group(1)) if m else []
    wall = max((u["start"] + u["duration"] for u in units), default=None)
    rows = sorted(units, key=lambda u: -u["duration"])
    top = [{"name": u["name"], "target": u.get("target", ""), "mode": u.get("mode"), "s": round(u["duration"], 1)}
           for u in rows[:8]]
    bins = [{"target": u.get("target", "").strip(), "start": round(u["start"], 1), "s": round(u["duration"], 1)}
            for u in units if u["name"] == "cmux-tui" and "bin" in u.get("target", "")]
    lib = [round(u["duration"], 1) for u in units if u["name"] == "cmux-tui" and u.get("target", "").strip() in ("", "lib")]
    return {"units": len(units), "cargo_wall_s": round(wall, 1) if wall else None, "top_units": top,
            "cmux_tui_bin_units": bins, "cmux_tui_lib_s": lib}


def links(path):
    out = []
    for line in open(path):
        parts = line.split()
        if len(parts) == 3 and parts[0].startswith("cmux_tui") or (len(parts) == 3 and parts[0].startswith("cmux-tui")):
            out.append({"output": parts[0], "s": float(parts[1]), "rc": int(parts[2])})
    return out


def purge():
    started = time.perf_counter()
    ok = subprocess.run(["sudo", "-n", "/usr/sbin/purge"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL).returncode == 0
    return ok, time.perf_counter() - started


def run_version(binary):
    started = time.perf_counter()
    subprocess.run([binary, "--version"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True, timeout=60)
    return (time.perf_counter() - started) * 1000


def identify(path):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(2.0)
            conn.connect(path)
            conn.sendall(b'{"id":1,"cmd":"identify"}\n')
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(65536)
                if not chunk:
                    return None
                data += chunk
            return json.loads(data.split(b"\n", 1)[0])
    except (OSError, ValueError):
        return None


def daemon_start(binary, label):
    """A headless daemon on an empty state, as the app starts it: ms to listen and to lifecycle_ready."""
    root = tempfile.mkdtemp(prefix="lto-d.", dir="/private/tmp")
    home, state, sock = os.path.join(root, "h"), os.path.join(root, "s"), os.path.join(root, "m.sock")
    os.makedirs(home, mode=0o700)
    os.makedirs(state, mode=0o700)
    env = {k: v for k, v in os.environ.items() if k not in ("ACPMUX_HOME", "ACPMUX_SOCKET", "CMUX_TUI_SOCKET")}
    env.update(HOME=home, ACPMUX_HOME=os.path.join(home, ".acpmux"), CMUX_TUI_STATE_DIR=state,
               CMUX_TUI_CONFIG=os.path.join(home, "config.json"), CMUX_TUI_LOG_FILE=os.path.join(home, "client.log"),
               XDG_CONFIG_HOME=os.path.join(home, ".config"), XDG_STATE_HOME=os.path.join(home, ".local/state"),
               XDG_DATA_HOME=os.path.join(home, ".local/share"), XDG_CACHE_HOME=os.path.join(home, ".cache"))
    session = "lto" + label
    log = open(os.path.join(root, "owner.log"), "wb")
    started = time.perf_counter()
    child = subprocess.Popen([binary, "--headless", "--session", session, "--socket", sock], env=env,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, start_new_session=True)
    listen = ready = None
    deadline = started + 60
    while time.perf_counter() < deadline and child.poll() is None:
        if listen is None:
            if os.path.exists(sock):
                listen = time.perf_counter() - started
            else:
                time.sleep(0.001)
                continue
        reply = identify(sock)
        if reply is not None and (reply.get("data") or {}).get("lifecycle_ready") is True:
            ready = time.perf_counter() - started
            break
        time.sleep(0.002)
    exited = child.poll()
    subprocess.run([binary, "server", "stop", "--session", session, "--end-terminals", "--socket", sock], env=env,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
    try:
        child.wait(timeout=60)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
    log.close()
    tail = ""
    if ready is None:
        tail = open(os.path.join(root, "owner.log"), errors="replace").read()[-600:]
    shutil.rmtree(root, ignore_errors=True)
    ms = lambda v: None if v is None else round(v * 1000, 2)  # noqa: E731
    return {"listen_ms": ms(listen), "ready_ms": ms(ready), "exited_early": exited, "tail": tail}


def measure(a):
    out, variants = a.out, a.variants.split()
    report = {"host": os.uname().nodename, "variants": {}, "startup": {}, "bench": {}}
    for v in variants:
        b = os.path.join(out, v, "bin")
        pkg = os.path.join(out, v, "pkg")
        size = lambda p: os.path.getsize(p)  # noqa: E731
        row = {
            "cmux_unstripped_bytes": size(os.path.join(b, "cmux.unstripped")),
            "cmux_stripped_bytes": size(os.path.join(b, "cmux")),
            "cmux_tui_host_stripped_bytes": size(os.path.join(b, "cmux-tui-host")),
            "zip_bytes": size(os.path.join(pkg, "cmux.zip")),
            "dmg_ulfo_bytes": size(os.path.join(pkg, "cmux-ulfo.dmg")),
            "dmg_udzo_bytes": size(os.path.join(pkg, "cmux-udzo.dmg")),
            "symlinks": {n: os.readlink(os.path.join(b, n)) for n in ("cmux-tui", "acpmux")},
            "acpmux_version": open(os.path.join(out, v, "acpmux-version.txt"), errors="replace").read().strip()[:200],
            "timings": timings(os.path.join(out, f"timings-{v}.html")),
            "links": links(os.path.join(out, f"links-{v}.txt")),
        }
        report["variants"][v] = row
        print("LTO-SIZE " + v + " " + json.dumps({k: row[k] for k in row if k.endswith("bytes")}), flush=True)
        print("LTO-TIMINGS " + v + " " + json.dumps(row["timings"]) + " links " + json.dumps(row["links"]), flush=True)
    bins = {v: os.path.join(out, v, "bin", "cmux") for v in variants}
    daemon_bins = {v: os.path.join(out, v, "bin", "cmux-tui") for v in variants}
    purge_ok, purge_s = purge()
    print(f"LTO-PURGE ok={purge_ok} s={purge_s:.2f}", flush=True)
    # One untimed daemon start per binary: a new binary's first start pays one-time costs.
    for v in variants:
        daemon_start(daemon_bins[v], f"w{v}")
        for _ in range(5):
            run_version(bins[v])
    samples = {v: {"version_cold": [], "version_warm": [], "daemon_cold_listen": [], "daemon_cold_ready": [],
                   "daemon_warm_listen": [], "daemon_warm_ready": [], "purge_s": [], "failures": []} for v in variants}
    for r in range(a.rounds):
        order = variants[r % len(variants):] + variants[:r % len(variants)]
        for v in order:
            s = samples[v]
            if purge_ok:
                _, p = purge()
                s["purge_s"].append(round(p, 2))
                s["version_cold"].append(run_version(bins[v]))
                purge()
                d = daemon_start(daemon_bins[v], f"c{v}{r}")
                s["daemon_cold_listen"].append(d["listen_ms"])
                s["daemon_cold_ready"].append(d["ready_ms"])
                if d["ready_ms"] is None:
                    s["failures"].append(d)
            s["version_warm"].append(run_version(bins[v]))
            d = daemon_start(daemon_bins[v], f"h{v}{r}")
            s["daemon_warm_listen"].append(d["listen_ms"])
            s["daemon_warm_ready"].append(d["ready_ms"])
            if d["ready_ms"] is None:
                s["failures"].append(d)
        print(f"LTO-ROUND {r} " + json.dumps({v: {k: (round(x[-1], 2) if x and isinstance(x[-1], float) else None)
                                                   for k, x in samples[v].items() if k not in ("failures", "purge_s")}
                                              for v in variants}), flush=True)
    for v in variants:
        summary = {k: dist(x) for k, x in samples[v].items() if k not in ("failures", "purge_s")}
        summary["purge_s"] = dist(samples[v]["purge_s"])
        summary["failures"] = samples[v]["failures"][:3]
        summary["samples"] = {k: x for k, x in samples[v].items() if k != "failures"}
        report["startup"][v] = summary
        print("LTO-STARTUP " + v + " " + json.dumps({k: summary[k] for k in summary if k not in ("samples",)}), flush=True)
    # The hot-path bench: bench-terminal-perf.py throughput (64 MB cat through host and daemon) and busy CPU.
    bench = {v: [] for v in variants}
    for r in range(a.bench_rounds):
        order = variants[r % len(variants):] + variants[:r % len(variants)]
        for v in order:
            path = os.path.join(out, f"bench-{v}-{r}.json")
            proc = subprocess.run([sys.executable, a.bench, "--bin", daemon_bins[v], "--counts", "1",
                                   "--fill-terminals", "2", "--fill-lines", "2000", "--cat-mb", "64",
                                   "--busy-terminals", "10", "--busy-seconds", "10", "--settle", "2", "--out", path],
                                  stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=900)
            lines = [l for l in proc.stdout.splitlines() if l.startswith("TERMINAL-PERF")]
            print(f"LTO-BENCH {v} {r} rc={proc.returncode} " + " | ".join(lines), flush=True)
            try:
                bench[v].append(json.load(open(path)))
            except (OSError, ValueError):
                bench[v].append({"error": proc.stderr[-800:]})
    for v in variants:
        tp = [x["throughput"]["mb_per_s"] for x in bench[v] if x.get("throughput")]
        secs = [x["throughput"]["seconds"] for x in bench[v] if x.get("throughput")]
        dcpu = [x["busy"]["cpu_pct"]["daemon"] for x in bench[v] if x.get("busy")]
        hcpu = [x["busy"]["cpu_pct"]["hosts"] for x in bench[v] if x.get("busy")]
        report["bench"][v] = {"throughput_mb_per_s": dist(tp), "throughput_s": dist(secs),
                              "busy_daemon_cpu_pct": dist(dcpu), "busy_hosts_cpu_pct": dist(hcpu),
                              "runs": bench[v]}
        print("LTO-BENCHSUM " + v + " " + json.dumps({k: y for k, y in report["bench"][v].items() if k != "runs"}),
              flush=True)
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("members")
    m = sub.add_parser("measure")
    m.add_argument("--out", required=True)
    m.add_argument("--variants", required=True)
    m.add_argument("--rounds", type=int, default=30)
    m.add_argument("--bench-rounds", type=int, default=5)
    m.add_argument("--bench", required=True)
    a = p.parse_args()
    if a.cmd == "members":
        members()
    else:
        measure(a)


if __name__ == "__main__":
    main()
