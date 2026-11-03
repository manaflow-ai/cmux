#!/usr/bin/env python3
"""The action fuzzer: seeded, model-based runs of journeys/fuzz/action-fuzz.json (ext_fuzz.py), with an A/B of speed.

    scripts/journeys/fuzz.py --build JOB [--base JOB] [--minutes 10] [--seed S] [--diagnostic] [--corpus]
                             [--hog-swap-gb 14] [--hosts "cmux18 ..."] [--out DIR]
    scripts/journeys/fuzz.py --build JOB --replay REPRO.json     # one shrunk sequence, in a fresh lease
    scripts/journeys/fuzz.py --plan --seed S [--count N]         # print a seed's plan (no fleet)

cmux-ad 2026-10-31 (Lawrence: "we need to fuzz greater for both correctness and speed"). One harness with the smoke
gate: each round is one run.py lease (`--exclusive`, pool perf-lead: no fleet step runs on the mini) that plays the
fuzz journey with a seed; the driver's action layer and the oracles are ext_fuzz.py's (its docstring lists them).

- A/B: with --base, every round plays the SAME seed on the build and on the base, back to back on the same mini
  (ABBA order over rounds), so each action's speed marks (key -> the new terminal drawn, key -> its prompt drawn,
  Cmd-T -> the field has focus) are compared build against build on one host in one run, never against a fixed
  number. A speed regression is red with the action, its timing kind and the seeds (see speed_table).
- Correctness: a failure of the build names the oracle, the seed and the shrunk sequence (ext_fuzz shrinks in the
  app with ddmin). Each shrunk sequence is replayed in a fresh lease (confirmed: fails again with the same oracle)
  and written as a regression journey (journeys/fuzz/found-*.json shape, priority P1) under OUT/repros/; the same
  failure on the base is reported as a base finding, not a regression.
- --corpus plays the sequences of Lawrence's reported bugs first (ext_fuzz.CORPUS).
- --diagnostic: a capture slot has no key window (until the Cua grant on cmux17), so keys after a create wait out the
  creation hold; typing at once into a new terminal, quick pairs of creates, and the focus oracle are weak. The
  verdict is DIAGNOSTIC and no clean file is written.

Verdict: CLEAN (no failure on the build, no speed regression, every round ran, at least --minutes of fuzz, not
diagnostic: writes HANDOFF/<JOB>.clean, default /Users/lawrence/fun/wt/handoff/dogfood-fuzz), RED (a failure or a
speed regression), NOT JUDGED (a round did not run), DIAGNOSTIC. Writes OUT/summary.json and OUT/summary.txt.
Exit 0 CLEAN, 1 RED, 75 NOT JUDGED or DIAGNOSTIC without a red, 2 usage. Fleet only: never on a person's Mac.
"""
import argparse
import calendar
import importlib.util
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import ext_fuzz  # noqa: E402  (plan, CORPUS; nothing of it runs at import)

JOURNEY = "action-fuzz"
HANDOFF = Path("/Users/lawrence/fun/wt/handoff/dogfood-fuzz")
# cmux17 is reserved for the Cua grant (STATUS "CUA GRANTED cmux17"); cmux16 is Leo's builder.
# cmux20-bench is the quiet measurement host (cmux-ad 07:1xZ): no fuzz there except row m on --host cmux20, one lease.
# cmux21 holds the tip watcher's smoke candidates since 08:47Z (mini scheduler 09:1xZ): not a default fuzz host.
# cmux18, 22, 23 and 24 are in the scheduler's Cua grant list (lead 09:3xZ): each needs an empty slot until STATUS has
# a line that starts with "CUA GRANTED <mini>"; a fuzz run names them in --hosts only after that line.
DEFAULT_HOSTS = "cmux19"
# A speed regression: at least MIN_SAMPLES on each side, the build's median above the base's by RATIO and by
# FLOOR_MS, and its p90 worse too (one slow sample does not make a red).
MIN_SAMPLES = 4
RATIO = 1.25
FLOOR_MS = 40


