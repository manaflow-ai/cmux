#!/usr/bin/env python3
"""SCRATCH MEASUREMENT REF ONLY (cp/proof-ab-measure, never lands): one prove-or-remove switch A/B on one build.

Prove or remove (plans/cmux-next/prove-or-remove.md, Lawrence 2026-10-28): a mechanism stays only with a felt
result on an optimized build. This driver runs ONE bench suite on ONE app, alternating two arms of the same
switches on the same host:

  on   PROOF_AB_ENABLE=<switches>   (the app launches with CMUX_ENABLE_FEATURES=<switches>)
  off  PROOF_AB_DISABLE=<switches>  (the app launches with CMUX_DISABLE_FEATURES=<switches>)

Both arms name the switches explicitly, so the build's defaults (the chrome-parity- tag's dogfood set) do not
decide an arm. Runs are interleaved in ABBA blocks (on off off on, on off off on, ...) so a drift of the host over
the step hits both arms the same. Each launch's features.list is read back (proof_ab_env.record): a run whose
switches did not take the arm's state is invalid.

Usage (split-spring.sh passes --tag, --app, --out and --json; the rest after --suite=proof-ab is ours):
  split-spring.sh --config=<app sha256> --vdisplay=120 --suite=proof-ab --toggle=a,b --inner=typing-frame \
      --runs=5 --metric='k2f=^runs\\.\\*\\.key_to_frame_ms\\.p95$' [--validity='sender=send_late_ms$:1.0'] \
      -- <the inner suite's own arguments>
  proof-ab.py --summarize REPORT.json [--metric ...]   (offline: the same summary from a report's kept runs)

--inner is a split-spring-terminal.py suite (first5s, typing-frame, launch, idle-budget, anim-perf, pane-perf,
automation-typing, sidebar-churn, ...) or `memory` (bench_memory.py). --metric NAME=REGEX[:higher] selects numeric
leaves of each run's JSON by their flattened path (list indices become `*`); lower is better unless `:higher`.
--validity NAME=REGEX:MAX makes a run invalid when any matched value is over MAX (the first-5s sender: a run whose
send_late_ms max is over 1 ms is not valid).

Summary per metric: per arm the pooled p50/p95/p99/max and n, and the per-run p95 list; the noise band is the off
arm's per-run p95 spread (max - min); the effect is median(on per-run p95) - median(off per-run p95); a two-sided
exact Mann-Whitney U test over the per-run p95 values. Verdict:
  proven      every run valid and its arm verified, p < 0.05, the effect is in the better direction and larger
              than the noise band
  regression  the same, in the worse direction
  not proven  anything else (including too few valid runs: fewer than --runs per arm)
  invalid scenario  a --probe showed that the mechanism did not run in an on-arm run: the scenario is wrong, not the
              code; this never counts as "not proven" and goes back to the row's owner (coordinator, 2026-10-28)
  unverified scenario (no probe)  not proven and the step names no --probe, so it is unknown whether the code ran

--probe NAME|METHOD|PARAMS_JSON|REGEX|MIN: every launch path reads METHOD (a debug.* or features.* socket method) just
before the app quits (never in the measured window) and records the reply; an on-arm run is valid only when a value
at a path matching REGEX (inside the reply) is >= MIN.
"""
import argparse, itertools, json, math, os, plistlib, re, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
HEAVY = ("frames", "journal", "frame_details", "main_profile", "sample", "photon", "open_reply", "line",
         "hang_records", "stream_replies", "view_churn")


def flatten(node, path="", out=None):
    """Numeric leaves of `node` as (path, value); list indices become `*`."""
    if out is None:
        out = []
    if isinstance(node, bool):
        return out
    if isinstance(node, (int, float)):
        if not (isinstance(node, float) and math.isnan(node)):
            out.append((path, float(node)))
    elif isinstance(node, dict):
        for key, value in node.items():
            flatten(value, f"{path}.{key}" if path else str(key), out)
    elif isinstance(node, list):
        for value in node:
            flatten(value, f"{path}.*" if path else "*", out)
    return out


