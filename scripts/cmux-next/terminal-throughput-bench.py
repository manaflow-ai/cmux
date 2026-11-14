#!/usr/bin/env python3
"""Terminal throughput: one large output burst through a cmux NEXT terminal and through standalone Ghostty, on one Mac.

Leo, 2026-11-10: "we need to be adding more perf benchmarks". The CMUX-571 goal terminal-throughput reads the ratio
NEXT / Ghostty (target >= 1.0).

The same writer runs in both terminals: it reads a fixed payload (--mb MB of terminal text: plain lines, lines longer
than the grid, 256-color SGR runs, UTF-8) into memory, then writes it to its terminal in 64 KiB writes and waits with
tcdrain() until the terminal has read every byte off the PTY. MB/s is payload bytes / that time (1 MB = 10^6 bytes).
The terminal reads only as fast as it consumes, so the time is the terminal's, not the writer's; launch time and
font loading are outside it. Each terminal gets one warm-up burst (the first --warmup-mb MB), then --runs timed bursts;
the row is the median.

  NEXT     the tagged app (--app), launched once (bench_launch.BenchApp); each burst runs in a new focused terminal tab
           (action.run newTab with the writer as its command).
  Ghostty  the pinned standalone release (GHOSTTY_VERSION, sha256 checked; kept in $CI_SHARED_CACHE_DIR), or
           --ghostty-app. Each burst launches it with the writer as its command, the default config files off, and
           the grid NEXT's first burst reported (window-width/height in cells), so both draw the same columns and rows.

Rows (report.json `rows`, perf-cron.py kind budgets; reporting only, perf-cron.py judges no terminal.throughput row):
  terminal.throughput.next_mb_s, terminal.throughput.ghostty_mb_s (MB/s), terminal.throughput.ratio (x, NEXT/Ghostty).
Prints TERMINAL-THROUGHPUT lines. Exits 1 when a terminal gave no timed burst (the report says why in `incomplete`).

  terminal-throughput-bench.py --app "<cmux DEV tag.app>" --out DIR [--json FILE] [--mb 200] [--runs 3]
      [--warmup-mb 16] [--timeout 240] [--ghostty-app PATH] [--no-ghostty]
"""
import argparse, hashlib, json, os, platform, random, shlex, shutil, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

GHOSTTY_VERSION = "1.4.0"
GHOSTTY_DMG_SHA256 = "3a02075dbd24318d778426af41dee5507d53ecc4578ede96912ec9ce6d18d3e8"
GHOSTTY_URL = f"https://release.files.ghostty.org/{GHOSTTY_VERSION}/Ghostty.dmg"
MB = 1_000_000
# The writer, run as the terminal's command. argv: payload, result file, bytes to write (0: all).
WRITER = r'''
import json, os, sys, termios, time
src, result, limit = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src, "rb") as f:
    data = f.read(limit) if limit > 0 else f.read()
try:
    cols, rows = os.get_terminal_size(1)
except OSError:
    cols = rows = None
view, n, off, chunk = memoryview(data), len(data), 0, 65536
t0 = time.perf_counter()
while off < n:
    off += os.write(1, view[off:off + chunk])
termios.tcdrain(1)
t1 = time.perf_counter()
os.write(1, b"\x1b[0m\r\nterminal-throughput: done\r\n")
tmp = result + ".tmp"
with open(tmp, "w") as f:
    json.dump({"bytes": n, "seconds": t1 - t0, "cols": cols, "rows": rows}, f)
os.rename(tmp, result)
'''


def payload_block(seed=571, size=1 << 20):
    """About `size` bytes of terminal text, the same every run (pure)."""
    rng = random.Random(seed)
    words = ["cargo", "build", "warning:", "error[E0308]:", "src/main.rs:42:7", "Compiling", "Finished", "test", "ok",
             "PASS", "FAIL", "0x7ffee4b2c8a0", "GET", "/api/v1/sessions", "200", "1.24ms", "INFO", "DEBUG", "--release"]
    utf8 = ["é", "ü", "→", "✓", "✗", "日本語", "│", "─", "λ", "🙂"]
    out, total = [], 0
    while total < size:
        kind = rng.random()
        if kind < 0.05:
            line = ""
        elif kind < 0.30:
            line = " ".join(f"\x1b[38;5;{rng.randrange(256)}m{rng.choice(words)}\x1b[0m" for _ in range(rng.randrange(4, 14)))
        elif kind < 0.40:
            line = " ".join(rng.choice(words + utf8) for _ in range(rng.randrange(6, 20)))
        else:
            line = " ".join(rng.choice(words) for _ in range(rng.randrange(6, 30)))  # some lines wrap a 120-column grid
        b = (line + "\n").encode()
        out.append(b)
        total += len(b)
    return b"".join(out)


def write_payload(path, mb):
    block, want = payload_block(), mb * MB
    with open(path, "wb") as f:
        left = want
        while left > 0:
            f.write(block[:left])
            left -= min(left, len(block))
    return want


