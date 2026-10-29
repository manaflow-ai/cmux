#!/usr/bin/env python3
"""Chromium resize sync (fork API 27): how long a page's resize holds cmux's frame, and the frames it costs.

Review 2 of PL-cef-layer slice 1 (plans/cmux-next/cef-layer-hosting-DESIGN.md "Live resize"): a hosted page's resize
wait runs inside the window's Core Animation commit on the main thread, on every motion frame of a split, close or
column spring, so it must be measured as commit time and dropped frames, light and STRESS, before it is called a fix.

Modes, on one tagged build (each checked first with cef-layer-verify.py --checks hosted --tunables build, which also
checks with debug.layers that the fork really moved the page's pixels, `hosted.fork`):

  off     layer hosting off: the page is a child window. API 26 and older: Chromium's own wait (up to 500 ms per
          page resize); API 27: no wait
  on      layer hosting on (cef-layer-verify.py --mode on: the feature `cefLayerHosting`, a pane's page hosts only
          where the app makes every Track A call), `browserResize.syncDeadline` at its default (8 ms, capped at half a display frame by
          CEFResizeSyncDeadline: 4 ms at 120 Hz)
  on0     the same hosting, syncDeadline 0: the page never holds the commit (it shows its last frame until Chromium
          draws the new size)
  host    Chromium in the Chromium Host (features cefHelperHost and chromiumHostTabs, Debug builds): each page resize is an ordered op, no
          fence (the page shows its last frame until the host's page draws the new size)
  hostfence  host, plus feature chromiumHostResizeFence (p01-process-052): the window's commit waits on a Core
          Animation fence until the host's page joins it, one display frame at most from the commit. Rows add
          fence_resizes (fenced resizes), fence_joined, fence_late and fence_cut (`debug.cef` host_resize);
          acceptance: commit p95 within one display frame and no more missed frames than `host`
The host modes are not checked with cef-layer-verify.py (it checks in-process layer hosting). They start with the
layer hosting and deadline tunables removed, and a bench of one counts as valid only when the app reported
`debug.cef` host_resize at its end (null: Chromium ran in process), for `hostfence` with at least one fenced resize.
summary.json records the features, the tunables file reset and each bench's host_resize.

Benches per mode: `light` (pane-perf-terminal.py --browser 1x2,4x2: the top-left pane is a Chromium page) and `stress`
(pane-perf-terminal.py --layouts stress --stress-selected chromium: the STRESS session, every pane a Chromium page),
actions split, close, column, drag. Per action it reports `commit_p95_ms` / `commit_max_ms` (every Core Animation
commit while debug.motion records: MotionCommitProbe, `ca.commit`, which holds Chromium's pre-commit wait), missed
frames and the display refresh (`refresh_ms`: judge drops in frames, a fleet mini may run at 60 Hz).

API 26 against API 27: run it once per build (--label names the run; summary.json records each mode's fork_api).

Each row also has `frames_p99_ms`. Every round of every mode and bench is also written as cmux-perf-result/v1 in
--out (stories cef-resize-sync and cef-resize-sync-stress: `cef_resize_sync.<mode>.<layout>.<action>.<metric>` and
`cef_resize_sync.<mode>.failed`, drag_layout_bench_report.py), with the --app bundle's build and this host.

Run on a GUI fleet host, never a laptop:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/cef-resize-sync-bench.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS"
Not a gate: it never fails on a number. Exit 1 when a mode is not what it says, a bench left no report or the
result-v1 file could not be written.
"""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # its siblings, also under `python3 -I`
import drag_layout_bench_report as results  # noqa: E402
from bench_launch import RecordError  # noqa: E402
from new_tab_bench_report import perf_result, write_all  # noqa: E402
from sidebar_drag_bench_report import measured_build  # noqa: E402