def trim(node):
    if isinstance(node, dict):
        return {k: trim(v) for k, v in node.items() if k not in HEAVY}
    if isinstance(node, list):
        return [trim(v) for v in node]
    return node


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return round(s[lo] + (s[hi] - s[lo]) * (k - lo), 3)


def stats(values):
    return {"n": len(values), "p50": pct(values, 0.5), "p95": pct(values, 0.95), "p99": pct(values, 0.99),
            "max": round(max(values), 3) if values else None}


def mann_whitney_p(a, b):
    """Two-sided exact p of the Mann-Whitney U statistic (ties get half), by enumeration (n <= 10 per side), else
    the normal approximation."""
    if not a or not b:
        return None
    def u_of(x, y):
        return sum(1.0 if xi > yi else 0.5 if xi == yi else 0.0 for xi in x for yi in y)
    u = u_of(a, b)
    n1, n2 = len(a), len(b)
    mean = n1 * n2 / 2
    if n1 + n2 <= 20:
        pooled = a + b
        count, extreme = 0, 0
        for idx in itertools.combinations(range(n1 + n2), n1):
            chosen = set(idx)
            x = [pooled[i] for i in idx]
            y = [pooled[i] for i in range(n1 + n2) if i not in chosen]
            count += 1
            if abs(u_of(x, y) - mean) >= abs(u - mean) - 1e-9:
                extreme += 1
        return round(extreme / count, 4)
    sd = math.sqrt(n1 * n2 * (n1 + n2 + 1) / 12)
    z = (abs(u - mean) - 0.5) / sd if sd else 0
    return round(math.erfc(z / math.sqrt(2)), 4)


def parse_metric(spec):
    name, _, rest = spec.partition("=")
    higher = rest.endswith(":higher")
    return name, re.compile(rest[:-len(":higher")] if higher else rest), higher


def parse_probe(spec):
    """A probe: a dict {name, method, params, regex, min} (spec files), or NAME|METHOD|PARAMS_JSON|REGEX|MIN, where only
    the first three and the last `|` split (a regex may hold `|`)."""
    if isinstance(spec, dict):
        # "max" instead of "min": the mechanism ran when every matched value is <= max (a value the on arm lowers,
        # for example a renderer count a rendererless spare takes to 0); "absent": true counts no match as ran.
        bound = ("max", float(spec["max"])) if "max" in spec else ("min", float(spec["min"]))
        return (spec["name"], spec["method"], spec.get("params") or {}, re.compile(spec["regex"]), bound,
                bool(spec.get("absent")))
    name, method, params, rest = spec.split("|", 3)
    regex, _, minimum = rest.rpartition("|")
    return name, method, json.loads(params or "{}"), re.compile(regex), ("min", float(minimum)), False


def parse_validity(spec):
    name, _, rest = spec.partition("=")
    regex, _, limit = rest.rpartition(":")
    return name, re.compile(regex), float(limit)


