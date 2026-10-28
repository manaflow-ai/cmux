#!/usr/bin/env python3
"""Pro audit 11 daemon suite: the cmux-tui benches benchmark.md names, on one binary, one host (scratch, never lands).

  1. bench-scale.py          memory per terminal (macOS footprint, Linux PSS), threads, idle CPU and wakeups at 1, 10
                             and 100 idle terminals; key -> echo (send on the control socket -> the echoed bytes on an
                             attach stream)
  2. bench-terminal-perf.py  idle memory at 1/10/100, memory per 10,000 lines of scrollback, throughput (cat 150 MB),
                             busy CPU
  3. bench-lifecycle.py      new tab, split, new workspace latency (send -> reply)
  4. attach                  connect + attach-surface -> its reply (vt-state first) for a fresh terminal and for one with
                             10,000 lines of scrollback, and key -> echo on that attach

  bench-daemon-suite.py --bin target/release/cmux-tui --out FILE.json [--quick]
"""
import argparse
import base64
import importlib.util
import json
import os
import platform
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("bench_scale", os.path.join(HERE, "bench-scale.py"))
bs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bs)


def log(*parts):
    print("DAEMON-SUITE", *parts, flush=True)


def child(script, args, out, timeout):
    t0 = time.time()
    try:
        r = subprocess.run([sys.executable, os.path.join(HERE, script), *args, "--out", out], capture_output=True,
                           text=True, timeout=timeout)
        tail = (r.stdout + r.stderr)[-4000:]
        code = r.returncode
    except subprocess.TimeoutExpired as error:
        tail, code = str(error), 124
    for line in tail.splitlines():
        if line.startswith(("TERMINAL-PERF", "LIFECYCLE", "{")) or "rss/each" in line:
            print(line, flush=True)
    try:
        report = json.load(open(out))
    except (OSError, ValueError):
        report = None
    return {"exit": code, "seconds": round(time.time() - t0, 1), "report": report, "tail": tail[-1500:] if code else ""}


def attach_bench(binary, samples):
    root = tempfile.mkdtemp(prefix="a11att.", dir="/private/tmp" if sys.platform == "darwin" else None)
    args = argparse.Namespace(bin=binary, mode="durable", shell=["/bin/sh"], busy_fraction=0.0, busy_rate=1,
                              busy_line_bytes=80, per_workspace=1000000, fill="sequential", create_concurrency=2,
                              settle_seconds=3, settle_seconds_min=3, idle_seconds=5, latency_terminals=1,
                              latency_samples=1, topology_samples=1, out=None, root_dir=root, keep_root=False,
                              counts="1")
    bench = bs.Bench(args)
    out = {}
    try:
        bench.start()
        bench.setup_workspaces(1)
        surface = bench.terminals[0]["surface"]
        ctl = bs.Conn(bench.sock_path)

        def attach_once(rows):
            t0 = time.perf_counter()
            att = bs.Conn(bench.sock_path, timeout=30)
            att.send_line({"id": 1, "cmd": "attach-surface", "surface": surface, "cols": 120, "rows": rows})
            first = None
            while True:
                m = att.read_line()
                if first is None:
                    first = (time.perf_counter() - t0) * 1000
                if m.get("id") == 1:
                    ok = m.get("ok")
                    break
            done = (time.perf_counter() - t0) * 1000
            return att, first, done, ok

        def series(label):
            firsts, dones = [], []
            for _ in range(samples):
                att, first, done, ok = attach_once(40)
                att.close()
                if ok:
                    firsts.append(first)
                    dones.append(done)
                time.sleep(0.05)
            out[label] = {"first_message_ms": bs.latency_summary(firsts) if firsts else None,
                          "reply_ms": bs.latency_summary(dones) if dones else None}
            log("attach", label, json.dumps(out[label]))

        series("fresh")
        bs.must(ctl.call("send", surface=surface, text="i=0; while [ $i -lt 10000 ]; do i=$((i+1)); echo \"$i "
                         "the quick brown fox jumps over the lazy dog 0123456789 abcdefghij\"; done\n"), "send")
        time.sleep(8)
        series("scrollback_10k")
        att, *_ = attach_once(40)
        lat = []
        for k in range(samples):
            marker = f"z{k:06d}q"
            t0 = time.perf_counter()
            bs.must(ctl.call("send", surface=surface, text=marker), "send")
            got, deadline = b"", time.time() + 5
            while time.time() < deadline:
                m = att.read_line()
                if m.get("event") == "output" and m.get("surface") == surface:
                    got += base64.b64decode(m.get("data", ""))
                    if marker.encode() in got:
                        lat.append((time.perf_counter() - t0) * 1000)
                        break
            ctl.call("send", surface=surface, text="\x15")
            time.sleep(0.02)
        att.close()
        out["key_echo_attached_ms"] = bs.latency_summary(lat) if lat else None
        log("attach key_echo", json.dumps(out["key_echo_attached_ms"]))
        ctl.close()
    except Exception as error:  # noqa: BLE001
        out["error"] = repr(error)
        out["daemon_log"] = bench.tail_log()[-1500:] if bench.daemon else ""
    finally:
        try:
            bench.stop()
        except Exception as error:  # noqa: BLE001
            out["teardown_error"] = repr(error)
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bin", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--quick", action="store_true")
    a = p.parse_args()
    work = os.path.dirname(os.path.abspath(a.out))
    os.makedirs(work, exist_ok=True)
    host = {"platform": platform.platform(), "machine": platform.machine(), "cpus": os.cpu_count(),
            "node": platform.node(), "load": os.getloadavg()}
    if sys.platform == "darwin":
        host["chip"] = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True,
                                      text=True).stdout.strip()
    else:
        try:
            host["cpu"] = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
        except (OSError, StopIteration):
            pass
    result = {"bin": a.bin, "host": host, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    log("host", json.dumps(host))

    def flush():
        with open(a.out, "w") as f:
            json.dump(result, f, indent=1)
    quick = a.quick
    result["scale"] = child("bench-scale.py", ["--bin", a.bin, "--counts", "1,10,100", "--busy-fraction", "0",
                                               "--idle-seconds", "10" if quick else "20", "--settle-seconds", "20",
                                               "--settle-seconds-min", "5", "--latency-terminals", "10",
                                               "--latency-samples", "50" if quick else "200", "--topology-samples",
                                               "20"], os.path.join(work, "suite-scale.json"), 1800)
    flush()
    result["terminal_perf"] = child("bench-terminal-perf.py", ["--bin", a.bin, "--counts", "1,10,100", "--cat-mb",
                                                               "20" if quick else "150"],
                                    os.path.join(work, "suite-terminal-perf.json"), 1800)
    flush()
    result["lifecycle"] = child("bench-lifecycle.py", ["--bin", a.bin, "--rounds", "10" if quick else "40"],
                                os.path.join(work, "suite-lifecycle.json"), 1200)
    flush()
    result["attach"] = attach_bench(a.bin, 10 if quick else 40)
    result["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    flush()
    log("done", a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