def load_gate():
    """smoke-gate.py's helpers (idle_first, exclusive_line, pressure): the same lease rules as the gate."""
    spec = importlib.util.spec_from_file_location("smoke_gate", HERE / "smoke-gate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pct(values, q):
    values = sorted(values)
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return round(values[lo] + (values[hi] - values[lo]) * (k - lo), 1)


def speed_table(rows):
    """rows: [{build: "test"|"base", seed, a, t, shown_ms, typeable_ms}] -> per (action, timing, mark): each side's
    n, p50, p90, max, and `red` when the build is slower by the rule above."""
    groups = {}
    for r in rows:
        for mark in ("shown_ms", "typeable_ms"):
            if r.get(mark) is None:
                continue
            key = (r["a"], r["t"] if r["t"] == "slow" else "quick", mark)
            side = groups.setdefault(key, {"test": [], "base": [], "seeds": set()})
            side[r["build"]].append(float(r[mark]))
            side["seeds"].add(r["seed"])
    table = []
    for (action, timing, mark), g in sorted(groups.items()):
        row = {"action": action, "timing": timing, "mark": mark, "seeds": sorted(g["seeds"])[:12]}
        for side in ("test", "base"):
            v = g[side]
            row[side] = {"n": len(v), "p50": pct(v, 0.5), "p90": pct(v, 0.9), "max": max(v) if v else None}
        t, b = row["test"], row["base"]
        row["red"] = bool(t["n"] >= MIN_SAMPLES and b["n"] >= MIN_SAMPLES and t["p50"] > b["p50"] * RATIO
                          and t["p50"] - b["p50"] >= FLOOR_MS and t["p90"] >= b["p90"])
        row["delta_p50_ms"] = round(t["p50"] - b["p50"], 1) if t["p50"] is not None and b["p50"] is not None else None
        table.append(row)
    return table


def fuzz_report(out):
    path = out / JOURNEY / "fuzz.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except ValueError:
        return None


def journey_problems(out, report):
    """What failed in the round's journey besides the fuzz's own verdict: a step that failed (smoke_ready, a fuzz_run
    that stopped on a harness error and wrote no failure) or a check of the final expect other than fuzz_clean
    (fuzz_daemon_agrees, the frame). A round with such a problem is never clean."""
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return []
    try:
        result = json.loads(path.read_text())
    except ValueError:
        return ["result.json does not parse"]
    if result.get("status") == "not run" or (result.get("harness") or {}).get("pinned") is False:
        # run.py judged the round not run (an unpinned harness, the lease deadline, a known gap): its steps are no
        # evidence either way, so none of them makes the round broken (RED); it counts as not run.
        return []
    problems = []
    for st in result.get("steps") or []:
        if st.get("ok") is not False or st.get("finally"):
            continue
        if st.get("do") == "fuzz_run" and (report or {}).get("failure"):
            continue  # the fuzz's own failure, judged from fuzz.json
        if st.get("do") == "expect":
            continue  # judged check by check below
        problems.append(f"step {st.get('index')} ({st.get('do')}): {(st.get('error') or '')[:240]}")
    for ev in result.get("evidence") or []:
        if ev.get("pass") is False and ev.get("check") != "fuzz_clean":
            problems.append(f"check {ev.get('check')} failed: {json.dumps(ev.get('detail'), default=str)[:240]}")
    return problems


def journey_row(out):
    path = out / "results.jsonl"
    if not path.is_file():
        return {"status": "not run", "reason": "run.py wrote no results.jsonl"}
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == JOURNEY:
            return row
    return {"status": "not run", "reason": "no action-fuzz line"}


def wait_go(opts, what):
    """The mini scheduler's hand-off (--go-dir DIR --go-spec NAME, its mini-queue/rounds/ protocol): before a round
    acquires, wait for DIR/NAME.go ({"spec", "host", "worker", "go", "until"}): the scheduler holds that mini free for
    5 min, so the round never waits in a capture-host drain behind fleet steps. The go file is consumed; a go whose
    `until` has passed is dropped (the scheduler writes a new one). Returns the mini to lease."""
    d = Path(opts.go_dir)
    d.mkdir(parents=True, exist_ok=True)
    go = d / f"{opts.go_spec}.go"
    print(f"fuzz: {what} waits for {go}", flush=True)
    # The minis this run may lease: --whole-host's one mini (normal mode), else --host, else --hosts. A go for another
    # mini is dropped, so the lease is always the mini the scheduler holds and the run may use.
    allowed = (getattr(opts, "whole_host", None) or opts.host or opts.hosts).split()
    while True:
        while not go.exists():
            time.sleep(5)
        try:
            data = json.loads(go.read_text() or "{}") or {}
        except ValueError:
            data = {}
        try:
            go.unlink()
        except FileNotFoundError:
            pass
        host, until, stamp = data.get("host"), data.get("until"), data.get("go")
        if stamp is not None and stamp == getattr(opts, "last_go", None):
            # The same GO again (a copy the scheduler left, or a re-read): one GO is one lease, never two.
            print(f"fuzz: dropped a go file that repeats the last GO ({stamp})", flush=True)
            continue
        expired = False
        if isinstance(until, (int, float)):
            expired = until < time.time()
        elif isinstance(until, str):
            try:
                expired = calendar.timegm(time.strptime(until[:19], "%Y-%m-%dT%H:%M:%S")) < time.time()  # UTC
            except ValueError:
                expired = True  # an until that cannot be read is no hold: wait for the next go
        if not host or host not in allowed or expired:
            print(f"fuzz: dropped a go file ({data}): host not in {allowed} or past its until", flush=True)
            continue
        print(f"fuzz: {what} goes on {host} (scheduler hold until {until})", flush=True)
        opts.last_go = stamp
        if isinstance(until, str):
            until = calendar.timegm(time.strptime(until[:19], "%Y-%m-%dT%H:%M:%S"))
        return host, (float(until) if isinstance(until, (int, float)) else None)


def signal_done(opts, what, host, status):
    """After the round released its lease: DIR/NAME.done (the scheduler gives the mini back to its queue)."""
    # "go": the GO this lease used, so the scheduler ends that GO's hold only (STATUS 1590): a .done written after the
    # scheduler already wrote the next GO must not end the next one.
    (Path(opts.go_dir) / f"{opts.go_spec}.done").write_text(json.dumps({"spec": opts.go_spec, "what": what, "host": host,
                                                                        "status": status, "at": time.time(),
                                                                        "go": getattr(opts, "last_go", None)}) + "\n")


def replay_options(seq, opts):
    """The journey options of one replay of SEQ (no shrink in the app, the run's set, the size trace on)."""
    return {"fuzz_sequence": json.dumps(seq, separators=(",", ":")), "fuzz_shrink": "false", "fuzz_set": opts.set,
            "fuzz_trace": "1"}


def repro_journey(failure, sequence, seed, build):
    """A regression journey that plays SEQUENCE once (no shrink) and must stay clean: red on the build it was found on."""
    ident = f"found-{failure['oracle']}-{seed}".lower()
    spec = json.loads((HERE / "journeys" / "fuzz" / "action-fuzz.json").read_text())
    spec.update(id=ident, priority="P1",
                title=f"fuzz repro ({failure['oracle']}): {' '.join(i['a'] for i in sequence)[:160]}",
                why=f"action fuzz, seed {seed}, build {build}: {failure['detail'][:300]}",
                source="scripts/journeys/fuzz.py (shrunk by ext_fuzz.ddmin)")
    for step in spec["steps"]:
        if step["do"] == "fuzz_run":
            step.clear()
            step.update({"do": "fuzz_run", "sequence": sequence, "shrink": False, "budget_s": 150})
    return ident, spec


class Runner:
    def __init__(self, opts, gate):
        self.opts, self.gate = opts, gate

    def lease(self, build, out, options, host=None):
        """One run.py round: the fuzz journey on BUILD in an exclusive lease (on HOST when given); (exit code,
        journey row, fuzz report, the mini it ran on). With --go-dir every lease (rounds, ddmin tries, confirmations)
        waits for the scheduler's go file and leases only the mini it names, then writes the done file."""
        opts = self.opts
        if opts.go_dir:
            host, until = wait_go(opts, out.name)
            try:
                return self._lease(build, out, options, host, until)
            finally:
                signal_done(opts, out.name, host, None)
        return self._lease(build, out, options, host)

    def _lease(self, build, out, options, host=None, until=None):
        opts = self.opts
        env = {**os.environ,
               "CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": os.environ.get("CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS", "600"),
               "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": os.environ.get("CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS", "900"),
               "CAPTURE_HOST_POOL": os.environ.get("CAPTURE_HOST_POOL", self.gate.OWNER_POOL),
               "JOURNEYS_EXCLUDE_HOSTS": " ".join(x for x in (os.environ.get("JOURNEYS_EXCLUDE_HOSTS", "cmux16"),
                                                                "" if opts.allow_cmux17 else "cmux17") if x)}
        # Normal mode leases only its --whole-host mini (wait_go drops a go for any other one); else the go host or
        # the first side's mini of an ABBA pair, else --host, else an idle one of --hosts.
        hosts = opts.whole_host or host or opts.host or self.gate.idle_first(opts.hosts)
        if until is not None:
            # A go-gated round: the scheduler holds the mini until UNTIL, so the acquire waits only that window (counted
            # from the go, not from when the round queued). Past it, the round is "not run" and waits for the next go,
            # never a long drain on a mini the scheduler no longer holds.
            window = int(max(30, until - time.time()))
            env["CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS"] = str(window)
            env["CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS"] = "0"
        env["CAPTURE_HOST_HOSTS"] = env["CAPTURE_HOST_SLOT_HOSTS"] = hosts
        argv = [sys.executable, opts.runner, "--build", build, "--journey", JOURNEY, "--exclusive", "--hosts", hosts,
                "--out", str(out)]
        if opts.hog_swap_gb:
            argv += ["--hog-swap-gb", str(opts.hog_swap_gb)]
        for key, value in options.items():
            argv += ["--journey-option", f"{key}={value}"]
        if opts.diagnostic:
            argv += ["--journey-option", "fuzz_mode=diagnostic"]
        if opts.whole_host:
            argv += ["--whole-host"]  # the whole mini, the app launched active: its window is key (normal mode)
        out.mkdir(parents=True, exist_ok=True)
        with open(out / "run.log", "w") as log:  # live, so a long round can be followed
            proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, text=True, env=env)
            try:
                code = proc.wait()
            except BaseException:
                # fuzz.py was stopped: TERM to run.py (never KILL), whose handler releases the lease, then wait.
                proc.terminate()
                try:
                    proc.wait(timeout=180)
                except subprocess.TimeoutExpired:
                    proc.kill()
                raise
        row = journey_row(out)
        return code, row, fuzz_report(out), (row.get("host") or None)