def summarize(report, metrics, runs_wanted):
    out = {}
    on_runs = [r for r in report["runs"] if r["arm"] == "on"]
    bench_failed = sum(1 for r in report["runs"] if r.get("raw") is None)
    bad_scenario = sum(1 for r in on_runs if r.get("invalid_scenario"))
    has_probe = bool(report.get("probes"))
    for name, regex, higher in metrics:
        arms = {}
        for arm in ("on", "off"):
            runs = [r for r in report["runs"] if r["arm"] == arm and r.get("valid")]
            pooled, per_run = [], []
            for r in runs:
                values = [v for p, v in flatten(r.get("raw")) if regex.search(p)]
                if values:
                    pooled += values
                    per_run.append(pct(values, 0.95))
            arms[arm] = {**stats(pooled), "runs_valid": len(runs), "per_run_p95": per_run}
        on, off = arms["on"]["per_run_p95"], arms["off"]["per_run_p95"]
        effect = (pct(on, 0.5) - pct(off, 0.5)) if on and off else None
        band = (max(off) - min(off)) if len(off) > 1 else None
        p = mann_whitney_p(on, off)
        better = effect is not None and ((effect > 0) if higher else (effect < 0))
        enough = len(on) >= runs_wanted and len(off) >= runs_wanted
        verified = all(r.get("arm_verified") is True for r in report["runs"] if r.get("valid"))
        strong = enough and verified and p is not None and p < 0.05 and band is not None and abs(effect) > band
        verdict = ("proven" if better else "regression") if strong else "not proven"
        if bench_failed and bench_failed >= len(report["runs"]) / 2:
            verdict = "bench failed"  # the bench produced no report: neither proof nor a scenario verdict
        elif bad_scenario:
            # The mechanism did not run in the on arm: the scenario is wrong, not the code (coordinator, 2026-10-28).
            verdict = "invalid scenario"
        elif verdict == "not proven" and not has_probe:
            verdict = "unverified scenario (no probe)"
        why = [] if strong else [w for w, bad in (("fewer valid runs than --runs per arm", not enough),
                                                  ("an arm not verified by features.list", not verified),
                                                  ("p >= 0.05", p is None or p >= 0.05),
                                                  ("effect inside the noise band", band is None or effect is None or abs(effect) <= band))
                                 if bad]
        out[name] = {"better": "higher" if higher else "lower", "on": arms["on"], "off": arms["off"],
                     "effect_ms_or_unit": None if effect is None else round(effect, 3),
                     "noise_band": None if band is None else round(band, 3), "mann_whitney_p": p,
                     "verdict": verdict, "why_not": why, "on_runs_mechanism_not_run": bad_scenario, "runs_without_report": bench_failed}
    return out


def app_identity(app):
    info = {}
    try:
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as handle:
            plist = plistlib.load(handle)
        info = {"bundle_id": plist.get("CFBundleIdentifier"), "configuration": plist.get("CMUXBuildConfiguration"),
                "commit": plist.get("CMUXCommit") or plist.get("CMUXGitCommit"),
                "tag": (plist.get("LSEnvironment") or {}).get("CMUX_TAG")}
    except (OSError, ValueError):
        pass
    return info


