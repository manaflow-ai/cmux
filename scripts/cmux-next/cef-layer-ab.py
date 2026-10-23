#!/usr/bin/env python3
"""Chromium page window vs layer hosting (fork API 26), A/B in a real window (plans/cmux-next/cef-layer-hosting-DESIGN.md).

Runs the existing benches twice on one tagged build: once with `browserResize.layerHosting` off (the page is a child
window over its pane) and once on (the page's pixels in the cmux window's layer tree). Before each mode's benches,
cef-layer-verify.py --checks hosted --tunables build launches the build the way the benches do, sets the tunable in
the build's own debug-tunables.json (the path the app reports, which every bench launch reads) and checks that the
mode is real. A mode that fails runs no benches and fails the run, so two "off" runs are never labelled off/on.

Each bench launch is checked too, from its own app (the benches start the app themselves): a reader reads `debug.cef`
once Chromium is ready in that launch, then every --cef-every seconds until the bench ends (one main-thread socket
command each; the read times are in summary.json, to match against an outlier). The bench is valid when it saw a
ready Chromium, every read has no `unavailable` and no `fallback`, and in mode on windows.fork_api >= 26 and
layer_hosting.hosted_pages >= 1 at some read, in mode off hosted_pages == 0 at every read. An invalid bench keeps
its rows, is marked `valid: false` and fails the run.

  switch     sidebar-stress-bench.py switch_matrix at --workspaces workspaces (10 tickers): Chromium and terminal
             workspaces, click / Cmd-digit / Ctrl-Cmd-] ; input to commit (`debug.workspace_switch`), longest frame
  tabs       tab-switch-matrix.py --kinds chromium: Ctrl-Tab, Cmd-Shift-], clicks; input + apply + commit
  light      pane-perf-terminal.py --browser (the top-left pane is a Chromium page): split, close, drag, scroll
  stress     pane-perf-terminal.py --layouts stress --stress-selected chromium: the standard STRESS session
             (perf-stress-session.py: 60 workspaces, the measured one 4x3 panes x 6 mixed tabs with Chromium shown,
             10 background Chromium workspaces, 10 printing terminals, nested splits); its STRESS-SESSION line is in
             summary.json

Slice 1 moves only the page's pixels: the page window still takes its per-frame setFrame, its order in and out on
hide and show, and the tracker's clip and occlusion reads (slice 3 removes the orders). So off vs on shows tearing
parity and what still costs, not a speed gain: summary.json `cost` has, per mode and bench, the change of
tracker.geometry_posts, tracker.clip_reads and layer_hosting.fork_calls between the first and last read.

Each run writes OUT/<mode>/<bench>/ (the bench's own report). OUT/summary.json holds the headline rows side by side.
Read the display refresh rate from the pane-perf reports (`refresh_hz`) and judge drops in frames.

The build's debug-tunables.json is put back as it was before the run (its first contents, or no file) when the run
ends, fails, or gets SIGINT, SIGTERM or SIGHUP, so a later bench or dogfood launch of the build never runs with
hosting on unseen. A SIGKILL cannot be caught: then rerun with --modes off, which sets it off again.

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-layer-ab.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS"
Not a gate: it never fails on a number. Exit 1 when a mode or a bench launch is not what it says, or a bench left no
report (a launch failure or a crash exits 1 too, so the exit code alone does not tell a budget miss from no result).
"""
import argparse, json, os, signal, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
KEY = "browserResize.layerHosting"
LAYER_HOSTING_FORK_API = 26

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--modes", default="off,on", help="off = page child windows, on = layer hosting")
parser.add_argument("--benches", default="switch,tabs,light,stress")
parser.add_argument("--workspaces", type=int, default=60)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--cef-every", type=float, default=5.0, help="seconds between debug.cef reads in a bench launch")
opts = parser.parse_args()
SOCKETS = (f"/tmp/cmux-debug-{opts.tag}.sock", os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{opts.tag}.sock"))


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# The build's tunables file as it was before this run: (path, text or None for no file). Restored on every way out.
ORIGINAL = {}


def remember_original(facts):
    path = facts.get("tunables_file")
    if path and "path" not in ORIGINAL:
        ORIGINAL.update(path=path, text=facts.get("tunables_original"))


def restore_tunables():
    path = ORIGINAL.get("path")
    if not path:
        return
    try:
        if ORIGINAL.get("text") is None:
            if os.path.exists(path):
                os.remove(path)
        else:
            with open(path, "w") as f:
                f.write(ORIGINAL["text"])
        print(f"== restored {path}", flush=True)
    except OSError as error:
        print(f"== could not restore {path}: {error}", flush=True)


CHILD = {}


def on_signal(number, _frame):
    child = CHILD.get("proc")
    if child and child.poll() is None:
        child.send_signal(signal.SIGTERM)  # our own child: its finally quits the app it launched
        try:
            child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            child.kill()
    sys.exit(128 + number)  # the `finally` around main() puts the tunables file back


for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, on_signal)