def summarize(rounds, opts, started):
    test = [r for r in rounds if r["build"] == "test"]
    base = [r for r in rounds if r["build"] == "base"]
    fails = [r for r in test if r.get("failure")]
    base_fails = [r for r in base if r.get("failure")]
    # The test side treats a failed step without a fuzz oracle as broken. The baseline is
    # also essential to a CLEAN A/B certificate: its failed/missing evidence is unjudged.
    # A real baseline fuzz failure *with an oracle* remains judged when the test fixes it.
    unjudged_base = [r for r in base if (
        r.get("journey_problems")
        or r.get("status") not in ("pass", "fail")
        or (r.get("status") == "fail" and not r.get("failure"))
        or not r.get("played")
        or r.get("seconds") is None
    )]
    base_by_round = {r["round"]: r for r in base}
    missing_base = [r["round"] for r in test if r["round"] not in base_by_round
                    or r.get("seed") != base_by_round[r["round"]].get("seed")]
    not_run = [r for r in rounds if r["status"] == "not run" and not r.get("failure")]
    broken = [r for r in test if r.get("journey_problems") or (r["status"] == "fail" and not r.get("failure")
                                                               and not r.get("findings"))]
    base_sigs = {f["signature"] for r in rounds if r["build"] == "base" for f in r.get("findings") or []}
    base_fail_oracles = {(r.get("failure") or {}).get("oracle") for r in base_fails}
    findings = {}
    for r in test:
        for f in r.get("findings") or []:
            row = findings.setdefault(f["signature"], dict(f, seeds=[], rounds=0, on_base=f["signature"] in base_sigs))
            row["rounds"] += 1
            if r.get("seed") is not None and r["seed"] not in row["seeds"]:
                row["seeds"].append(r["seed"])
    new_findings = [f for f in findings.values() if not f["on_base"]]
    for f in fails:
        f["also_on_base"] = (f.get("failure") or {}).get("oracle") in base_fail_oracles
    split = {k: sum(((r.get("split_type") or {}).get(k) or 0) for r in test) for k in
             ("played", "hold", "red", "pass_hold", "pass_not_judged", "refused", "creation_hold")}
    split_base = {k: sum(((r.get("split_type") or {}).get(k) or 0) for r in rounds if r["build"] == "base") for k in
                  ("played", "hold", "red", "pass_hold", "pass_not_judged", "refused", "creation_hold")}
    speed = speed_table([dict(s, build=r["build"], seed=r["seed"]) for r in rounds for s in r.get("speed") or []])
    reds = [s for s in speed if s["red"]]
    base_speed_samples = sum(row["base"]["n"] for row in speed)
    fuzz_s = sum(r.get("seconds") or 0 for r in test)
    actions = sum(r.get("played") or 0 for r in test)
    if fails or reds or broken or (new_findings if opts.base else findings):
        verdict = "RED"
    elif opts.diagnostic:
        verdict = "DIAGNOSTIC (NOT JUDGED)"
    elif opts.replay:
        verdict = "REPLAY PASSED (NOT JUDGED)"
    elif not opts.base:
        verdict = "NO A/B (NOT JUDGED)"  # a clean file needs the speed A/B against a base build
    elif (not_run or unjudged_base or missing_base or not base_speed_samples
          or opts.minutes <= 0 or not actions or fuzz_s < opts.minutes * 60):
        verdict = "NOT JUDGED"
    else:
        verdict = "CLEAN"
    return {"build": opts.build, "base": opts.base, "set": opts.set, "verdict": verdict, "diagnostic": opts.diagnostic,
            "rounds": len(rounds), "test_rounds": len(test), "not_run": len(not_run), "actions": actions,
            "fuzz_seconds": round(fuzz_s), "wall_seconds": round(time.time() - started),
            "seeds": sorted({r["seed"] for r in test if r.get("seed") is not None}),
            "failures": [{k: r.get(k) for k in ("round", "seed", "host", "failure", "shrunk", "shrink_leases", "confirmed",
                                                "repro", "corpus", "also_on_base")} for r in fails],
            "findings": sorted(findings.values(), key=lambda f: (f["on_base"], f["oracle"])),
            "split_type": split, "split_type_base": split_base,
            "broken_rounds": [{k: r.get(k) for k in ("round", "seed", "host", "status", "reason", "journey_problems")} for r in broken],
            "unjudged_base_rounds": [{k: r.get(k) for k in ("round", "seed", "host", "status", "reason", "journey_problems")}
                                      for r in unjudged_base],
            "missing_base_rounds": missing_base, "base_speed_samples": base_speed_samples,
            "base_failures": [{k: r.get(k) for k in ("round", "seed", "host", "failure", "shrunk", "corpus")} for r in base_fails],
            "speed": speed, "speed_reds": reds,
            "weak_oracles": (["typeable at once (keys wait out the 2.5 s creation hold after a create)",
                              "quick pairs of creates (the second key waits too)",
                              "focus (a slot has no key window; AppKit has no first responder to compare)"]
                             if opts.diagnostic else []),
            "rounds_detail": rounds}


