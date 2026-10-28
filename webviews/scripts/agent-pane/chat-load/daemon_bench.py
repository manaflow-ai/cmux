#!/usr/bin/env python3
"""Chat-load benchmark, daemon stage (perf100; Linux, reads /proc). No model calls.

Opens each fixture chat (fixture.ts) the way the agent pane does (direct.ts `attach`): the same
`_acpmux/attach` params, then the reads the pane makes after it (the open turn's prompt, the
newest command list), then detach. Then it scrolls to the first message the way the pane's
loadOlder does (`_acpmux/events` beforeSeq pages of 256 KB, transcript kinds) and counts every
record, so a page that loses or repeats one fails the run.

usage: daemon_bench.py ACPMUX_BIN FIXTURE_JSON OUT_JSON [--repeat 3] [--listen 127.0.0.1:P --token T
                       --allow-dev-origin http://127.0.0.1:Q --keep-pidfile FILE]

With --keep-pidfile the daemon keeps running after the stage (the browser stage reuses it) and
its pid goes to FILE.

With PERF_RESULT_DIR set it also writes every run's numbers as result-v1 through
scripts/perf-lab/bench_results.py (perf_result.py): story webviews-chat-load-daemon, metrics
web.chat_load.daemon.* (perf_series).
"""
import argparse
import importlib.util
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time

OPEN_PAGE_BYTES = 128 * 1024
OLDER_PAGE_BYTES = 256 * 1024
ATTACH_KINDS = ["transcript", "available_commands_update", "usage_update", "config_option_update",
                "bookmarks", "secret_request", "secret_decision", "queue_order", "queue_updated", "prompt_refused"]


def cpu_s(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return (int(parts[11]) + int(parts[12])) / os.sysconf("SC_CLK_TCK")


def status(pid):
    out = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            k, _, v = line.partition(":")
            if k in ("VmRSS", "VmHWM"):
                out[k] = int(v.split()[0])
    return out


def io_read(pid):
    with open(f"/proc/{pid}/io") as f:
        for line in f:
            if line.startswith("rchar:"):
                return int(line.split()[1])
    return 0


def reset_hwm(pid):
    with open(f"/proc/{pid}/clear_refs", "w") as f:
        f.write("5")


class Rpc:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.w = self.sock.makefile("wb", buffering=0)
        self.r = self.sock.makefile("rb", buffering=1 << 20)
        self.next = 0
        self.replies = {}
        self.cond = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.r:
            msg = json.loads(line)
            if "id" in msg and ("result" in msg or "error" in msg):
                with self.cond:
                    self.replies[msg["id"]] = (msg, len(line))
                    self.cond.notify_all()

    def call(self, method, params, timeout=600):
        self.next += 1
        rid = self.next
        self.w.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        deadline = time.time() + timeout
        with self.cond:
            while rid not in self.replies:
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(method)
                self.cond.wait(left)
            msg, size = self.replies.pop(rid)
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg["result"], size


def measured(pid, fn):
    reset_hwm(pid)
    before = status(pid)["VmRSS"]
    c0, r0, t0 = cpu_s(pid), io_read(pid), time.perf_counter()
    result = fn()
    wall = time.perf_counter() - t0
    after = status(pid)
    return result, {"wall_ms": round(wall * 1000, 2), "cpu_ms": round((cpu_s(pid) - c0) * 1000, 1),
                    "read_mb": round((io_read(pid) - r0) / 1e6, 2), "peak_extra_mb": round((after["VmHWM"] - before) / 1024, 1)}


def open_chat(rpc, sid):
    """The pane's open: attach, then the reads direct.ts makes after it. Returns bytes and calls."""
    calls = []
    page, size = rpc.call("_acpmux/attach", {"sessionId": sid, "limit": 400, "maxBytes": OPEN_PAGE_BYTES,
                                             "kinds": ATTACH_KINDS, "eventStream": True, "visible": True})
    calls.append(("attach", size))
    events = page.get("events", [])
    first = events[0] if events else None
    if page.get("hasMore") and first and first["seq"] > 1 and not (first["kind"] == "user_message" and first["dir"] == "mux"):
        _, s = rpc.call("_acpmux/events", {"sessionId": sid, "beforeSeq": first["seq"], "limit": 16, "kinds": ["user_message"]})
        calls.append(("opener", s))
    kept = (page.get("session") or {}).get("availableCommands")
    if not kept and not any(e["kind"] == "available_commands_update" for e in events) and page.get("lastSeq", 0) > 0:
        _, s = rpc.call("_acpmux/events", {"sessionId": sid, "beforeSeq": page["lastSeq"] + 1, "limit": 1,
                                           "kinds": ["available_commands_update"]})
        calls.append(("commands", s))
    rpc.call("_acpmux/detach", {"sessionId": sid})
    return {"calls": [c for c, _ in calls], "bytes": sum(s for _, s in calls), "records": len(events),
            "has_more": page.get("hasMore"), "first_seq": first["seq"] if first else None}


def scroll_to_first(rpc, sid, first_seq):
    """Every older page as the pane's loadOlder reads it, to the first message."""
    pages, size, records, before, seqs = 0, 0, 0, first_seq, []
    while before and before > 1:
        r, s = rpc.call("_acpmux/events", {"sessionId": sid, "beforeSeq": before, "limit": 400,
                                           "maxBytes": OLDER_PAGE_BYTES, "kinds": ["transcript"]})
        pages += 1
        size += s
        ev = r.get("events", [])
        records += len(ev)
        seqs.extend(e["seq"] for e in ev)
        if not ev or not r.get("hasMore"):
            break
        before = ev[0]["seq"]
    return {"pages": pages, "bytes": size, "records": records, "min_seq": min(seqs) if seqs else None,
            "unique": len(set(seqs)) == len(seqs)}


PERF_STORY = "webviews-chat-load-daemon"
BENCH_RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..",
                             "scripts", "perf-lab", "bench_results.py")