def run(command, log_path):
    with open(log_path, "w") as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        CHILD["proc"] = child
        code = child.wait()
        CHILD.pop("proc", None)
    return code


def rpc(method, timeout=10):
    for path in SOCKETS:
        if not os.path.exists(path):
            continue
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
            if reply.get("ok"):
                return reply.get("result")
        except (OSError, ValueError):
            continue
    return None


class CefReader(threading.Thread):
    """debug.cef of the bench's own app launch: once Chromium is ready, then every --cef-every seconds."""

    def __init__(self):
        super().__init__(daemon=True)
        self.reads, self.done = [], threading.Event()
        self.started = time.time()

    def run(self):
        while not self.done.is_set():
            cef = rpc("debug.cef")
            if isinstance(cef, dict) and cef.get("state") == "ready":
                tracker, hosting = cef.get("tracker") or {}, cef.get("layer_hosting") or {}
                self.reads.append({
                    "t_s": round(time.time() - self.started, 2), "unavailable": cef.get("unavailable"),
                    "fallback": cef.get("fallback"), "fork_api": (cef.get("windows") or {}).get("fork_api") or 0,
                    "hosted_pages": hosting.get("hosted_pages"), "host_views": hosting.get("host_views"),
                    "refusals": hosting.get("refusals"), "fork_calls": hosting.get("fork_calls"),
                    "geometry_posts": tracker.get("geometry_posts"), "clip_reads": tracker.get("clip_reads")})
            # Before Chromium is ready a read is a cheap file check or a refused connect; after, one per period.
            self.done.wait(opts.cef_every if self.reads else 1.0)

    def verdict(self, mode):
        """(valid, why, cost) for the reads of this launch."""
        reads = self.reads
        if not reads:
            return False, "Chromium never reached ready in this launch", {}
        hosted = [r.get("hosted_pages") or 0 for r in reads]
        why = []
        if any(r["unavailable"] is not None for r in reads):
            why.append("unavailable")
        if any(r["fallback"] is not None for r in reads):
            why.append("fallback to WebKit")
        if mode == "on" and max(r["fork_api"] for r in reads) < LAYER_HOSTING_FORK_API:
            why.append(f"fork_api {max(r['fork_api'] for r in reads)} < {LAYER_HOSTING_FORK_API}")
        if mode == "on" and max(hosted) < 1:
            why.append("no hosted page at any read")
        if mode == "off" and max(hosted) > 0:
            why.append(f"hosted_pages {max(hosted)} in mode off")

        def change(key):
            first, last = reads[0].get(key), reads[-1].get(key)
            return last - first if isinstance(first, (int, float)) and isinstance(last, (int, float)) else None
        cost = {"geometry_posts": change("geometry_posts"), "clip_reads": change("clip_reads"),
                "fork_calls": change("fork_calls"), "span_s": round(reads[-1]["t_s"] - reads[0]["t_s"], 2)}
        return not why, ", ".join(why) or "ok", cost


def check_mode(mode):
    """cef-layer-verify.py's valid + hosted rows for `mode`, in the build's own tunables file; (ok, facts)."""
    out = os.path.join(opts.out, mode, "verify")
    os.makedirs(out, exist_ok=True)
    command = [sys.executable, os.path.join(HERE, "cef-layer-verify.py"), "--app", opts.app, "--tag", opts.tag,
               "--out", out, "--mode", mode, "--checks", "hosted", "--tunables", "build"]
    print(f"== {mode} verify: {' '.join(command)}", flush=True)
    code = run(command, os.path.join(out, "log.txt"))
    report = load(os.path.join(out, f"verify-{mode}.json")) or {}
    rows = report.get("rows") or []
    ok = code == 0 and bool(rows) and all(r.get("ok") for r in rows)
    return ok, {"exit": code, "rows": rows, **(report.get("facts") or {})}