def text_of(summary):
    s = summary
    lines = [f"action fuzz ({s['set']}) of build {s['build']}" + (f" vs base {s['base']}" if s["base"] else "")
             + f": {s['verdict']} ({s['test_rounds']} rounds, {s['actions']} actions, {s['fuzz_seconds']} s of fuzz, "
             f"{s['not_run']} rounds not run; seeds {s['seeds'][:10]})"]
    for name, sp in (("build", s.get("split_type") or {}), ("base", s.get("split_type_base") or {})):
        if sp.get("played"):
            lines.append(f"  split + type at once ({name}): n(hold)/n(rounds) = {sp['hold']}/{sp['played']}; red {sp['red']}, "
                         f"pass on the hold path {sp['pass_hold']}, pass not judged (no key held) {sp['pass_not_judged']}; "
                         f"creation-hold hook rounds {sp.get('creation_hold', 0)}, refused by the app {sp.get('refused', 0)}"
                         + ("; HOLD PATH NOT PROVEN: no pass of this action is judged" if not sp["hold"] else ""))
    if s["weak_oracles"]:
        lines.append("DIAGNOSTIC (no key window on a slot): weak oracles: " + "; ".join(s["weak_oracles"]))
    for f in s["failures"]:
        fl = f["failure"] or {}
        lines.append(f"  FAIL {fl.get('oracle')} seed {f['seed']} round {f['round']} on {f['host']}"
                     + (" (the base fails the same oracle)" if f.get("also_on_base") else "") + f": {str(fl.get('detail'))[:220]}")
        lines.append(f"       shrunk to {len(f['shrunk'] or [])} actions: {json.dumps(f['shrunk'])[:400]}"
                     f" (confirmed in a fresh lease: {f.get('confirmed')}; repro {f.get('repro')})")
    for r in s["broken_rounds"]:
        lines.append(f"  BROKEN round {r['round']} seed {r['seed']} on {r['host']}: "
                     + "; ".join(r.get("journey_problems") or [str(r.get("reason"))])[:300])
    for r in s["unjudged_base_rounds"]:
        lines.append(f"  UNJUDGED BASE round {r['round']} seed {r['seed']} on {r['host']}: "
                     + "; ".join(r.get("journey_problems") or [f"{r['status']}: {r.get('reason') or 'no fuzz result'}"])[:300])
    if s["missing_base_rounds"]:
        lines.append(f"  MISSING BASE round(s) or seed mismatch: {s['missing_base_rounds']}")
    if s["base"] and not s["base_speed_samples"]:
        lines.append("  UNJUDGED BASE speed: zero timing samples from the comparison build")
    for f in s["findings"]:
        lines.append(f"  {'base finding (also on the base)' if f['on_base'] else 'FINDING'} {f['oracle']} x{f['count']} in "
                     f"{f['rounds']} rounds, seeds {f['seeds'][:5]}: {str(f['detail'])[:200]}")
        lines.append(f"       actions before it: {' '.join(i['a'] for i in f.get('sequence') or [])[:200]}")
    for f in s["base_failures"]:
        fl = f["failure"] or {}
        lines.append(f"  base finding {fl.get('oracle')} seed {f['seed']}: {str(fl.get('detail'))[:200]}")
    for row in s["speed"]:
        if row["test"]["n"] or row["base"]["n"]:
            lines.append(f"  speed {row['action']:<15} {row['timing']:<5} {row['mark']:<12} build p50 {row['test']['p50']} "
                         f"p90 {row['test']['p90']} (n {row['test']['n']}) | base p50 {row['base']['p50']} p90 "
                         f"{row['base']['p90']} (n {row['base']['n']}) | delta p50 {row['delta_p50_ms']} ms"
                         + ("  RED" if row["red"] else ""))
    return "\n".join(lines)