def run_one(opts, inner_args, arm, index):
    run_dir = os.path.join(opts.out, "proof-ab", f"{index:02d}-{arm}")
    os.makedirs(run_dir, exist_ok=True)
    run_json = os.path.join(run_dir, "run.json")
    features_out = os.path.join(run_dir, "features.jsonl")
    env = dict(os.environ)
    env.pop("PROOF_AB_ENABLE", None)
    env.pop("PROOF_AB_DISABLE", None)
    env["PROOF_AB_ENABLE" if arm == "on" else "PROOF_AB_DISABLE"] = opts.toggle
    env["PROOF_AB_FEATURES_OUT"] = features_out
    if opts.probes_parsed:
        env["PROOF_AB_PROBES"] = json.dumps([[method, params] for _n, method, params, _r, _b, _a in opts.probes_parsed])
    else:
        env.pop("PROOF_AB_PROBES", None)
    if opts.inner == "memory":
        cmd = [sys.executable, os.path.join(HERE, "bench_memory.py"), "--app", opts.app, "--out", run_json] + inner_args
    else:
        cmd = [sys.executable, os.path.join(HERE, "split-spring-terminal.py"), "--tag", opts.tag, "--app", opts.app,
               "--out", run_dir, "--json", run_json, f"--suite={opts.inner}"] + inner_args
    start = time.monotonic()
    load_start = os.getloadavg()
    print(f"PROOF-AB run {index} arm {arm}: load {load_start[0]:.1f}: {' '.join(cmd)}", flush=True)
    try:
        code = subprocess.call(cmd, env=env, timeout=opts.run_timeout)
    except subprocess.TimeoutExpired:
        code = 124
    seconds = round(time.monotonic() - start, 1)
    load_end = os.getloadavg()
    # Every run starts from no process of the tag: a bench that leaves its daemon (anim-perf, step 4bcdbf91) makes the
    # next launch refuse with tag-in-use. tag_teardown.py ends only this bundle's processes, by PID.
    subprocess.call([sys.executable, os.path.join(HERE, "tag_teardown.py"), opts.app], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=120)
    raw = None
    try:
        with open(run_json) as handle:
            raw = trim(json.load(handle))
    except (OSError, ValueError):
        pass
    want = "enabled" if arm == "on" else "disabled"
    checks = []
    try:
        with open(features_out) as handle:
            checks = [json.loads(line) for line in handle if line.strip()]
    except OSError:
        pass
    toggles = [n for n in opts.toggle.split(",") if n]
    verified = None
    if verified is None:
        states = [c.get("features") for c in checks if "features" in c]
        verified = bool(states) and all(isinstance(s, dict) and all(
            str((s.get(n) or {}).get("state", "")).lower() in (want, "on" if arm == "on" else "off", str(arm == "on").lower())
            for n in toggles) for s in states)
    probe_rows = [c["probes"] for c in checks if "probes" in c]
    probes, scenario_ok = {}, None
    for name, method, _params, regex, bound, absent_ok in opts.probes_parsed:
        replies = [reply.get(method) for reply in probe_rows]
        values = [v for reply in replies for p, v in flatten(reply) if regex.search(p)]
        answered = any(isinstance(r, (dict, list)) and not (isinstance(r, dict) and ("probe_error" in r or "error" in r)) for r in replies)
        kind, limit = bound
        if kind == "max":
            ran = all(v <= limit for v in values) and (bool(values) or (absent_ok and answered))
        else:
            ran = bool(values) and max(values) >= limit
        probes[name] = {"max": max(values) if values else None, "n": len(values), kind + "_to_run": limit, "ran": ran}
    if opts.probes_parsed and probe_rows:
        scenario_ok = all(p["ran"] for p in probes.values())  # no probe rows at all: the bench failed before the quit
    invalid = []
    for name, regex, limit in opts.validity_parsed:
        bad = [v for p, v in flatten(raw) if regex.search(p) and v > limit]
        if bad:
            invalid.append(f"{name}: {len(bad)} values over {limit} (max {max(bad)})")
    invalid_scenario = arm == "on" and scenario_ok is False
    valid = raw is not None and not invalid and verified is not False and not invalid_scenario
    row = {"arm": arm, "index": index, "exit": code, "seconds": seconds, "valid": valid, "arm_verified": verified,
           "probes": probes, "scenario_ran": scenario_ok, "invalid_scenario": invalid_scenario,
           "load_start": [round(x, 2) for x in load_start], "load_end": [round(x, 2) for x in load_end],
           "features_seen": checks[:3], "invalid": invalid, "raw": raw if opts.keep_raw else None}
    print(f"PROOF-AB run {index} arm {arm}: exit {code} in {seconds} s valid={valid} arm_verified={verified} "
          f"scenario_ran={scenario_ok} "
          f"{'; '.join(invalid)}", flush=True)
    return row, raw


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag")
    parser.add_argument("--app")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--toggle", help="comma list of the switches both arms set")
    parser.add_argument("--inner", help="the bench suite each run executes")
    parser.add_argument("--runs", type=int, default=5, help="runs per arm (at least 5 for the noise band)")
    parser.add_argument("--run-timeout", type=float, default=1800)
    parser.add_argument("--metric", action="append", default=[])
    parser.add_argument("--validity", action="append", default=[])
    parser.add_argument("--probe", action="append", default=[],
                        help="NAME|METHOD|PARAMS_JSON|REGEX|MIN: a debug.* reply read at the end of each launch (REGEX matches the flattened "
                             "path inside the reply, list indices as *); the on arm's run is valid only when a matched value is >= MIN "
                             "(the mechanism ran)")
    parser.add_argument("--row", default="", help="the prove-or-remove row id(s) this A/B is for (reported)")
    parser.add_argument("--keep-raw", type=int, default=1)
    parser.add_argument("--summarize", help="offline: summarize this report again")
    parser.add_argument("--spec", help="a JSON file in this checkout (proof-specs/<row>.json) with toggle, inner, runs, row, "
                                       "metric, validity, probe and inner_args: the fleet controller allows only "
                                       "[A-Za-z0-9._/@+=,:-] and 16 args per step, so regexes and JSON travel in the file")
    argv = sys.argv[1:]
    inner_args = []
    if "--" in argv:
        cut = argv.index("--")
        argv, inner_args = argv[:cut], argv[cut + 1:]
    opts = parser.parse_args([a for a in argv if a != "--suite=proof-ab"])
    if opts.spec:
        here_root = os.path.dirname(os.path.dirname(HERE))
        path = opts.spec if os.path.isabs(opts.spec) else os.path.join(here_root, opts.spec)
        with open(path) as handle:
            spec = json.load(handle)
        for name in ("toggle", "inner", "runs", "row", "run_timeout"):
            if name in spec and spec[name] is not None:
                setattr(opts, name, spec[name])
        opts.metric = list(opts.metric) + list(spec.get("metric") or [])
        opts.validity = list(opts.validity) + list(spec.get("validity") or [])
        opts.probe = list(opts.probe) + list(spec.get("probe") or [])
        inner_args = list(spec.get("inner_args") or []) + inner_args
    metrics = [parse_metric(m) for m in opts.metric]
    opts.validity_parsed = [parse_validity(v) for v in opts.validity]
    opts.probes_parsed = [parse_probe(p) for p in opts.probe]
    if opts.summarize:
        with open(opts.summarize) as handle:
            report = json.load(handle)
        print(json.dumps(summarize(report, metrics or [parse_metric(m) for m in report.get("metrics", [])],
                                   report.get("runs_per_arm", opts.runs)), indent=1))
        return 0
    if not (opts.toggle and opts.inner and opts.app and opts.out and opts.json and metrics):
        parser.error("--toggle, --inner, --app, --out, --json and at least one --metric are required")
    order = []
    for block in range((opts.runs + 1) // 2):
        order += ["on", "off", "off", "on"] if block % 2 == 0 else ["off", "on", "on", "off"]
    counts = {"on": 0, "off": 0}
    plan = []
    for arm in order:
        if counts[arm] < opts.runs:
            plan.append(arm)
            counts[arm] += 1
    report = {"bench": "proof-ab", "row": opts.row, "toggle": opts.toggle.split(","), "inner": opts.inner,
              "inner_args": inner_args, "runs_per_arm": opts.runs, "order": plan, "metrics": opts.metric,
              "validity": opts.validity, "probes": opts.probe, "app": opts.app, "build": app_identity(opts.app),
              "host": socket.gethostname().split(".")[0],
              "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
              if sys.platform == "darwin" else None,
              "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
              "load_start": [round(x, 2) for x in os.getloadavg()], "runs": []}
    for index, arm in enumerate(plan):
        row, _ = run_one(opts, inner_args, arm, index)
        report["runs"].append(row)
        report["summary"] = summarize(report, metrics, opts.runs)
        with open(opts.json, "w") as handle:
            json.dump(report, handle)
    report["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    report["load_end"] = [round(x, 2) for x in os.getloadavg()]
    with open(opts.json, "w") as handle:
        json.dump(report, handle)
    print("PROOF-AB " + json.dumps({"row": opts.row, "toggle": opts.toggle, "host": report["host"],
                                    "build": report["build"], "summary": report["summary"]}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