# The hosting tunable cef-layer-verify.py sets per mode (the feature's local override), removed at the end.
HOSTING_KEYS = ("browserResize.layerHosting",)
DEADLINE_KEY = "browserResize.syncDeadline"
MODES = {"off": ("off", None), "on": ("on", None), "on0": ("on", 0.0), "host": ("host", None), "hostfence": ("host", None)}
# The features each host mode starts the app with (pane-perf-terminal.py --enable-features).
HOST_FEATURES = {"host": "cefHelperHost,chromiumHostTabs",
                 "hostfence": "cefHelperHost,chromiumHostResizeFence,chromiumHostTabs"}


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--label", default="", help="names this build's run in summary.json (api26, api27)")
    # on and on0 need a fork with every Track A call (API 34): on the API 30 pin their check fails `valid`.
    parser.add_argument("--modes", default="off")
    parser.add_argument("--benches", default="light,stress")
    parser.add_argument("--actions", default="split,close,column,drag")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it")
    opts = parser.parse_args(argv)
    unknown = [m for m in opts.modes.split(",") if m not in MODES] + \
        [b for b in opts.benches.split(",") if b not in results.CEF_RESIZE_SESSIONS]
    if unknown:
        parser.error(f"unknown mode or bench: {', '.join(unknown)}")
    return opts


opts = None  # set by main()


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def set_deadline(path, value):
    """syncDeadline in the build's own tunables file (the app has quit: no writer races this); None removes it."""
    data = load(path) or {"version": 1, "values": {}}
    values = data.setdefault("values", {})
    if value is None:
        values.pop(DEADLINE_KEY, None)
    else:
        values[DEADLINE_KEY] = value
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)


def check_mode(mode, hosting):
    out = os.path.join(opts.out, mode, "verify")
    os.makedirs(out, exist_ok=True)
    command = [sys.executable, os.path.join(HERE, "cef-layer-verify.py"), "--app", opts.app, "--tag", opts.tag,
               "--out", out, "--mode", hosting, "--checks", "hosted", "--tunables", "build"]
    print(f"== {mode} verify: {' '.join(command)}", flush=True)
    with open(os.path.join(out, "log.txt"), "w") as log:
        code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
    report = load(os.path.join(out, f"verify-{hosting}.json")) or {}
    rows = report.get("rows") or []
    return code == 0 and bool(rows) and all(r.get("ok") for r in rows), {"exit": code, "rows": rows, **(report.get("facts") or {})}


def bench_command(bench, out, mode=None):
    common = [sys.executable, os.path.join(HERE, "pane-perf-terminal.py"), "--app", opts.app, "--tag", opts.tag,
              "--out", out, "--actions", opts.actions, "--rounds", str(opts.rounds), "--json", os.path.join(out, "report.json")]
    if mode in HOST_FEATURES:
        common += ["--enable-features", HOST_FEATURES[mode]]
    if bench == "light":
        return common + ["--browser", "--layouts", "1x2,4x2"]
    if bench == "stress":
        return common + ["--layouts", "stress", "--stress-selected", "chromium"]
    raise SystemExit(f"unknown bench {bench}")


def stress_session(log_path):
    """The STRESS-SESSION line the bench printed (the shape perf-stress-session.py built), to quote with the numbers."""
    try:
        for line in open(log_path, errors="replace"):
            if line.startswith("STRESS-SESSION "):
                return json.loads(line[len("STRESS-SESSION "):])
    except (OSError, ValueError):
        pass
    return None


KEYS = ("commit_p95_ms", "commit_max_ms", "missed", "frames_p95_ms", "frames_p99_ms", "frames_max_ms", "layout_p95_ms",
        "refresh_ms", "fence_resizes", "fence_joined", "fence_late", "fence_cut")


def clear_tunables(path):
    """Removes the layer hosting and deadline tunables from the build's tunables file (the app has quit)."""
    data = load(path) or {}
    for key in (*HOSTING_KEYS, DEADLINE_KEY):
        data.setdefault("values", {}).pop(key, None)
    try:
        with open(path, "w") as f:
            json.dump(data, f, indent=2, sort_keys=True)
    except OSError:
        pass


def host_validity(mode, report):
    """Why a host mode bench did not measure host mode, None when it did: the app reported `debug.cef` host_resize
    at the end (null in process), and for `hostfence` at least one fenced resize."""
    counters = report.get("host_resize")
    if not isinstance(counters, dict):
        return "debug.cef host_resize is null: Chromium ran in process"
    if mode == "hostfence" and not (counters.get("fenced") or 0) > 0:
        return f"no fenced resize (host_resize {json.dumps(counters)})"
    return None


