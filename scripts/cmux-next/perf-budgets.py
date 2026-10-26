#!/usr/bin/env python3
"""cmux-next perf budgets: one suite, one table, one gate (Lawrence 2026-10-21: "a ton of performance
issues ... introduced recently. how do we fix from first principles").

Budgets (scripts/cmux-next/perf-budgets.json): every hot interaction has a written latency or frame
budget. This script runs the existing benches against ONE built tagged app, one after the other (each
bench launches and quits the app itself), and maps their reports to budget rows with p50 and p95:

  bench                          rows
  instant-new-surfaces-bench.py  Cmd-N, Cmd-T, Ctrl-`, Cmd-D, Cmd-Shift-D: key to visible, idle and under load
  pane-perf-terminal.py          split / close / New Column / zoom: frame intervals during the motion (4x2 terminals)
  tab-switch-matrix.py           tab switch: input to committed frame (terminal and Chromium, 10 tabs)
  palette-open-stages.py         Cmd-Shift-P / Cmd-P: key-down to committed frame (p90 as its p95: the bench keeps p90)
  sidebar-stress-bench.py        400 workspaces, 15 ticking: scroll, ticks (frames, CPU, main ms/s), row drag, and the
                                 workspace switch matrix (click, Cmd-1..4, Ctrl-Cmd-]/[ x terminal, Chromium)
  home-perf.py                   Home: typing key dispatch, chat scroll frames
  agent-engine-bench.py          ACP chat composer: keydown to next frame (the page's typingStats)
  bench_idle.py                  idle CPU of the app with terminals open

  A bench that fails to run (older build without its debug method, no display) leaves its rows "n/a"; the
  suite goes on, but the gate reports an incomplete result when an expected row is absent. Output: --json
  (rows, raw report paths, host), a Markdown table in the log.

Gate (--gate): a row regresses when its p95 is more than 10 % over the stored baseline for this host
class (scripts/cmux-next/perf-budgets-baseline/<chip>-macos<major>.json) and more than the row's
noise floor (1 ms; 0.3 points of CPU). Exit 1 on any regression. Rows over their absolute budget are
listed ("over budget") but do not fail the gate: the gate stops new regressions, the budgets are the
target the fixes work toward. --write-baseline FILE writes this run's p95s as a baseline.

Fleet (an owned mini with a console; the step builds the app):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \\
    --ref SHA --artifact artifacts/split-spring/report.json --arg=--suite=budgets [--arg=--gate] [--arg=--only=a,b]
Local, on a built app (never on a laptop that is in use):
  perf-budgets.py --tag T --app "<...>/cmux DEV T.app" --out DIR --json DIR/report.json
"""
import argparse, importlib.util, json, os, platform, re, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
BUDGETS_FILE = os.path.join(HERE, "perf-budgets.json")
BASELINE_DIR = os.path.join(HERE, "perf-budgets-baseline")
REGRESSION = 0.10

BENCHES = ["new_surfaces", "panes", "tab_switch", "palette", "sidebar", "home", "acp", "idle", "anim"]
PERF_BENCH = os.path.join(HERE, "..", "perf-bench")


# ---------- pure helpers (tests/test_perf_budgets.py) ----------

def pct(values, q):
    vals = sorted(v for v in values if isinstance(v, (int, float)))
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def p50_p95(obj):
    """p50/p95 from a bench's stat dict (p50/p95, p50_ms/p95_ms, or p90 when the bench keeps no p95) or a list."""
    if obj is None:
        return None, None
    if isinstance(obj, list):
        return pct(obj, 0.5), pct(obj, 0.95)
    if isinstance(obj, (int, float)):
        return obj, obj
    if not isinstance(obj, dict):
        return None, None
    p50 = next((obj[k] for k in ("p50", "p50_ms", "median") if isinstance(obj.get(k), (int, float))), None)
    p95 = next((obj[k] for k in ("p95", "p95_ms", "p90", "p90_ms") if isinstance(obj.get(k), (int, float))), None)
    return p50, p95