class Stopped(BaseException):
    """SIGTERM of fuzz.py: raised so the round's run.py gets TERM and releases its lease (Runner.lease)."""


def _stopped(signum, frame):
    raise Stopped(f"signal {signum}")


def main(argv=None):
    import signal
    import threading
    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, _stopped)
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--build", help="the fleet build job id under test")
    ap.add_argument("--base", help="the base build job id for the speed A/B (same seeds, same mini, interleaved)")
    ap.add_argument("--minutes", type=float, default=10.0, help="fuzz time on the build (the base gets as much)")
    ap.add_argument("--seed", type=int, help="the first seed (default: from the clock); round N plays seed + N - 1")
    ap.add_argument("--count", type=int, default=300, help="actions planned per round (a round stops at its budget)")
    ap.add_argument("--set", default="layout", choices=sorted(ext_fuzz.SETS),
                    help="the action set: layout (fuzz-catalog row m, the first mode: R3a/R3b under New Column, Cmd-D, "
                         "Split Down, Ctrl-`, close pane, divider drag, window resize, relaunch) or full (every action)")
    ap.add_argument("--corpus", action="store_true", help="play Lawrence's reported-bug sequences first")
    ap.add_argument("--diagnostic", action="store_true", help="a slot with no key window: keys wait out the creation hold")
    ap.add_argument("--hog-swap-gb", type=float, default=0.0, help="the memory hog (smoke_hog.py) for each round")
    ap.add_argument("--hosts", default=DEFAULT_HOSTS)
    ap.add_argument("--host", help="pin every round to this mini (the A/B is then on one host for the whole run)")
    ap.add_argument("--allow-cmux17", action="store_true", help="only after STATUS says CUA GRANTED cmux17")
    ap.add_argument("--whole-host", metavar="HOST",
                    help="normal mode: lease this whole mini (exclusive) and launch the app active, so its window is key "
                         "and keys are typed at once (needs CuaDriver's grants and its direct-capture Allow on HOST)")
    ap.add_argument("--go-dir", help="the mini scheduler's hand-off folder (mini-queue/rounds): each round waits for "
                                     "DIR/<--go-spec>.go ({\"host\": MINI, \"until\": ...}) before it acquires, and "
                                     "writes DIR/<--go-spec>.done after the release")
    ap.add_argument("--go-spec", default="fuzz", help="the spec name of the scheduler's go and done files")
    ap.add_argument("--shrink-tries", type=int, default=None,
                    help="ddmin tries per failure (one short lease each); default 10, and 0 for --replay (a replay is "
                         "the confirmation of a repro; give a number to shrink it further, e.g. a 3-action repro that "
                         "may need fewer)")
    ap.add_argument("--replay", help="a repro JSON (a sequence list, or a file with `shrunk`/`sequence`): one round")
    ap.add_argument("--plan", action="store_true", help="print the plan of --seed and exit (no fleet)")
    ap.add_argument("--out")
    ap.add_argument("--handoff", default=str(HANDOFF))
    ap.add_argument("--runner", default=str(HERE / "run.py"), help=argparse.SUPPRESS)  # tests: a stand-in for run.py
    opts = ap.parse_args(argv)
    seed0 = opts.seed if opts.seed is not None else int(time.time()) % 1000000
    if opts.plan:
        for item in ext_fuzz.plan(seed0, opts.count, actions=opts.set):
            print(json.dumps(item))
        return 0
    if not opts.build:
        ap.error("--build JOB is required")
    if not opts.diagnostic and not opts.whole_host and not opts.plan:
        ap.error("normal mode needs a key window: --whole-host HOST (a granted mini), else --diagnostic (a slot)")
    if opts.whole_host and opts.diagnostic:
        ap.error("--whole-host is the normal mode: drop --diagnostic")
    if "cmux17" in (opts.host, opts.whole_host) and not opts.allow_cmux17:
        ap.error("cmux17 is reserved for the Cua grant: --allow-cmux17 only after STATUS says CUA GRANTED cmux17")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(opts.out) if opts.out else ROOT / "artifacts" / "fuzz" / f"{opts.build[:12]}-{stamp}"
    if out.exists() and any(out.iterdir()):
        ap.error(f"--out {out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    gate = load_gate()
    runner = Runner(opts, gate)
    started = time.time()
    rounds = []

    # The work: (label, options) per round. Corpus entries first, then seeds until the time is spent.
    work = []
    if opts.replay:
        data = json.loads(Path(opts.replay).read_text())
        seq = data if isinstance(data, list) else (data.get("shrunk") or data.get("sequence"))
        work.append(("replay", replay_options(seq, opts), None))
    else:
        if opts.corpus:
            # Lawrence's reported bugs, one round (a close-all between them): ext_fuzz.CORPUS_SETS[--set].
            seq = ext_fuzz.corpus_sequence(ext_fuzz.CORPUS_SETS[opts.set])
            work.append(("corpus", {"fuzz_sequence": json.dumps(seq, separators=(",", ":")), "fuzz_set": opts.set}, None))

    def play(label, options, seed, n):
        # ABBA over rounds; the second side plays on the mini the first one got.
        order = ["test", "base"] if not opts.base or n % 2 == 1 else ["base", "test"]
        host = opts.host
        for side in order:
            if side == "base" and not opts.base:
                continue
            job = opts.build if side == "test" else opts.base
            r_out = out / f"round-{n:03d}-{side}"
            code, row, report, used = runner.lease(job, r_out, options, host)
            host = host or used
            rec = {"round": n, "build": side, "job": job, "label": label, "seed": seed if seed is not None else (report or {}).get("seed"),
                   "host": used, "status": row.get("status"), "reason": (row.get("reason") or "")[:300], "exit": code,
                   "played": (report or {}).get("played"), "seconds": (report or {}).get("seconds"),
                   "failure": (report or {}).get("failure"), "shrunk": (report or {}).get("shrunk"),
                   "speed": (report or {}).get("speed") or [], "findings": (report or {}).get("findings") or [],
                   "journey_problems": journey_problems(r_out, report),
                   "split_type": (report or {}).get("split_type"), "corpus": label == "corpus",
                   "exclusive": gate.exclusive_line(r_out), "pressure": gate.pressure(r_out, opts.hog_swap_gb) if opts.hog_swap_gb else None}
            rounds.append(rec)
            print(f"round {n} {side} ({label}, seed {rec['seed']}) on {used}: {rec['status']}"
                  + (f" FAIL {rec['failure']['oracle']}: {rec['failure']['detail'][:160]}" if rec["failure"] else
                     f" ({rec['reason'][:160]})" if rec["status"] != "pass" else f" {rec['played']} actions"), flush=True)

    n = 0
    for label, options, seed in work:
        n += 1
        play(label, options, seed, n)
    if not opts.replay:
        budget = opts.minutes * 60
        while sum(r.get("seconds") or 0 for r in rounds if r["build"] == "test") < budget:
            n += 1
            seed = seed0 + n - 1
            play("seed", {"fuzz_seed": str(seed), "fuzz_count": str(opts.count), "fuzz_set": opts.set}, seed, n)
            test_rounds = [r for r in rounds if r["build"] == "test"]
            if len(test_rounds) >= 3 and not any(r.get("seconds") for r in test_rounds[-3:]):
                print("fuzz: three rounds in a row played nothing; stopping", flush=True)
                break
            if time.time() - started > budget * 6 + 1800:
                print("fuzz: the wall clock is six times the fuzz budget; stopping", flush=True)
                break

    # Shrink each failure of the build OUTSIDE its lease (cmux-ad 09:05Z: a lease is held only while journey steps
    # run): ddmin, each try one short replay lease with a fresh app, at most --shrink-tries; the smallest failing
    # sequence is then confirmed (a try that failed with the same oracle, else one more lease) and written as a
    # regression journey. The same failure is shrunk once (by oracle and signature), not per round.
    repros, done_sigs, k = out / "repros", set(), 0
    # A --replay plays a sequence that is already a repro: by default it is the confirmation only, not shrunk again
    # (each ddmin try spends a lease). An explicit --shrink-tries N shrinks it too (a replayed 3-action R3b repro on
    # cmux20 at 12:3xZ shrank to New Column alone).
    if opts.shrink_tries is None:
        opts.shrink_tries = 0 if opts.replay else 10
    for r in [r for r in rounds if r["build"] == "test" and r.get("failure") and opts.shrink_tries > 0]:
        sig = ext_fuzz.signature(r["failure"]["oracle"], r["failure"]["detail"])
        report = fuzz_report(out / f"round-{r['round']:03d}-test") or {}
        seq = r.get("shrunk") or report.get("sequence") or []
        if not seq or sig in done_sigs:
            continue
        done_sigs.add(sig)
        failed, tries = set(), [0]

        def fails(cand, r=r):
            if tries[0] >= opts.shrink_tries:
                return None
            tries[0] += 1
            nonlocal k
            k += 1
            code, row, rep_, used = runner.lease(opts.build, out / f"shrink-{r['round']:03d}-{k:02d}", replay_options(cand, opts))
            got = (rep_ or {}).get("failure")
            if rep_ is None or row.get("status") == "not run":
                return None
            hit = bool(got) and got.get("oracle") == r["failure"]["oracle"]
            if hit:
                failed.add(json.dumps(cand, sort_keys=True))
            return hit
        small, _ = ext_fuzz.ddmin(seq, fails) if len(seq) > 1 else (seq, 0)
        r["shrunk"], r["shrink_leases"] = small, tries[0]
        r["confirmed"] = json.dumps(small, sort_keys=True) in failed
        if not r["confirmed"]:
            code, row, rep_, used = runner.lease(opts.build, out / f"confirm-{r['round']:03d}", replay_options(small, opts))
            again = (rep_ or {}).get("failure")
            r["confirmed"] = bool(again) and again.get("oracle") == r["failure"]["oracle"]
            r["confirm_detail"] = (again or {}).get("detail") or row.get("reason")
        repros.mkdir(exist_ok=True)
        ident, spec = repro_journey(r["failure"], small, r["seed"], opts.build)
        for st in spec["steps"]:
            if st["do"] == "fuzz_run":
                st["set"] = opts.set
        (repros / f"{ident}.json").write_text(json.dumps(spec, indent=1) + "\n")
        r["repro"] = str(repros / f"{ident}.json")

    summary = summarize(rounds, opts, started)
    summary["out"] = str(out)
    (out / "summary.json").write_text(json.dumps(summary, indent=1, default=str) + "\n")
    text = text_of(summary)
    (out / "summary.txt").write_text(text + "\n")
    print(text)
    if summary["verdict"] == "CLEAN":
        handoff = Path(opts.handoff)
        handoff.mkdir(parents=True, exist_ok=True)
        sp = summary.get("split_type") or {}
        summary["split_type_hold_proven"] = bool(sp.get("hold"))  # TIP RED 1193: a clean run says if it judged a hold
        (handoff / f"{opts.build}.clean").write_text(json.dumps({k: v for k, v in summary.items() if k != "rounds_detail"},
                                                                indent=1, default=str) + "\n")
        print(f"wrote {handoff / (opts.build + '.clean')}")
        return 0
    return 1 if summary["verdict"] == "RED" else 75


if __name__ == "__main__":
    sys.exit(main())