# measured() field -> (result-v1 metric suffix, unit, factor back to the unit): read_mb is 1e6 bytes,
# peak_extra_mb is VmHWM KiB / 1024.
MEASURED_SERIES = {"wall_ms": ("wall", "ms", 1), "cpu_ms": ("cpu", "ms", 1),
                   "read_mb": ("read", "bytes", 1e6), "peak_extra_mb": ("peak_extra", "bytes", 2 ** 20)}


def perf_series(runs_by_turns, result):
    """The stage's result-v1 series: each open run (`runs_by_turns[turns]`, measured() rows) and the
    scroll to the first message under web.chat_load.daemon.t<turns>, and the daemon's final RSS."""
    series = []

    def add(metric, unit, samples):
        if samples:
            series.append({"metric": metric, "unit": unit, "better": "lower", "samples": samples})

    for row in result["sessions"]:
        prefix = f"web.chat_load.daemon.t{row['turns']}"
        for key, (name, unit, factor) in MEASURED_SERIES.items():
            add(f"{prefix}.open.{name}", unit, [run[key] * factor for run in runs_by_turns[row["turns"]]])
        add(f"{prefix}.open.bytes", "bytes", [row["open_bytes"]])
        scroll = row.get("scroll_to_first")
        if scroll and scroll.get("pages"):
            for key, (name, unit, factor) in MEASURED_SERIES.items():
                add(f"{prefix}.scroll.{name}", unit, [scroll[key] * factor])
            add(f"{prefix}.scroll.bytes", "bytes", [scroll["bytes"]])
            add(f"{prefix}.scroll.pages", "count", [scroll["pages"]])
    if "rss_mb" in result:
        add("web.chat_load.daemon.rss", "bytes", [result["rss_mb"] * 2 ** 20])
    return series