def compare(rows, baseline, regression=REGRESSION):
    """Rows that regressed against baseline {name: p95}: p95 > base * (1 + regression) and p95 - base > floor."""
    out = []
    for r in rows:
        base = baseline.get(r["name"])
        if base is None or r.get("p95") is None:
            continue
        floor = r.get("floor", 1.0)
        if r["p95"] > base * (1 + regression) and r["p95"] - base > floor:
            out.append({"name": r["name"], "p95": r["p95"], "baseline": base,
                        "worse_pct": round(100 * (r["p95"] - base) / base, 1) if base else None})
    return out


def over_budget(rows):
    return [r["name"] for r in rows if r.get("p95") is not None and r.get("budget") is not None and r["p95"] > r["budget"]]


def host_class():
    chip = "unknown"
    try:
        chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True,
                              timeout=5).stdout.strip() or chip
    except Exception:
        pass
    major = (platform.mac_ver()[0] or "0").split(".")[0]
    return re.sub(r"[^a-z0-9]+", "-", chip.lower()).strip("-") + f"-macos{major}"


# ---------- bench runs ----------

def run_bench(name, argv, log_dir, timeout):
    log = os.path.join(log_dir, f"{name}.log")
    print(f"\n=== {name}: {' '.join(os.path.basename(a) if i == 1 else a for i, a in enumerate(argv))}", flush=True)
    start = time.time()
    try:
        with open(log, "w") as fh:
            proc = subprocess.run(argv, stdout=fh, stderr=subprocess.STDOUT, timeout=timeout, cwd=os.path.join(HERE, "../.."))
        code = proc.returncode
    except subprocess.TimeoutExpired:
        code = "timeout"
    took = round(time.time() - start, 1)
    tail = open(log, errors="replace").read().splitlines()[-6:]
    print(f"--- {name}: exit {code} in {took}s", *("    " + t for t in tail), sep="\n", flush=True)
    return {"exit": code, "seconds": took, "log": log}


def load(path):
    try:
        return json.load(open(path))
    except Exception:
        return None


def find_stage(table, stage):
    """tab-switch tables nest {kind: {stage: stat}} or {stage: stat}."""
    if not isinstance(table, dict):
        return None
    if stage in table:
        return table[stage]
    for v in table.values():
        if isinstance(v, dict) and stage in v:
            return v[stage]
    return None


def rows_new_surfaces(rep):
    out = {}
    names = {"new_workspace": "cmd_n", "new_tab": "cmd_t", "new_terminal": "ctrl_backtick",
             "split_right": "cmd_d", "split_down": "cmd_shift_d"}
    for key, s in ((rep or {}).get("summary") or {}).items():
        phase, _, cmd = key.partition("/")
        if cmd in names:
            out[f"{names[cmd]}.{phase}.key_to_visible"] = (s.get("visible_p50"), s.get("visible_p95"))
    return out


def rows_panes(rep):
    out = {}
    for s in (rep or {}).get("summary") or []:
        out[f"panes.{s.get('action')}.{s.get('layout')}.frame"] = (s.get("frames_p50_ms"), s.get("frames_p95_ms"))
    return out


def rows_tab_switch(rep):
    out = {}
    for sc in (rep or {}).get("scenarios") or []:
        stat = find_stage((sc.get("ctrl_tab") or {}).get("table"), "e2e")
        out[f"tab_switch.{sc.get('kind')}.{sc.get('count')}.e2e"] = p50_p95(stat)
    return out


def rows_palette(rep):
    out = {}
    for name, s in ((rep or {}).get("surfaces") or {}).items():
        slug = re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_")
        out[f"palette.{slug}.key_to_frame"] = p50_p95((s.get("table") or {}).get("key"))
    return out