def record_results(series):
    """Every mode and bench's rounds as cmux-perf-result/v1 in --out (one file, each session its own run). False when
    they could not be written (no build sha, an unknown config, an invalid result), with the reason printed."""
    try:
        build, host = measured_build(opts.app, opts.build_config)
        path = write_all(opts.out, series, build, host)
    except (RecordError, perf_result.ResultError) as error:
        print(f"result-v1: not recorded: {error}", flush=True)
        return False
    print(f"result-v1: {len(series)} series in {path}", flush=True)
    return True


def main(argv=None):
    global opts
    opts = parse(argv)
    failures = 0
    summary = {"tag": opts.tag, "app": opts.app, "label": opts.label, "validity": {}, "modes": {}}
    series = []
    tunables_file = None
    for mode in opts.modes.split(","):
        hosting, deadline = MODES[mode]
        summary["modes"][mode] = {}
        if mode in HOST_FEATURES:
            # The tunables an in-process mode left would change what the host mode measures.
            if tunables_file:
                clear_tunables(tunables_file)
            summary["validity"][mode] = {"ok": True, "features": HOST_FEATURES[mode], "tunables_reset": tunables_file,
                                         "benches": {}}
        else:
            ok, facts = check_mode(mode, hosting)
            summary["validity"][mode] = {"ok": ok, **facts}
            tunables_file = facts.get("tunables_file") or tunables_file
            if not ok or not facts.get("tunables_file"):
                print(f"== {mode}: not a valid {mode} run, no benches: {json.dumps(facts)[:400]}", flush=True)
                failures += 1
                for bench in opts.benches.split(","):
                    series += results.cef_resize_series(mode, bench, [], valid=False)
                continue
            set_deadline(facts["tunables_file"], deadline)
        for bench in opts.benches.split(","):
            out = os.path.join(opts.out, mode, bench)
            os.makedirs(out, exist_ok=True)
            command = bench_command(bench, out, mode)
            print(f"== {mode} {bench}: {' '.join(command)}", flush=True)
            with open(os.path.join(out, "log.txt"), "w") as log:
                code = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
            report = load(os.path.join(out, "report.json")) or {}
            rows = [{"layout": r.get("layout"), "action": r.get("action"), **{k: r.get(k) for k in KEYS}}
                    for r in report.get("summary") or []]
            valid = True
            if mode in HOST_FEATURES:
                invalid = host_validity(mode, report)
                valid = invalid is None
                summary["validity"][mode]["benches"][bench] = {"ok": valid, "host_resize": report.get("host_resize"),
                                                               **({"error": invalid} if invalid else {})}
                if not valid:
                    summary["validity"][mode]["ok"] = False
                    print(f"== {mode} {bench}: not a valid {mode} run: {invalid}", flush=True)
                    failures += 1
            if not rows:
                failures += 1
            series += results.cef_resize_series(mode, bench, (report.get("runs") or []) if rows and valid else [],
                                                valid=valid)
            summary["modes"][mode][bench] = {"exit": code,
                                             "stress_session": stress_session(os.path.join(out, "log.txt")),
                                             "macos": report.get("macos"), "host": report.get("host"),
                                             "rows": rows or {"error": "no report"}}
    if tunables_file:
        clear_tunables(tunables_file)
    with open(os.path.join(opts.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2, sort_keys=True)
    for mode, benches in summary["modes"].items():
        for bench, result in benches.items():
            for r in result["rows"] if isinstance(result["rows"], list) else []:
                print(f"{opts.label or '-'} {mode:<4} {bench:<6} {r['layout']:<6} {r['action']:<13} commit p95 "
                      f"{r['commit_p95_ms']} max {r['commit_max_ms']} ms  missed {r['missed']} (refresh "
                      f"{r['refresh_ms']} ms)  frame p95 {r['frames_p95_ms']} p99 {r['frames_p99_ms']} max "
                      f"{r['frames_max_ms']}  layout p95 {r['layout_p95_ms']}", flush=True)
    if not record_results(series):
        failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