def wait_result(path, timeout, alive=lambda: True):
    """The writer's result, or None after `timeout` s or once `alive()` is False (the terminal went away)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
        if not alive():
            time.sleep(0.5)  # the result may land just as the terminal exits
            if os.path.exists(path):
                with open(path) as f:
                    return json.load(f)
            return None
        time.sleep(0.2)  # test harness: the writer's result file is its only signal
    return None


def summarize(runs):
    rates = [r["mb_s"] for r in runs if isinstance(r.get("mb_s"), (int, float))]
    return round(statistics.median(rates), 1) if rates else None


def run_record(label, i, res):
    if not res or not res.get("seconds"):
        return {"run": i, "error": "no result"}
    rec = {"run": i, "bytes": res["bytes"], "seconds": round(res["seconds"], 4),
           "mb_s": round(res["bytes"] / MB / res["seconds"], 1), "cols": res.get("cols"), "rows": res.get("rows")}
    print("TERMINAL-THROUGHPUT " + json.dumps({"terminal": label, **rec}), flush=True)
    return rec


def measure_next(opts, writer, payload, scratch):
    from bench_launch import BenchApp
    out = {"runs": []}
    app = BenchApp(opts.app, out=os.path.join(opts.out, "next"))
    try:
        app.launch()
        time.sleep(3)  # test harness: let the first window settle before the first burst
        plan = [("warmup", opts.warmup_mb * MB)] + [(i, 0) for i in range(1, opts.runs + 1)]
        for i, limit in plan:
            result = os.path.join(scratch, f"next-{i}.json")
            cmd = " ".join(shlex.quote(a) for a in ["/usr/bin/python3", "-I", writer, payload, result, str(limit)])
            reply = app.rpc("action.run", {"action": "newTab", "args": {"name": f"throughput-{i}", "focus": True,
                                                                         "command": cmd}})
            if isinstance(reply, dict) and reply.get("error"):
                out["error"] = f"newTab: {reply['error']}"
                break
            res = wait_result(result, opts.timeout, alive=lambda: app.process.poll() is None)
            if i == "warmup":
                out["warmup"] = run_record("next-warmup", 0, res)
                continue
            out["runs"].append(run_record("next", i, res))
    except Exception as e:  # a failed launch (LaunchError printed its report) or a dead socket
        out["error"] = f"{type(e).__name__}: {e}"[:400]
    finally:
        app.stop()
    return out


def ghostty_app(opts, scratch):
    """(path to Ghostty.app, version) or (None, why)."""
    if opts.ghostty_app:
        return (opts.ghostty_app, "given") if os.path.isdir(opts.ghostty_app) else (None, f"no app at {opts.ghostty_app}")
    cache_root = os.environ.get("CI_SHARED_CACHE_DIR")
    home = os.path.join(cache_root, "ghostty-standalone", GHOSTTY_VERSION) if cache_root else os.path.join(scratch, "ghostty")
    app = os.path.join(home, "Ghostty.app")
    if os.path.isfile(os.path.join(home, "ok")) and os.path.isdir(app):
        return app, GHOSTTY_VERSION
    os.makedirs(home, exist_ok=True)
    dmg, mnt, tmp_app = os.path.join(scratch, "Ghostty.dmg"), os.path.join(scratch, "ghostty-mnt"), app + ".tmp"
    got = subprocess.run(["curl", "-fsSL", "--retry", "3", "--retry-all-errors", "-m", "600", "-o", dmg, GHOSTTY_URL],
                         capture_output=True, text=True)
    if got.returncode != 0:
        return None, f"download {GHOSTTY_URL}: {got.stderr.strip()[:200]}"
    with open(dmg, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != GHOSTTY_DMG_SHA256:
        return None, f"{GHOSTTY_URL} sha256 {digest}, want {GHOSTTY_DMG_SHA256}"
    os.makedirs(mnt, exist_ok=True)
    att = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mnt, dmg],
                         capture_output=True, text=True)
    if att.returncode != 0:
        return None, f"hdiutil attach: {att.stderr.strip()[:200]}"
    try:
        shutil.rmtree(tmp_app, ignore_errors=True)
        cp = subprocess.run(["ditto", os.path.join(mnt, "Ghostty.app"), tmp_app], capture_output=True, text=True)
        if cp.returncode != 0:
            return None, f"ditto: {cp.stderr.strip()[:200]}"
    finally:
        subprocess.run(["hdiutil", "detach", mnt, "-force"], capture_output=True)
    shutil.rmtree(app, ignore_errors=True)
    os.rename(tmp_app, app)
    open(os.path.join(home, "ok"), "w").close()
    return app, GHOSTTY_VERSION


def measure_ghostty(opts, writer, payload, scratch, grid):
    out = {"runs": []}
    app, version = ghostty_app(opts, scratch)
    if not app:
        out["error"] = version
        return out
    out["app"], out["version"] = app, version
    binary = os.path.join(app, "Contents", "MacOS", "ghostty")
    env = dict(os.environ, XDG_CONFIG_HOME=os.path.join(scratch, "xdg"))
    cols, rows = grid if grid and all(grid) else (120, 40)
    out["grid_requested"] = [cols, rows]
    plan = [("warmup", opts.warmup_mb * MB)] + [(i, 0) for i in range(1, opts.runs + 1)]
    for i, limit in plan:
        result = os.path.join(scratch, f"ghostty-{i}.json")
        cmd = " ".join(shlex.quote(a) for a in ["/usr/bin/python3", "-I", writer, payload, result, str(limit)])
        argv = [binary, "--config-default-files=false", f"--command={cmd}", "--wait-after-command=false",
                "--quit-after-last-window-closed=true", "--confirm-close-surface=false", "--window-save-state=never",
                "--auto-update=off", f"--window-width={cols}", f"--window-height={rows}"]
        log = open(os.path.join(opts.out, f"ghostty-{i}.log"), "w")
        proc = subprocess.Popen(argv, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            res = wait_result(result, opts.timeout, alive=lambda: proc.poll() is None)
        finally:
            try:
                proc.wait(15)  # it quits once its last window closes
            except subprocess.TimeoutExpired:
                proc.terminate()  # the PID this script started
                try:
                    proc.wait(10)
                except subprocess.TimeoutExpired:
                    proc.kill()
            log.close()
        if i == "warmup":
            out["warmup"] = run_record("ghostty-warmup", 0, res)
            continue
        out["runs"].append(run_record("ghostty", i, res))
    return out


def report_rows(next_mb_s, ghostty_mb_s):
    """The report's rows (pure): each MB/s median and their ratio, when both are known."""
    rows = []
    for name, v, unit in (("terminal.throughput.next_mb_s", next_mb_s, "MB/s"),
                          ("terminal.throughput.ghostty_mb_s", ghostty_mb_s, "MB/s")):
        if v is not None:
            rows.append({"name": name, "p50": v, "p95": v, "unit": unit, "budget": None, "floor": round(0.1 * v, 1)})
    if next_mb_s and ghostty_mb_s:
        ratio = round(next_mb_s / ghostty_mb_s, 3)
        rows.append({"name": "terminal.throughput.ratio", "p50": ratio, "p95": ratio, "unit": "x", "budget": None,
                     "floor": 0.1})
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring-terminal.py passes it; the app path names the tag
    parser.add_argument("--mb", type=int, default=200)
    parser.add_argument("--warmup-mb", type=int, default=16)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=240)
    parser.add_argument("--ghostty-app")
    parser.add_argument("--no-ghostty", action="store_true")
    opts = parser.parse_args(argv)
    os.makedirs(opts.out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="tput.", dir="/private/tmp" if os.path.isdir("/private/tmp") else None)
    try:
        writer = os.path.join(scratch, "writer.py")
        with open(writer, "w") as f:
            f.write(WRITER)
        payload = os.path.join(scratch, "payload.txt")
        size = write_payload(payload, opts.mb)
        report = {"suite": "terminal-throughput", "payload_bytes": size, "runs_per_terminal": opts.runs,
                  "host": platform.node(), "incomplete": []}
        report["next"] = measure_next(opts, writer, payload, scratch)
        first = next((r for r in report["next"]["runs"] if r.get("cols")), report["next"].get("warmup") or {})
        grid = (first.get("cols"), first.get("rows"))
        if opts.no_ghostty:
            report["ghostty"] = {"runs": [], "error": "--no-ghostty"}
        else:
            report["ghostty"] = measure_ghostty(opts, writer, payload, scratch, grid)
        next_mb_s, ghostty_mb_s = summarize(report["next"]["runs"]), summarize(report["ghostty"]["runs"])
        report["next"]["median_mb_s"], report["ghostty"]["median_mb_s"] = next_mb_s, ghostty_mb_s
        for label, v in (("next", next_mb_s), ("ghostty", ghostty_mb_s)):
            if v is None:
                report["incomplete"].append({"name": f"terminal.throughput.{label}_mb_s",
                                             "reason": report[label].get("error") or "no timed burst"})
        report["rows"] = report_rows(next_mb_s, ghostty_mb_s)
        if not report["incomplete"]:
            del report["incomplete"]
        print("TERMINAL-THROUGHPUT-SUMMARY " + json.dumps({"next_mb_s": next_mb_s, "ghostty_mb_s": ghostty_mb_s,
                                                           "ratio": next((r["p50"] for r in report["rows"]
                                                                          if r["name"].endswith(".ratio")), None),
                                                           "host": report["host"], "payload_mb": opts.mb}), flush=True)
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
        return 0 if next_mb_s is not None and (ghostty_mb_s is not None or opts.no_ghostty) else 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