def rows_sidebar(rep, size):
    out = {}
    s = ((rep or {}).get("sizes") or {}).get(str(size)) or {}
    out[f"sidebar.{size}.scroll.frame"] = p50_p95((s.get("scroll") or {}).get("frames"))
    out[f"sidebar.{size}.scroll_while_ticking.frame"] = p50_p95((s.get("scroll_while_ticking") or {}).get("frames"))
    out[f"sidebar.{size}.drag.frame"] = p50_p95((s.get("drag") or {}).get("frames"))
    out[f"sidebar.{size}.workspace_switch.click_to_idle"] = p50_p95((s.get("switch") or {}).get("click_to_idle_ms"))
    ticks = s.get("ticks") or {}
    out[f"sidebar.{size}.ticking.frame"] = p50_p95(ticks.get("frames_while_ticking"))
    cpu = (ticks.get("ticking") or {}).get("cpu_pct") if isinstance(ticks.get("ticking"), dict) else None
    if isinstance(cpu, (int, float)):
        out[f"sidebar.{size}.ticking.cpu_pct"] = (cpu, cpu)
    if isinstance(ticks.get("main_ms_per_s"), (int, float)):
        out[f"sidebar.{size}.ticking.main_ms_per_s"] = (ticks["main_ms_per_s"], ticks["main_ms_per_s"])
    for key, m in (s.get("switch_matrix") or {}).items():
        if isinstance(m, dict) and "input_to_idle_ms" in m:
            out[f"workspace_switch.{key}.input_to_idle"] = p50_p95(m["input_to_idle_ms"])
            out[f"workspace_switch.{key}.longest_frame"] = p50_p95(m.get("longest_frame_ms"))
            if m.get("input_to_commit_ms"):
                out[f"workspace_switch.{key}.input_to_commit"] = p50_p95(m["input_to_commit_ms"])
    return out


def rows_home(rep):
    rep = rep or {}
    return {"home.typing.key_dispatch": p50_p95((rep.get("typing") or {}).get("key_dispatch_ms")),
            "home.scroll.frame": p50_p95(rep.get("scroll"))}


def rows_acp(rep):
    out = {}
    for mode, r in ((rep or {}).get("modes") or {}).items():
        summ = r.get("summary", r) if isinstance(r, dict) else {}
        out[f"acp.{mode}.typing.to_frame"] = p50_p95(summ.get("typing_to_frame"))
        out[f"acp.{mode}.typing.to_paint"] = p50_p95(summ.get("typing_to_paint"))
    return out


def rows_idle(rep):
    out = {}
    for name, sc in ((rep or {}).get("scenarios") or {}).items():
        app = [p for p in sc.get("processes") or [] if p.get("kind") == "app"]
        if app:
            cpu = app[0].get("cpu_percent")
            out[f"idle.{name}.app_cpu_pct"] = (cpu, cpu)
    return out