def record_perf_results(series, environ=os.environ):
    """Writes `series` as result-v1 when PERF_RESULT_DIR is set; returns the file's path or None."""
    if not environ.get("PERF_RESULT_DIR", "").strip() or not series:
        return None
    spec = importlib.util.spec_from_file_location("chat_load_bench_results", BENCH_RESULTS)
    bench_results = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = bench_results
    spec.loader.exec_module(bench_results)
    return bench_results.record({"story": PERF_STORY, "engine": "none", "results": series}, environ)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("fixture")
    ap.add_argument("out")
    ap.add_argument("--repeat", type=int, default=3)
    ap.add_argument("--listen")
    ap.add_argument("--token")
    ap.add_argument("--allow-dev-origin")
    ap.add_argument("--keep-pidfile")
    ap.add_argument("--scroll", default="1", help="0 skips the scroll to the first message")
    a = ap.parse_args()
    fixture = json.load(open(a.fixture))
    home = fixture["home"]
    scratch = os.path.join(os.path.dirname(home.rstrip("/")), "daemon-" + os.path.basename(home.rstrip("/")))
    os.makedirs(scratch, exist_ok=True)
    sock = os.path.join(scratch, "s.sock")
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"harnesses": {"fc": {"kind": "claude-stdio", "argv": ["false"]}}, "defaultHarness": "fc"}, f)
    os.chmod(os.path.join(home, "config.json"), 0o600)
    env = {"HOME": os.path.join(scratch, "uhome"), "PATH": "/usr/bin:/bin", "ACPMUX_HOME": home,
           "ACPMUX_SOCKET": sock, "TMPDIR": scratch, "RUST_LOG": "warn"}
    os.makedirs(env["HOME"], exist_ok=True)
    argv = [a.binary, "daemon", "run", "--log", "warn"]
    if a.listen:
        argv += ["--listen", a.listen, "--token", a.token]
    if a.allow_dev_origin:
        argv += ["--allow-dev-origin", a.allow_dev_origin, "--dev"]
    r, w = os.pipe()
    argv += ["--ready-fd", str(w)]
    proc = subprocess.Popen(argv, env=env, pass_fds=(w,), stdout=open(os.path.join(scratch, "daemon.out"), "w"),
                            stderr=subprocess.STDOUT, cwd=scratch, start_new_session=True)
    os.close(w)
    with os.fdopen(r) as rf:
        ready = rf.readline()
    if not ready:
        sys.exit("daemon did not start: " + open(os.path.join(scratch, "daemon.out")).read()[-2000:])
    pid = proc.pid
    rpc = Rpc(sock)
    rpc.call("session/list", {})
    result = {"stage": "daemon", "binary": a.binary, "host": socket.gethostname(), "sessions": []}
    runs_by_turns = {}
    try:
        for s in fixture["sessions"]:
            sid = s["id"]
            runs = []
            info = None
            for i in range(a.repeat):
                info, m = measured(pid, lambda: open_chat(rpc, sid))
                runs.append(m)
            runs_by_turns[s["turns"]] = runs
            row = {"turns": s["turns"], "records": s["records"], "log_mb": round(s["bytes"] / 1e6, 1),
                   "first_open": runs[0], "open": {k: statistics.median(r[k] for r in runs) for k in runs[0]},
                   "open_calls": info["calls"], "open_bytes": info["bytes"], "open_records": info["records"]}
            if a.scroll == "1" and info["has_more"]:
                sc, m = measured(pid, lambda: scroll_to_first(rpc, sid, info["first_seq"]))
                row["scroll_to_first"] = {**sc, **m}
            elif a.scroll == "1":
                row["scroll_to_first"] = {"pages": 0, "bytes": 0, "records": 0, "unique": True, "wall_ms": 0}
            result["sessions"].append(row)
            print(json.dumps(row), flush=True)
        result["rss_mb"] = round(status(pid)["VmRSS"] / 1024, 1)
        record_perf_results(perf_series(runs_by_turns, result))
    finally:
        json.dump(result, open(a.out, "w"), indent=1)
        if a.keep_pidfile:
            open(a.keep_pidfile, "w").write(str(pid))
        else:
            proc.terminate()
            proc.wait(30)


if __name__ == "__main__":
    main()