def bench_command(bench, out):
    common = ["--app", opts.app, "--tag", opts.tag]
    if bench == "switch":
        return [sys.executable, os.path.join(HERE, "sidebar-stress-bench.py"), *common, "--out", out,
                "--sizes", str(opts.workspaces), "--tickers", "10", "--scenarios", "switch_matrix", "--no-trace", "--stop"]
    if bench == "tabs":
        return [sys.executable, os.path.join(HERE, "tab-switch-matrix.py"), *common, "--out", out,
                "--kinds", "chromium", "--counts", "2,10", "--json", os.path.join(out, "report.json")]
    if bench == "light":
        return [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), *common, "--out", out, "--browser",
                "--layouts", "1x2,4x2", "--actions", "split,close,drag,scroll", "--rounds", str(opts.rounds),
                "--json", os.path.join(out, "report.json")]
    if bench == "stress":
        return [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), *common, "--out", out,
                "--layouts", "stress", "--stress-selected", "chromium", "--actions", "split,close,drag",
                "--rounds", str(opts.rounds), "--json", os.path.join(out, "report.json")]
    raise SystemExit(f"unknown bench {bench}")


def headline(bench, out):
    """The rows to compare; the full report stays in the bench's folder."""
    if bench == "switch":
        report = load(os.path.join(out, "results.json")) or {}
        rows = {}
        for size in (report.get("sizes") or {}).values() if isinstance(report.get("sizes"), dict) else []:
            for key, entry in (size.get("switch_matrix") or {}).items():
                if isinstance(entry, dict) and "input_to_idle_ms" in entry:
                    rows[key] = {k: entry.get(k) for k in ("input_to_commit_ms", "input_to_idle_ms", "longest_frame_ms")}
        return rows or report
    return load(os.path.join(out, "report.json"))


def stress_session(log_path):
    """The STRESS-SESSION line the bench printed (the shape it measured), or None."""
    try:
        with open(log_path) as f:
            for line in f:
                if line.startswith("STRESS-SESSION "):
                    return json.loads(line[len("STRESS-SESSION "):])
    except (OSError, ValueError):
        pass
    return None


def main():
    failures = 0
    summary = {"tag": opts.tag, "app": opts.app, "modes": {}, "validity": {}, "cost": {}}
    for mode in opts.modes.split(","):
        ok, facts = check_mode(mode)
        remember_original(facts)
        summary["validity"][mode] = {"ok": ok, **{k: v for k, v in facts.items() if k != "tunables_original"}}
        summary["modes"][mode], summary["cost"][mode] = {}, {}
        if not ok:
            print(f"== {mode}: not a valid {mode} run, no benches: {json.dumps(facts)[:400]}", flush=True)
            failures += 1
            continue
        for bench in opts.benches.split(","):
            out = os.path.join(opts.out, mode, bench)
            os.makedirs(out, exist_ok=True)
            command = bench_command(bench, out)
            print(f"== {mode} {bench}: {' '.join(command)}", flush=True)
            reader = CefReader()
            reader.start()
            log_path = os.path.join(out, "log.txt")
            code = run(command, log_path)
            reader.done.set()
            reader.join(timeout=15)
            valid, why, cost = reader.verdict(mode)
            rows = headline(bench, out)
            # A report is the result (exit 1 with one is the bench's own budget miss). No report is no result,
            # whatever the exit code: the app never came up, or the bench crashed. A launch that was not the mode
            # it says (WebKit, no hosting) keeps its rows, marked invalid.
            if not rows or not valid:
                failures += 1
            entry = {"exit": code, "valid": valid, "validity": why, "cef_reads": reader.reads,
                     "rows": rows if rows else {"error": "no report"}}
            if bench == "stress":
                entry["stress_session"] = stress_session(log_path)
            summary["modes"][mode][bench] = entry
            summary["cost"][mode][bench] = cost
            print(f"== {mode} {bench}: exit {code}, {'valid' if valid else 'NOT VALID'} ({why}), cost {json.dumps(cost)}",
                  flush=True)
    with open(os.path.join(opts.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
    print(json.dumps({"validity": {m: v["ok"] for m, v in summary["validity"].items()},
                      "benches": {m: {b: {"exit": v["exit"], "valid": v["valid"]} for b, v in r.items()}
                                  for m, r in summary["modes"].items()},
                      "cost": summary["cost"]}))
    return 1 if failures else 0


try:
    status = main()
finally:
    restore_tunables()
sys.exit(status)