def profile_splits(out):
    """Framework vs our main-thread time for each profile the benches left (perf-profile-split.py)."""
    import glob
    spec = importlib.util.spec_from_file_location("perf_profile_split", os.path.join(HERE, "perf-profile-split.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    found = sorted(glob.glob(os.path.join(out, "sidebar", "traces", "*.trace"))) + sorted(glob.glob(os.path.join(out, "panes", "sample-*.txt")))
    result = {}
    for path in found:
        name = os.path.basename(path).rsplit(".", 1)[0]
        try:
            result[name] = mod.split(path)
        except Exception as exc:
            result[name] = {"error": repr(exc)}
        r = result[name]
        print(f"PERF-PROFILE-SPLIT {name} framework {r.get('framework_pct')} % ours {r.get('ours_pct')} % "
              f"{json.dumps(r.get('busy_pct'))}", flush=True)
        for bucket, frames in (r.get("top_frames") or {}).items():
            print(f"PERF-PROFILE-TOP {name} {bucket}: " + "; ".join(f"{n} x{c}" for n, c in frames[:4]), flush=True)
    return result


def animation_budgets():
    """`animations` rows of scripts/perf-bench/budgets.json (budget.py animation_budgets), as
    {row name: spec}; none when the file has no such key."""
    try:
        spec = importlib.util.spec_from_file_location("perf_bench_budget", os.path.join(PERF_BENCH, "budget.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        entries = mod.animation_budgets()
    except (OSError, SystemExit, AttributeError):
        return {}
    return {f"anim.{e['anim']}.{e['metric']}": {"p95": e["limit"], "unit": "frames" if e["metric"] == "dropped" else "ms",
                                                "floor": 1.0, "what": f"animation {e['anim']}: {e['metric']}",
                                                "enforce": bool(e.get("enforce"))} for e in entries}


def rows_anim(rep):
    """anim-perf-terminal.py summary rows: frame p50/p95 per animation, and each metric its budgets name."""
    out = {}
    for s in (rep or {}).get("summary") or []:
        name = s.get("anim")
        if not name:
            continue
        out[f"anim.{name}.frame"] = (s.get("p50_ms"), s.get("p95_ms"))
        for metric in ("dropped", "main_ms_max", "over_8_33", "main_ms_p95"):
            if isinstance(s.get(metric), (int, float)):
                out[f"anim.{name}.{metric}"] = (s[metric], s[metric])
    return out


def budget_for(name, budgets):
    anim = budgets.get("_animations", {}).get(name)
    if anim:
        return anim
    for pattern, spec in budgets["rows"].items():
        if re.fullmatch(pattern, name):
            return spec
    return {}


def incomplete_rows(rows, baseline, manifest, only):
    """Return missing-data reasons for the requested benchmark parts.

    The baseline expands the manifest's patterns into concrete row names. This lets a
    renamed or newly added row fail closed without hard-coding every dynamic sidebar
    size in the runner. The manifest still catches a zero-row or schema-shape failure
    when no previous baseline contains a name to expand.
    """
    selected = [pattern for part in only for pattern in manifest.get(part, [])]
    current = {row.get("name"): row for row in rows if row.get("name")}
    missing = []
    for name in sorted(baseline):
        if selected and not any(re.fullmatch(pattern, name) for pattern in selected):
            continue
        sample = current.get(name)
        if sample is None or sample.get("p95") is None:
            missing.append({"name": name, "reason": "missing current p95"})
    # A baseline with at least one concrete row for a benchmark part is the
    # source of truth for that part's shape. Older baselines can legitimately
    # contain only one family (for example the sidebar switch row); requiring
    # every manifest family in that case would turn an otherwise concrete
    # current-value check into a false incomplete result. A part with no
    # baseline rows still needs its manifest families to prove that the bench
    # produced data at all.
    baseline_parts = {
        part for part in only
        if any(any(re.fullmatch(pattern, name) for pattern in manifest.get(part, []))
               for name in baseline)
    }
    for part in only:
        if part in baseline_parts:
            continue
        for pattern in manifest.get(part, []):
            matched = [name for name in current if re.fullmatch(pattern, name)]
            if not matched or not any(current[name].get("p95") is not None for name in matched):
                # A part with no baseline rows still needs this manifest-level
                # reason so a new baseline cannot be written from a partial run.
                missing.append({"name": pattern, "reason": "manifest row not measured"})
    return missing


def completeness_counts(rows, baseline, manifest, only, incomplete, regressed):
    """Summarize the manifest coverage in the JSON receipt.

    Concrete names in a baseline are the expected rows for that host. When no
    baseline exists, the manifest patterns are the expected entries instead.
    """
    selected = [pattern for part in only for pattern in manifest.get(part, [])]
    measured_names = {row.get("name") for row in rows if row.get("name") and row.get("p95") is not None}
    expected_names = {name for name in baseline
                      if not selected or any(re.fullmatch(pattern, name) for pattern in selected)}
    if expected_names:
        expected = len(expected_names)
        measured = len(expected_names & measured_names)
    else:
        matched = {pattern for pattern in selected
                   if any(re.fullmatch(pattern, name) for name in measured_names)}
        expected = len(selected)
        measured = len(matched)
    incomplete_names = {item["name"] for item in incomplete}
    return {"expected": expected,
            "measured": measured,
            "unsupported": 0,
            "failed": len(regressed),
            "incomplete": len(incomplete_names)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--json")
    ap.add_argument("--only", default=",".join(BENCHES))
    ap.add_argument("--sidebar-size", type=int, default=400)
    ap.add_argument("--sidebar-tickers", type=int, default=15, help="ticking (agent-like) workspaces in the sidebar bench")
    ap.add_argument("--sidebar-scenarios", default="ticks,scroll,scroll_ticking,switch,switch_matrix,drag")
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--baseline", help="baseline JSON (default: perf-budgets-baseline/<host class>.json)")
    ap.add_argument("--write-baseline")
    ap.add_argument("--bench-timeout", type=int, default=900)
    ap.add_argument("--profile", action="store_true",
                    help="also profile the sidebar (Time Profiler: scroll, ticks, switch, row drag) and the panes "
                         "(sample: split, New Column, divider drag) and split main-thread time into framework and our work")
    opts, _ = ap.parse_known_args()
    os.makedirs(opts.out, exist_ok=True)
    budgets = json.load(open(BUDGETS_FILE))
    budgets["_animations"] = animation_budgets()
    only = [b for b in opts.only.split(",") if b]
    py = sys.executable
    S = lambda f: os.path.join(HERE, f)  # noqa: E731
    o = lambda f: os.path.join(opts.out, f)  # noqa: E731
    common = ["--tag", opts.tag, "--app", opts.app]
    plan = {
        "new_surfaces": ([py, S("instant-new-surfaces-bench.py"), *common, "--runs", "10",
                          "--out", o("new_surfaces"), "--json", o("new_surfaces.json")], "new_surfaces.json", rows_new_surfaces),
        "panes": ([py, S("pane-perf-terminal.py"), *common, "--layouts", "4x2", "--rounds", "2",
                   "--actions", "split,close,column,zoom" + (",drag" if opts.profile else ""),
                   *(["--sample", "4x2:split,4x2:column,4x2:drag"] if opts.profile else []),
                   "--out", o("panes"), "--json", o("panes.json")],
                  "panes.json", rows_panes),
        "tab_switch": ([py, S("tab-switch-matrix.py"), *common, "--kinds", "terminal,chromium", "--counts", "10",
                        "--switches", "30", "--out", o("tab_switch"), "--json", o("tab_switch.json")],
                       "tab_switch.json", rows_tab_switch),
        "palette": ([py, S("palette-open-stages.py"), *common, "--rounds", "6", "--no-gate",
                     "--out", o("palette"), "--json", o("palette.json")], "palette.json", rows_palette),
        "sidebar": ([py, S("sidebar-stress-bench.py"), *common, "--sizes", str(opts.sidebar_size), "--stop",
                     "--tickers", str(opts.sidebar_tickers), "--scenarios", opts.sidebar_scenarios,
                     *([] if opts.profile else ["--no-trace"]), "--out", o("sidebar")], os.path.join("sidebar", "results.json"),
                    lambda r: rows_sidebar(r, opts.sidebar_size)),
        "home": ([py, S("home-perf.py"), "--tag", opts.tag, "--out", o("home.json")], "home.json", rows_home),
        "acp": ([py, S("agent-engine-bench.py"), *common, "--modes", "own,chromium", "--chats", "2", "--flings", "1",
                 "--out", o("acp"), "--json", o("acp.json")], "acp.json", rows_acp),
        "anim": ([py, S("anim-perf-terminal.py"), *common, "--rounds", "2", "--out", o("anim"), "--json", o("anim.json")],
                 "anim.json", rows_anim),
        "idle": ([py, S("bench_idle.py"), *common, "--scenarios", "terminals,chromium-static", "--settle", "15",
                  "--measure", "30", "--no-fail", "--label", "budgets", "--out", o("idle")], None, rows_idle),
    }
    runs, values = {}, {}
    for name in only:
        argv, report, mapper = plan[name]
        # Some benches open files in their --out without making it.
        for flag, value in zip(argv, argv[1:]):
            if flag == "--out":
                os.makedirs(value, exist_ok=True)
        if not os.path.exists(argv[1]):  # a bench another lane adds (anim-perf) on a checkout without it
            print(f"\n=== {name}: {os.path.basename(argv[1])} is not in this checkout; its rows stay n/a", flush=True)
            continue
        runs[name] = run_bench(name, argv, opts.out, opts.bench_timeout)
        if report is None:  # bench_idle names its file after the sha and label
            found = sorted(f for f in os.listdir(o("idle")) if f.endswith("-idle-budgets.json")) if os.path.isdir(o("idle")) else []
            report = os.path.join("idle", found[-1]) if found else "idle/missing.json"
        runs[name]["report"] = o(report)
        try:
            values.update(mapper(load(o(report))))
        except Exception as exc:  # a report from an older build with another shape: its rows stay n/a
            runs[name]["map_error"] = repr(exc)

    profile_split = profile_splits(opts.out) if opts.profile else None

    rows = []
    for name, (p50, p95) in sorted(values.items()):
        spec = budget_for(name, budgets)
        rows.append({"name": name, "p50": None if p50 is None else round(p50, 2),
                     "p95": None if p95 is None else round(p95, 2), "budget": spec.get("p95"),
                     "unit": spec.get("unit", "ms"), "floor": spec.get("floor", 1.0), "interaction": spec.get("what")})

    cls = host_class()
    base_path = opts.baseline or os.path.join(BASELINE_DIR, f"{cls}.json")
    baseline = (load(base_path) or {}).get("p95", {})
    regressed = compare(rows, baseline)
    over = over_budget(rows)
    incomplete = []
    if opts.gate and not baseline:
        incomplete.append({"name": "baseline", "reason": "missing baseline p95 rows"})
    incomplete.extend(incomplete_rows(rows, baseline, budgets.get("expected", {}), only))
    counts = completeness_counts(rows, baseline, budgets.get("expected", {}), only, incomplete, regressed)

    print(f"\n# cmux-next perf budgets, {cls} ({platform.node()}), tag {opts.tag}\n")
    print("| row | p50 | p95 | budget p95 | baseline p95 | |\n|---|---|---|---|---|---|")
    reg_names = {r["name"] for r in regressed}
    for r in rows:
        f = lambda v: "n/a" if v is None else f"{v}"  # noqa: E731
        mark = "REGRESSED" if r["name"] in reg_names else ("over budget" if r["name"] in over else "")
        print(f"| {r['name']} | {f(r['p50'])} | {f(r['p95'])} | {f(r['budget'])} | {f(baseline.get(r['name']))} | {mark} |")
    print(f"\nPERF-BUDGETS rows={len(rows)} measured={sum(r['p95'] is not None for r in rows)} "
          f"over_budget={len(over)} regressed={len(regressed)} incomplete={len(incomplete)} "
          f"baseline={'yes' if baseline else 'none'} expected={counts['expected']} "
          f"measured={counts['measured']} unsupported={counts['unsupported']} failed={counts['failed']}")
    for r in regressed:
        print(f"PERF-BUDGETS-REGRESSION {r['name']} p95 {r['p95']} vs baseline {r['baseline']} (+{r['worse_pct']} %)")
    for r in incomplete:
        print(f"PERF-BUDGETS-INCOMPLETE {r['name']}: {r['reason']}")

    result = {"tag": opts.tag, "host_class": cls, "host": platform.node(), "baseline_file": base_path if baseline else None,
              "rows": rows, "regressed": regressed, "over_budget": over, "incomplete": incomplete,
              "counts": counts, "runs": runs,
              "profile_split": profile_split}
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        json.dump(result, open(opts.json, "w"), indent=1)
    if opts.write_baseline and incomplete:
        print("PERF-BUDGETS-BASELINE refused: the run is incomplete; provide measured rows for every expected entry")
    elif opts.write_baseline:
        json.dump({"host_class": cls, "p95": {r["name"]: r["p95"] for r in rows if r["p95"] is not None}},
                  open(opts.write_baseline, "w"), indent=1, sort_keys=True)
    if opts.gate and not baseline:
        print(f"PERF-BUDGETS-GATE no baseline at {base_path}: incomplete")
    sys.exit(1 if opts.gate and (regressed or incomplete) else 0)


if __name__ == "__main__":
    main()
