#!/usr/bin/env python3
"""The dogfood smoke gate: a build goes to Lawrence only when the smoke journey passes 10 of 10 rounds.

    scripts/journeys/smoke-gate.py --build JOB [--rounds 10] [--swap-gb 15] [--hosts "cmux17 ..."] [--out DIR]

cmux-ad 2026-10-30 (stop the line, item 2). Runs journeys/dogfood/smoke-dogfood.json once per round through
run.py, each round on its own exclusive capture-host lease (`--exclusive`: no fleet step runs on the mini) with
the Austin's-day memory hog pushing swap toward --swap-gb above the start (`--hog-swap-gb`). Each step of the
journey is checked by the app's own state (socket and CLI reads) and, where the step shows text, a window frame
read by text recognition (run.py keeps each checked frame as <round>/smoke-dogfood/check-NN.png).

Verdict:
  - PASS only when every round's journey status is `pass` (10 of 10 by default) and each round reached and passed,
    exactly once, every R3a and R3b check (REQUIRED_CHECKS). A round whose journey passed without them is a FAIL
    naming the missing checks; one that failed earlier stays a FAIL; one that did not run stays NOT JUDGED. None of
    them is ever a pass. Then it writes
    HANDOFF/<JOB>.pass (default /Users/lawrence/fun/wt/handoff/dogfood-smoke): the summary, the build, every
    round's lease and results, and this gate's own git commit. A gate with uncommitted changes never writes it.
  - FAIL when any round failed: the summary names each failing round, its step and the reason.
  - NOT JUDGED when no round failed but some did not run (no lease, a known gap, no memory pressure): no .pass
    file. A round whose type-at-once step could not make the window key (`known gap: ...`) is never a pass, and
    a passed journey counts only when the round's hog log shows memory pressure (pressure() below). Such a round
    is run again in its slot (at most --rounds replacements per run; see the note at PRESSURE_SAMPLES), so the verdict
    stands on --rounds rounds under pressure; the summary names the replaced rounds.
  - TRIAL PASS: every round passed, but with fewer than 10 rounds or less than +15 GB asked of the hog: no .pass.
  - A PASS writes no .pass while an open P0 journey (open-p0-journeys.txt) or a golden video case
    (video-goldens.txt, VIDEO EXTRA item 9) has no PASS, or has a FAIL, on the exact build job, or while the typing
    rule fails (TYPING UNDER LOAD: no judged L6 run on the build, or one with p95 > 1 / max > 2 refreshes, a lost or
    merged key; typing-load-results/<JOB>.jsonl).
Each round must write its own results (a new --out folder; results of this build, newer than the round).
  - DIAGNOSTIC (NOT JUDGED), with --diagnostic: where the slot has no key window, the lines are typed after the
    creation hold, not at once; every other step is checked and each check's pass count is reported. Never a .pass
    file (exit 1 when a round failed, else 75).
Writes OUT/summary.json and OUT/summary.txt. Exit 0 PASS, 1 FAIL, 75 NOT JUDGED, 2 usage.
Never run it on a person's Mac: the hog fills the memory up to swap.
"""
import argparse
import calendar
import json
import re
import shutil
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
JOURNEY = "smoke-dogfood"
HANDOFF = Path("/Users/lawrence/fun/wt/handoff/dogfood-smoke")
# The perf minis' owner-only pool (hq fleet.json owner_only_hosts): the owner's opt-in for their exclusive lease.
OWNER_POOL = "perf-lead"
# cmux-ad 06:38Z (binding): a round passes only when every resize check was REACHED and passed. The checks are the
# journey's expect steps with exactly these titles; each must appear exactly once in the round's result and pass. A
# renamed check is missing and a duplicated one counts as not passed, so neither can stand in for another. A round
# that ends before them is never a pass. test_smoke_gate.py checks that the journey's R3 titles are exactly these.
REQUIRED_CHECKS = (
    "R3a split resize: the right pane is wider, the left narrower; in each, grid == fit(bounds) == PTY == daemon size, "
    "and a long line wraps at the new width",
    "R3a window resize: the window is 160 points narrower and the right pane narrower; grid == fit(bounds) == PTY == "
    "daemon size in the shown terminal, and a long line wraps at the new width",
    "R3b: New Column adds a column and every existing column keeps exactly its width",
    "R3b: New Column's key (the build's binding) adds a column and every existing column keeps exactly its width",
    "R3b: Cmd-D (Split Right) splits the pane inside its own column and every other column keeps exactly its width",
    "R3b: Cmd-Shift-D (Split Down) adds no column and every column keeps exactly its width",
    "R3b: New Column's key (the build's binding) as the first new column of a new one-pane workspace (Cmd-N, Ctrl-`) keeps the "
    "old column's exact width",
)
# Everything run.py ships to the mini: a change in any of them means the gate is not its commit.
GATE_PATHS = ("scripts/journeys", "scripts/cmux-next/build_names.py", "scripts/ci/pr_media_ocr.swift")
# The gate cmux-ad set (2026-10-30): a .pass file needs at least this many rounds under at least this much hog.
GATE_ROUNDS = 10
GATE_SWAP_GB = 15.0
# cmux-ad 13:10Z: each gate run types at least this many of its rounds with REAL HID keys (CuaDriver, the path a
# person's keyboard takes: window server, AppKit, the menu, the responder chain); debug.key enters the app's key
# router directly and cannot see e.g. the palette's Ctrl-` P0 (STATUS 1456). A .pass needs those rounds to pass.
GATE_REAL_KEY_ROUNDS = 2
# The steps whose keys must take the real path in a real-key round (the basic tasks: Cmd-N, Ctrl-`, Cmd-D, Cmd-T,
# Cmd-W, typing). Other steps may use debug.key (e.g. relaunch's Cmd-Q) and say so in result.json.
REAL_KEY_STEPS = ("smoke_key", "smoke_type", "smoke_type_now")


def real_key_rounds(rounds, real):
    """The round numbers (1-based) typed with real keys: REAL of ROUNDS, spread out (the first, then evenly)."""
    real = max(0, min(real, rounds))
    return sorted({1 + (i * rounds) // real for i in range(real)}) if real else []


def key_paths(out):
    """{key path: steps that used it} of the round's result.json, and the steps of REAL_KEY_STEPS that did not take
    the real path (index, do, path)."""
    path = out / JOURNEY / "result.json"
    try:
        steps = json.loads(path.read_text()).get("steps", []) if path.is_file() else []
    except ValueError:
        steps = []
    paths, not_real = {}, []
    for st in steps:
        kp = st.get("key_path")
        if kp:
            paths[kp] = paths.get(kp, 0) + 1
        if st.get("do") in REAL_KEY_STEPS and st.get("ok") and kp != "real_hid":
            not_real.append((st.get("index"), st.get("do"), kp))
    return paths, not_real
# A round counts only when its hog log shows memory pressure during the round: the hog held at least
# PRESSURE_HELD_GB, and swap grew by the hog's target or the free-memory level reached the hog's resume band
# (kern.memorystatus_level <= PRESSURE_LEVEL: the hog is at the mini's edge, where it gives memory back).
PRESSURE_HELD_GB = 4.0
PRESSURE_LEVEL = 20
PRESSURE_SAMPLES = 30
# A round that passed but whose hog log shows no pressure judges nothing (above). It is run again, at most this
# many times per gate run in total (one per gate round), so a build is judged on GATE_ROUNDS rounds under pressure.
# The level the hog reaches varies by round: on cmux17, 12 of 40 rounds (2026-11-01/02, four builds) held 14.25 GB
# and grew swap by 7+ GB like the others, but their lowest level was 21-32, not <= PRESSURE_LEVEL. Without a
# replacement, a build with no fault had about a 3% chance (0.7^10) of a .pass. A replacement round keeps its slot:
# a real-key slot is typed with real keys again. A failed round is never replaced.


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def round_result(out, build, exit_code, started):
    """The smoke journey's line of this round's results.jsonl, or a not-run record: a results file of this
    run.py (written after the round started), for this build, from a run.py that exited 0, 1 or 75."""
    path = out / "results.jsonl"
    if exit_code not in (0, 1, 75):
        return {"status": "not run", "reason": f"run.py exited {exit_code}"}
    if not path.is_file():
        return {"status": "not run", "reason": "run.py wrote no results.jsonl"}
    if path.stat().st_mtime < started:
        return {"status": "not run", "reason": "results.jsonl is older than the round"}
    for line in path.read_text().splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("id") == JOURNEY:
            if row.get("build_job") != build:
                return {"status": "not run", "reason": f"results.jsonl is for build {row.get('build_job')}, not {build}"}
            return row
    return {"status": "not run", "reason": "results.jsonl has no smoke-dogfood line"}


def idle_first(hosts):
    """Only the hosts with no running fleet step (the controller's `cmux-ci drain` read, no command on a mini), so
    an exclusive acquire does not drain a mini whose step runs for hours while another is idle. All the given
    hosts when the read fails or no mini is idle (then the drain waits, within its budget)."""
    names = hosts.split()
    try:
        done = subprocess.run([os.environ.get("SMOKE_GATE_CMUX_CI", "cmux-ci"), "drain", "--hosts", ",".join(names)], capture_output=True, text=True, timeout=60)
        state = json.loads(done.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return hosts
    idle = [h for h in names if isinstance(state.get(h), dict) and state[h].get("idle") is True]
    return " ".join(idle) if idle else hosts


def exclusive_line(out):
    """capture-host's own word that the round's mini was exclusive ("<host> is exclusive until ...: the fleet
    controller places no step on its workers"), from the acquire's lines run.py keeps; None when it is missing."""
    path = out / "acquire.log"
    if not path.is_file():
        return None
    return next((l.strip() for l in path.read_text(errors="replace").splitlines()
                 if " is exclusive until " in l and "places no step" in l), None)


def pressure(out, swap_gb):
    """What the round's hog logs show: samples, the most it held, swap growth and the lowest free level."""
    rows = []
    for path in sorted(out.glob("hog-*.jsonl")):
        for line in path.read_text(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and "held_mb" in row:
                rows.append(row)
    if not rows:
        return {"ok": False, "samples": 0, "why": "no hog log lines"}
    swaps = [float(r.get("swap_used_mb") or 0) for r in rows]
    levels = [int(r["level"]) for r in rows if isinstance(r.get("level"), (int, float))]
    held = max(float(r.get("held_mb") or 0) for r in rows) / 1024
    grown = (max(swaps) - swaps[0]) / 1024
    low = min(levels) if levels else None
    ok = (len(rows) >= PRESSURE_SAMPLES and held >= PRESSURE_HELD_GB
          and (grown >= swap_gb * 0.95 or (low is not None and low <= PRESSURE_LEVEL)))
    return {"ok": ok, "samples": len(rows), "held_gb_max": round(held, 2), "swap_growth_gb": round(grown, 2),
            "level_min": low, "swap_target_reached": grown >= swap_gb * 0.95}


def failing_step(out):
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return None
    result = json.loads(path.read_text())
    for step in result.get("steps", []):
        # `finally` steps (app_log, debug.focus, close all) only record or clean up: never the round's failing step.
        if step.get("ok") is False and not step.get("finally"):
            return {"do": step.get("do"), "title": step.get("title"), "error": (step.get("error") or "")[:400]}
    return None


def required_checks(out):
    """{required title: [ok of each expect step with exactly that title]} from the round's result.json."""
    found = {title: [] for title in REQUIRED_CHECKS}
    path = out / JOURNEY / "result.json"
    try:
        steps = json.loads(path.read_text()).get("steps", []) if path.is_file() else []
    except ValueError:
        steps = []
    for st in steps:
        if st.get("do") == "expect" and not st.get("finally") and st.get("title") in found:
            found[st["title"]].append(st.get("ok") is True)
    return found


def missing_checks(found):
    """The required checks a round did not reach exactly once and pass, as text; empty when all passed."""
    out = []
    for title, oks in found.items():
        if oks != [True]:
            state = "not reached" if not oks else ("failed" if len(oks) == 1 else f"recorded {len(oks)} times")
            out.append(f"{title[:72]}...: {state}")
    return out


def key_gaps(out):
    """The "known gap" texts of key-window checks the round could not judge (a system prompt on the console took the
    keys): a round with any is never a pass."""
    path = out / JOURNEY / "result.json"
    try:
        evidence = json.loads(path.read_text()).get("evidence", []) if path.is_file() else []
    except ValueError:
        return []
    return sorted({str((e.get("detail") or {}).get("not_checked")) for e in evidence
                   if isinstance(e.get("detail"), dict) and (e["detail"] or {}).get("not_checked")})


def typed_steps(out):
    """The results of the round's smoke_type_now steps (each says `at_once`)."""
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return []
    try:
        steps = json.loads(path.read_text()).get("steps", [])
    except ValueError:
        return []
    return [st.get("result") or {} for st in steps if st.get("do") == "smoke_type_now" and st.get("ok")]


def step_results(out):
    """Each step of the round's journey: index, do, title, ok, error (short), for the per-step report."""
    path = out / JOURNEY / "result.json"
    if not path.is_file():
        return []
    try:
        steps = json.loads(path.read_text()).get("steps", [])
    except ValueError:
        return []
    return [{"index": st.get("index"), "do": st.get("do"), "title": st.get("title"), "ok": st.get("ok"),
             "finally": bool(st.get("finally")), "error": (st.get("error") or st.get("not_judged") or "")[:300],
             "not_judged": bool(st.get("not_judged"))} for st in steps]


def frames(out):
    return sorted(str(p.relative_to(out)) for p in (out / JOURNEY).glob("check-*.png")) if (out / JOURNEY).is_dir() else []


def expect_table(rounds):
    """For each expect step (by its title): in how many rounds it was reached, passed and failed."""
    table = {}
    for r in rounds:
        for st in r["steps"]:
            if st["do"] != "expect" or st["finally"]:
                continue
            row = table.setdefault(st["title"] or f"step {st['index']}",
                                   {"reached": 0, "passed": 0, "failed": 0, "not_judged": 0, "errors": []})
            row["reached"] += 1
            row["not_judged" if st.get("not_judged") else "passed" if st["ok"] else "failed"] += 1
            if not st["ok"] and len(row["errors"]) < 3:
                row["errors"].append(f"round {r['round']}: {st['error'][:200]}")
    return table


# --go-spec (the tip watcher, 11:3xZ; lead STATUS 1354: a scheduler GO gives ONE round): the gate waits for a new GO of its
# spec before each round, so one gate run of 10 rounds (and its .pass) is made of 10 GO rounds. A round takes its lease only
# on the GO's mini and before the GO's "until": capture-host's acquire timeout + exclusive drain (the drain moves the
# acquire's deadline on) <= until - now - GO_MARGIN. A GO with less than GO_MIN_LEFT s left is given back unused. A .done
# is written only while that same GO is still the open one (a .done for an older GO would end the next GO).
SCHED_ROUNDS = Path(os.environ.get("SMOKE_GATE_SCHED_ROUNDS", "/work/wt/chrome-parity-design/mini-queue/rounds"))
GO_MARGIN, GO_MIN_LEFT = 20, 60


def _utc(text):
    try:
        return calendar.timegm(time.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, OverflowError):
        return None


def read_go(spec):
    """{"host", "go", "until"} (epoch s) of the scheduler's open GO file of SPEC, or None."""
    try:
        d = json.loads((SCHED_ROUNDS / f"{spec}.go").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict):
        return None
    go, until = _utc(d.get("go")), _utc(d.get("until"))
    return {"host": d["host"], "go": go, "until": until} if d.get("host") and go and until else None


def go_done(spec, go, cell, status=None):
    """The .done that ends GO, only while GO is still the open one. STATUS "not run" (a GO given back, a round with no
    lease) tells the scheduler the GO did not use up one of the spec's rounds."""
    cur = read_go(spec)
    if not (cur and cur["go"] == go["go"] and cur["host"] == go["host"]):
        return False
    tmp = SCHED_ROUNDS / f"{spec}.done.tmp"
    tmp.write_text(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "cell": cell,
                               **({"status": status} if status else {})}) + "\n")
    os.replace(tmp, SCHED_ROUNDS / f"{spec}.done")
    return True


def await_go(spec, hosts, used, deadline, poll=5.0):
    """(GO, "") of the next usable GO of SPEC on one of HOSTS that this run has not used yet (USED: their "go" times),
    or (None, why) after DEADLINE. A GO outside HOSTS or with too little window left is given back unused."""
    while True:
        go = read_go(spec)
        if go and go["go"] not in used:
            left = go["until"] - time.time()
            if go["host"] in hosts and left >= GO_MIN_LEFT:
                return go, ""
            if left > 0:
                print(f"GO for {go['host']} given back: " + (f"not in --hosts" if go["host"] not in hosts
                      else f"{left:.0f} s of its window left (< {GO_MIN_LEFT} s)"), flush=True)
                go_done(spec, go, "given back", "not run")
            used.add(go["go"])
        if time.time() > deadline:
            return None, f"the scheduler gave no GO of {spec} within the wait"
        time.sleep(poll)


# Open P0 journeys (cmux-ad 12:35Z): a .pass also needs each open P0 journey to have passed, and never failed, on the
# exact build job: a pass by omission (the gate does not test that P0) is no pass.
OPEN_P0 = Path(os.environ.get("SMOKE_GATE_OPEN_P0", "/Users/lawrence/fun/wt/handoff/open-p0-journeys.txt"))
P0_LEDGER = Path(os.environ.get("JOURNEYS_P0_LEDGER", "/Users/lawrence/fun/wt/handoff/open-p0-results"))
# A FAIL row shown to be the kit's own fault (a false red) is waived by a line "<the row's out path> <reason>"; the
# waiver is named in open-p0.txt and the .pass. Old kits are never ignored automatically: a real red can come from any.
P0_WAIVERS = Path(os.environ.get("SMOKE_GATE_P0_WAIVERS", "/Users/lawrence/fun/wt/handoff/open-p0-waivers.txt"))


def p0_waivers():
    try:
        return {f[0]: f[1] for f in (l.split(None, 1) for l in P0_WAIVERS.read_text().splitlines()
                                     if l.strip() and not l.lstrip().startswith("#")) if len(f) == 2}
    except OSError:
        return {}


def open_p0_blockers(job, waived=None):
    """[(list line, why)] of the open P0 journeys that block a .pass for JOB: no PASS on JOB in the ledger, or any FAIL.
    An unreadable list blocks too (the rule cannot be checked)."""
    try:
        listed = [l.split() for l in OPEN_P0.read_text().splitlines() if l.strip() and not l.lstrip().startswith("#")]
    except OSError as error:
        return [(str(OPEN_P0), f"the open-P0 list cannot be read ({error}): no .pass")]
    rows = []
    try:
        for text in (P0_LEDGER / f"{job}.jsonl").read_text().splitlines():
            try:
                row = json.loads(text)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("build_job") == job:
                rows.append(row)
    except OSError:
        pass
    blockers, waivers = [], p0_waivers()
    for fields in listed:
        ids = set(fields[0].split("|"))
        mine = [r for r in rows if r.get("id") in ids]
        fails = []
        for r in mine:
            if r.get("status") != "fail":
                continue
            if str(r.get("out")) in waivers:
                if waived is not None:
                    waived.append({"out": r.get("out"), "id": r.get("id"), "reason": waivers[str(r.get("out"))]})
                continue
            fails.append(r)
        # Only a pass of a clean kit in the judged mode counts (a diagnostic round types after the hold and does not
        # check the key window; a dirty tree is not the kit the commit names).
        passes = [r for r in mine if r.get("status") == "pass" and r.get("kit_dirty") is False
                  and (r.get("options") or {}).get("smoke_mode") != "diagnostic"]
        line = " ".join(fields)
        if fails:
            blockers.append((line, f"FAILED on {job}: {len(fails)} fail(s), e.g. {fails[0].get('out')}: "
                                   f"{str(fails[0].get('reason') or '')[:160]}"))
        elif not passes:
            blockers.append((line, f"has not passed on {job} ({len(mine)} result(s), none a pass of a clean kit in the "
                                   "judged mode)"))
    return blockers


# Video goldens (VIDEO EXTRA item 9, lead 2026-11-02 00:29Z): each finding of the video program, once fixed, keeps
# its case's clean video as a golden. A later build's run of the same case is judged against it by
# video_golden.py (the case's own judge plus the end layout), which appends one row per run to the ledger. A .pass
# also needs each listed golden case to have passed, and never failed, on the exact build job: the same rule as the
# open P0 journeys. A fleet check of the dogfood smoke gate, not a CI job or step (Lawrence 2026-10-23).
VIDEO_GOLDENS = Path(os.environ.get("SMOKE_GATE_VIDEO_GOLDENS", "/Users/lawrence/fun/wt/handoff/video-goldens.txt"))
GOLDEN_LEDGER = Path(os.environ.get("SMOKE_GATE_GOLDEN_LEDGER", "/Users/lawrence/fun/wt/handoff/video-golden-results"))


def golden_list():
    """(state, [fields...]) of the golden list: ("missing", []) when there is no list (no golden yet), ("listed",
    rows), or ("unreadable: <error>", []) when it or its folder cannot be read (that blocks the .pass)."""
    try:
        if not VIDEO_GOLDENS.exists():
            return "missing", []
        return "listed", [l.split() for l in VIDEO_GOLDENS.read_text().splitlines()
                          if l.strip() and not l.lstrip().startswith("#")]
    except OSError as error:
        return f"unreadable: {error}", []


def golden_blockers(job, listing=None):
    """[(list line, why)] of the golden video cases that block a .pass for JOB: no PASS on JOB in the golden ledger,
    or any FAIL. A missing list blocks nothing (no golden yet); an unreadable one blocks. LISTING: golden_list()'s
    answer, read once by the caller so the .pass names exactly the cases this check read.
    Rollout: the list stays absent until the per-build golden runs write the ledger (video_golden.py after each
    listed case's round on the build); a list without those runs blocks every .pass until they ran."""
    state, listed = listing if listing is not None else golden_list()
    if state.startswith("unreadable"):
        return [(str(VIDEO_GOLDENS), f"the golden list is {state}: no .pass")]
    rows = []
    try:
        for text in (GOLDEN_LEDGER / f"{job}.jsonl").read_text().splitlines():
            try:
                row = json.loads(text)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("build_job") == job:
                rows.append(row)
    except OSError:
        pass
    blockers = []
    for fields in listed:
        mine = [r for r in rows if r.get("case") == fields[0]]
        fails = [r for r in mine if r.get("status") == "fail"]
        # Only a judged run of a clean kit counts (as for the open P0 journeys).
        passes = [r for r in mine if r.get("status") == "pass" and r.get("kit_dirty") is False]
        line = " ".join(fields)
        if fails:
            blockers.append((line, f"FAILED on {job}: {len(fails)} fail(s), e.g. {fails[0].get('out')}: "
                                   f"{str(fails[0].get('reason') or '')[:160]}"))
        elif not passes:
            blockers.append((line, f"has no golden PASS on {job} ({len(mine)} result(s))"))
    return blockers


# TYPING UNDER LOAD (Lawrence P0 2026-11-02, lead 02:3xZ): "video + metric evidence that typing into terminals is
# never laggy". A .pass needs, on the exact build job, at least one judged L6 typing run (every load at once plus the
# 15 GB hog) whose key-to-photon is at most TYPING_P95 refreshes at p95 and TYPING_MAX at max (120 Hz), with no lost or
# merged key and the exact order; and no judged L6 run that breaks it. Rows come from typing/ledger.py (one per judged
# run, after the video judge and keys_check.py) in TYPING_LEDGER/<JOB>.jsonl. Only video-judged rows count (the rule
# is photon time); a row of a dirty kit, a SMOKE ENV round, or a display that was not 120 Hz never counts.
TYPING_LEDGER = Path(os.environ.get("SMOKE_GATE_TYPING_LEDGER", "/Users/lawrence/fun/wt/handoff/typing-load-results"))
TYPING_PROFILE = "L6"
TYPING_P95 = 1
TYPING_MAX = 2


def typing_row_ok(row):
    """(counts, breaks, why) of one ledger row. A row counts only for a run that happened as the rule says: a pass of
    the journey, both 60 s parts played in full, a 120 Hz video judge of both, the load alive until it was stopped with
    the focus never moved, the 15 GB hog held (>= 12 GB) for L6, a clean kit and no host dialog. A row whose start is
    the HID post (t_post, an upper bound of the latency) counts only when it passes (review at 8802cbd6e87)."""
    if row.get("kit_dirty") is not False or row.get("smoke_env") is not False or row.get("source") != "video":
        return False, False, "not judged (dirty kit, SMOKE ENV, or no video judge)"
    if row.get("status") != "pass" or row.get("parts") != 2 or not row.get("planned_keys") \
            or row.get("keys") != row.get("planned_keys"):
        return False, False, f"not judged (status {row.get('status')}, parts {row.get('parts')}, keys {row.get('keys')} of {row.get('planned_keys')})"
    if not row.get("load_ok") or (row.get("profile") == TYPING_PROFILE and float(row.get("hog_held_gb") or 0) < 12):
        return False, False, f"not judged (load_ok {row.get('load_ok')}, hog {row.get('hog_held_gb')} GB)"
    try:
        hz_ok = abs(float(row.get("refresh_ms") or 0) - 1000 / 120) <= 0.35
    except (TypeError, ValueError):
        hz_ok = False
    if not hz_ok:
        return False, False, f"display at {row.get('refresh_ms')} ms, not 120 Hz"
    p95, top = row.get("p95_refreshes"), row.get("max_refreshes")
    slow, broke = [], []
    if p95 is None or p95 > TYPING_P95:
        slow.append(f"p95 {p95} > {TYPING_P95} refresh")
    if top is None or top > TYPING_MAX:
        slow.append(f"max {top} > {TYPING_MAX} refreshes")
    # Breaches that do not depend on the start clock (review should-fix 2 at 71bef9a1695).
    if row.get("missing_frames"):
        broke.append(f"{row.get('missing_frames')} keys never shown")
    if row.get("lost") or row.get("merged") or row.get("order_ok") is not True:
        broke.append(f"keys: lost {row.get('lost')}, merged {row.get('merged')}, order_ok {row.get('order_ok')}")
    # cmux-ad 03:40Z: no timestamp from Python counts. A row whose key starts are not the keys' own NSEvent times is
    # provisional and never counts (pass or breach); a row whose achieved rate is under 95% of its target is not run.
    if row.get("start_clock") != "nsevent":
        return False, False, "provisional (key start from a Python post time, not the NSEvent time): " + "; ".join(slow + broke)
    if row.get("rate_ok") is not True:
        return False, False, f"not run (achieved {row.get('achieved_keys_per_s')} keys/s of {row.get('target_keys_per_s')})"
    return True, bool(slow or broke), "; ".join(slow + broke)


# The rule is live only while TYPING_RULE_ON exists (the lead creates it when the L6 load tool and the per-build L6
# round exist), so it never blocks every .pass before its evidence can be made (review must-fix 2 at 8802cbd6e87).
TYPING_RULE_ON = Path(os.environ.get("SMOKE_GATE_TYPING_RULE_ON", "/Users/lawrence/fun/wt/handoff/typing-load-rule.on"))


def typing_blockers(job):
    """[(what, why)] that block a .pass for JOB under the typing rule (empty = the rule holds or is not live)."""
    try:
        if not TYPING_RULE_ON.exists():
            return []
    except OSError as error:
        return [(str(TYPING_RULE_ON), f"the typing rule switch cannot be read ({error}): no .pass")]
    rows = []
    try:
        for text in (TYPING_LEDGER / f"{job}.jsonl").read_text().splitlines():
            try:
                row = json.loads(text)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("build_job") == job and row.get("profile") == TYPING_PROFILE:
                rows.append(row)
    except OSError:
        pass
    counted = [(r,) + typing_row_ok(r)[1:] for r in rows if typing_row_ok(r)[0]]
    broken = [(r, why) for r, broke, why in counted if broke]
    if broken:
        r, why = broken[0]
        return [(f"typing-load {TYPING_PROFILE}", f"{len(broken)} judged run(s) on {job} break the rule, e.g. {r.get('out')}: {why}")]
    if not counted:
        return [(f"typing-load {TYPING_PROFILE}", f"no judged {TYPING_PROFILE} typing run on {job} ({len(rows)} row(s); "
                                                 f"ledger {TYPING_LEDGER})")]
    return []


def build_state(job, deadline, poll=30.0):
    """The fleet state of build JOB once it is done, failed or cancelled, or its last state at DEADLINE."""
    while True:
        try:
            out = subprocess.run([os.environ.get("SMOKE_GATE_CMUX_CI") or shutil.which("cmux-ci")
                                  or str(Path.home() / ".local/bin/cmux-ci"), "status", job],
                                 capture_output=True, text=True, timeout=60).stdout
            state = json.loads(out).get("state") if out.strip() else None
        except FileNotFoundError:
            return "unknown (no cmux-ci)"  # never poll for hours without the client
        except (subprocess.TimeoutExpired, ValueError, OSError):
            state = None
        if state in ("done", "failed", "cancelled") or time.time() > deadline:
            return state or "unknown"
        time.sleep(poll)


def window_env(until):
    budget = max(0, int(until - time.time()) - GO_MARGIN)
    acquire = max(1, budget // 2)
    return {"CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": str(acquire),
            "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": str(max(0, budget - acquire)),
            "CAPTURE_HOST_DRAIN_SECONDS": str(min(acquire, 180))}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    ap.add_argument("--build", required=True, help="the fleet build job id of the app under test")
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--swap-gb", type=float, default=15.0)
    ap.add_argument("--hosts", default="cmux17 cmux18 cmux19 cmux20 cmux21 cmux22 cmux23 cmux24")
    ap.add_argument("--out")
    ap.add_argument("--whole-host", metavar="HOST",
                    help="lease this whole mini (exclusive) and launch the app active (--activate), so its window is "
                         "key and every line is typed at once; needs CuaDriver's console grant on HOST")
    ap.add_argument("--diagnostic", action="store_true",
                    help="no type-at-once where the slot has no key window (type after the creation hold); every "
                         "other step is still checked and reported. Verdict DIAGNOSTIC: never a .pass file")
    ap.add_argument("--real-key-rounds", type=int, default=GATE_REAL_KEY_ROUNDS,
                    help=f"how many rounds type with real HID keys through CuaDriver (default {GATE_REAL_KEY_ROUNDS}; "
                         "needs --whole-host); a gate run needs at least that many, and they must pass")
    ap.add_argument("--go-spec", metavar="NAME",
                    help="before each round wait for a new mini-scheduler GO of spec NAME (mini-queue/rounds/NAME.go), "
                         "run the round on the GO's mini (one of --hosts), take its lease within the GO's window, and "
                         "end the GO with NAME.done; all rounds stay one gate run")
    ap.add_argument("--go-wait-hours", type=float, default=4.0, help="how long the run waits for all its GOs")
    ap.add_argument("--handoff", default=str(HANDOFF))
    ap.add_argument("--runner", default=str(HERE / "run.py"), help=argparse.SUPPRESS)  # tests: a stand-in for run.py
    opts = ap.parse_args(argv)
    if opts.whole_host and opts.whole_host not in opts.hosts.split():
        ap.error(f"--whole-host {opts.whole_host} is not one of --hosts ({opts.hosts})")
    if opts.rounds < 1:
        ap.error("--rounds must be at least 1")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(opts.out) if opts.out else ROOT / "artifacts" / "smoke-gate" / f"{opts.build[:12]}-{stamp}"
    if out.exists() and any(out.iterdir()):
        ap.error(f"--out {out} is not empty: each gate run needs a new folder (old rounds must never count)")
    out.mkdir(parents=True, exist_ok=True)
    # Real HID keys go to the frontmost window: only on a whole-host lease (a shared slot's other apps could get them).
    real_rounds = real_key_rounds(opts.rounds, opts.real_key_rounds) if opts.whole_host else []
    gate_run = (opts.rounds >= GATE_ROUNDS and opts.swap_gb >= GATE_SWAP_GB and not opts.diagnostic
                and len(real_rounds) >= GATE_REAL_KEY_ROUNDS)
    gate_sha = git("rev-parse", "HEAD").stdout.strip()
    dirty = bool(git("status", "--porcelain", "--", *GATE_PATHS).stdout.strip())

    rounds = []
    go_used, go_deadline = set(), time.time() + opts.go_wait_hours * 3600
    if opts.go_spec:
        state = build_state(opts.build, go_deadline)
        if state != "done":
            ap.error(f"--go-spec needs a finished build: job {opts.build} is {state} (run.py would wait for it inside "
                     "the GO's window and take its lease after the GO ends)")
    slot, n, replaced = 1, 0, 0
    while slot <= opts.rounds:
        n += 1
        round_out = out / f"round-{n:02d}"
        go = None
        if opts.go_spec:
            go, why = await_go(opts.go_spec, opts.hosts.split(), go_used, go_deadline)
            if not go:
                round_out.mkdir(parents=True, exist_ok=True)
                rounds.append({"round": n, "steps": [], "status": "not run", "reason": why, "host": None, "seconds": 0,
                               "failing_step": None, "frames": [], "hog_logs": [], "pressure": {}, "hosts_offered": "",
                               "exclusive": None, "required_checks": {}, "required_missing": [], "known_gap": False,
                               "key_gaps": [], "leases": [], "go": None, "slot": slot,
                               "key_path": "real_hid" if slot in real_rounds else "debug.key"})
                print(f"round {n}: not run ({why})", flush=True)
                slot += 1
                continue
            go_used.add(go["go"])
            print(f"round {n}: GO on {go['host']} until {time.strftime('%H:%M:%SZ', time.gmtime(go['until']))}", flush=True)
        started = time.time() - 1
        # An exclusive lease waits for the mini's running fleet steps (the drain): give it the room the fleet
        # rules set (capture-host's default acquire timeout, 120 s, ends the drain first on a busy fleet).
        # The drain budget is bounded too (capture-host's default is an hour per acquire), so a round on a fleet
        # whose minis run hours-long steps ends as not run instead of waiting for them.
        env = {**os.environ, "CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": os.environ.get("CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS", "600"),
               "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": os.environ.get("CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS", "900"),
               # The perf minis are owner-only for pool perf-lead (hq fleet.json owner_only_hosts): the controller
               # refuses an exclusive lease there unless it names that owner pool (HTTP 409, trial 4, 2026-10-31).
               # capture-host passes it as `cmux-ci reserve --owner-pool` (hq #5153; refresh an older install).
               "CAPTURE_HOST_POOL": os.environ.get("CAPTURE_HOST_POOL", OWNER_POOL)}
        hosts = (go["host"] if go else None) or opts.whole_host or idle_first(opts.hosts)
        if go:
            env.update(window_env(go["until"]))
        env["CAPTURE_HOST_HOSTS"] = env["CAPTURE_HOST_SLOT_HOSTS"] = hosts
        done = subprocess.run([sys.executable, opts.runner, "--build", opts.build, "--journey", JOURNEY,
                               "--exclusive", "--hog-swap-gb", str(opts.swap_gb), "--hosts", hosts,
                               "--out", str(round_out), *(["--journey-option", "smoke_mode=diagnostic"] if opts.diagnostic else []),
                               *(["--journey-option", "key_path=real"] if slot in real_rounds else []),
                               *(["--whole-host"] if opts.whole_host else [])],
                              capture_output=True, text=True, env=env)
        (round_out / "run.log").parent.mkdir(parents=True, exist_ok=True)
        (round_out / "run.log").write_text(done.stdout + done.stderr)
        row = round_result(round_out, opts.build, done.returncode, started)
        hog = pressure(round_out, opts.swap_gb)
        checks = required_checks(round_out)
        missing = missing_checks(checks)
        if row.get("status") == "pass" and missing:
            row = dict(row, status="fail", reason="the resize checks were not all reached and passed: " + "; ".join(missing))
        typed = typed_steps(round_out)
        late = [st for st in typed if st.get("at_once") is not True] or ([] if typed else [{"none": True}])
        if row.get("status") == "pass" and not opts.diagnostic and late:
            row = dict(row, status="not run", reason=f"{len(late)} smoke_type_now steps were not typed at once "
                                                      "(a diagnostic round is never a gate pass)")
        gaps = key_gaps(round_out)
        if row.get("status") == "pass" and gaps:
            row = dict(row, status="not run", reason=gaps[0] + f" ({len(gaps)} key-window checks not judged)")
        paths, not_real = key_paths(round_out)
        if slot in real_rounds and row.get("status") == "pass" and (not_real or not paths.get("real_hid")):
            row = dict(row, status="not run", reason="a real-key round whose basic keys did not all take the real HID "
                                                     f"path: {not_real[:4] or 'no real_hid step'}")
        exclusive = exclusive_line(round_out)
        if row.get("status") == "pass" and not exclusive:
            row = dict(row, status="not run", reason="capture-host did not say the lease's mini was exclusive (acquire.log)")
        # The pressure rule comes LAST: every check above can turn the round into a FAIL or a not run first, so
        # only a round whose sole fault is the missing pressure gets no_pressure (and may be run again below).
        no_pressure = row.get("status") == "pass" and not hog["ok"]
        if no_pressure:
            row = dict(row, status="not run", reason=f"no memory pressure shown by the hog log: {json.dumps(hog)}")
        # run.py logs "leased <lease>": a slot lease (slot-<host>-<token>) or a whole-host lease (the host alias).
        leases = sorted(set(re.findall(r"\bleased (\S+)", done.stdout + done.stderr)))
        record = {"round": n, "steps": step_results(round_out), "status": row.get("status"), "reason": row.get("reason"), "host": row.get("host"),
                  "seconds": round(time.time() - started), "failing_step": failing_step(round_out),
                  "frames": frames(round_out), "hog_logs": sorted(p.name for p in round_out.glob("hog-*.jsonl")), "pressure": hog, "hosts_offered": hosts, "exclusive": exclusive,
                  "required_checks": checks, "required_missing": missing,
                  "known_gap": "known gap" in str(row.get("reason") or ""),
                  "key_gaps": gaps, "leases": leases,
                  "go": {"host": go["host"], "go": go["go"], "until": go["until"]} if go else None,
                  "key_path": "real_hid" if slot in real_rounds else "debug.key", "key_paths": paths, "slot": slot}
        # Only a round whose sole fault is the hog's missing pressure is run again (a fail or another not-run
        # reason stays). Diagnostic runs judge nothing, so they are never lengthened.
        again = no_pressure and not opts.diagnostic and replaced < opts.rounds
        if again:
            replaced += 1
            record["replaced"] = True
            record["reason"] += f" (round run again for slot {slot}: replacement {replaced} of at most {opts.rounds})"
        else:
            slot += 1
        rounds.append(record)
        if go:
            took = bool(leases) or record["status"] in ("pass", "fail")
            go_done(opts.go_spec, go, f"{opts.build[:12]} round {n}", None if took else "not run")
        print(f"round {n}: {record['status']}" + (f" ({record['reason'][:160]})" if record.get("reason") else "")
              + (f" step {record['failing_step']['do']}: {record['failing_step']['error'][:160]}" if record["failing_step"] else ""),
              flush=True)

    passed = sum(1 for r in rounds if r["status"] == "pass")
    failed = [r for r in rounds if r["status"] == "fail"]
    not_run = [r for r in rounds if r["status"] not in ("pass", "fail") and not r.get("replaced")]
    replaced_rounds = [r["round"] for r in rounds if r.get("replaced")]
    verdict = ("PASS" if gate_run else "TRIAL PASS") if passed == opts.rounds else ("FAIL" if failed else "NOT JUDGED")
    if opts.diagnostic:
        # Diagnostic rounds judge nothing: their findings are in the per-step report.
        verdict = "DIAGNOSTIC (NOT JUDGED)"
    summary = {"build": opts.build, "journey": JOURNEY, "rounds": opts.rounds, "passed": passed,
               "failed": len(failed), "not_run": len(not_run), "verdict": verdict, "swap_gb": opts.swap_gb,
               "gate_commit": gate_sha, "gate_dirty": dirty, "gate_run": gate_run, "diagnostic": opts.diagnostic,
               "whole_host": opts.whole_host, "go_spec": opts.go_spec, "real_key_rounds": real_rounds,
               "real_key_passed": sum(1 for r in rounds if r.get("key_path") == "real_hid" and r["status"] == "pass"),
               "expects": expect_table(rounds), "replaced_rounds": replaced_rounds, "known_gap_rounds": [r["round"] for r in rounds if r["known_gap"]],
               "rounds_detail": rounds, "out": str(out)}
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    ran = ("journeys completed" if opts.diagnostic else "rounds passed")
    lines = [f"dogfood smoke gate for build {opts.build}: {verdict} ({passed} of {opts.rounds} {ran}; "
             f"{len(failed)} failed, {len(not_run)} not run; memory hog +{opts.swap_gb} GB swap; gate {gate_sha[:11]}"
             + (" with uncommitted changes" if dirty else "") + ")"
             + ("; diagnostic rounds judge nothing, so no .pass file" if opts.diagnostic else
                "" if gate_run else f"; a trial: the gate needs {GATE_ROUNDS} rounds at +{GATE_SWAP_GB:g} GB with at least "
                f"{GATE_REAL_KEY_ROUNDS} real-key rounds, so no .pass file")
             + f"; real HID keys in rounds {real_rounds}"
             + (f"; rounds {replaced_rounds} showed no memory pressure and were run again" if replaced_rounds else "")]
    if summary["known_gap_rounds"]:
        lines.append(f"KNOWN GAP in rounds {summary['known_gap_rounds']}: the capture lease could not make the window key, "
                     "so keys typed into a new terminal while it is made were not checked; not a pass")
    if opts.diagnostic:
        lines.append("DIAGNOSTIC: no type-at-once where the slot has no key window; no .pass file. Each check:")
        for title, row in summary["expects"].items():
            lines.append(f"  {row['passed']}/{row['reached']} passed, {row.get('not_judged', 0)} not judged "
                         f"(of {opts.rounds} rounds): {title}"
                         + (f" -- {row['errors'][0]}" if row["errors"] else ""))
    for r in rounds:
        detail = r["failing_step"] and f"{r['failing_step']['do']}: {r['failing_step']['error'][:200]}"
        hog = r["pressure"]
        lines.append(f"  round {r['round']:2d} (slot {r.get('slot')}) on {r['host']} ({r.get('key_path')}): "
                     + ("replaced" if r.get("replaced") else r["status"]) + (f" -- {detail}" if detail else "")
                     + f" [hog held {hog.get('held_gb_max')} GB, swap +{hog.get('swap_growth_gb')} GB, level min {hog.get('level_min')}]"
                     + (f" -- {(r['reason'] or '')[:200]}" if r["status"] != "pass" and not detail else ""))
    text = "\n".join(lines)
    (out / "summary.txt").write_text(text + "\n")
    print(text)
    if verdict in ("PASS", "TRIAL PASS"):
        if dirty or git("status", "--porcelain", "--", *GATE_PATHS).stdout.strip() \
                or git("rev-parse", "HEAD").stdout.strip() != gate_sha:
            print("smoke-gate: PASS, but the gate has (or got) uncommitted changes: no .pass file written", file=sys.stderr)
            return 75
        if not gate_run:
            print(f"smoke-gate: a trial PASS (--rounds {opts.rounds}, --swap-gb {opts.swap_gb:g}): no .pass file", file=sys.stderr)
            return 75
        waived = []
        blockers = open_p0_blockers(opts.build, waived)
        listing = golden_list()
        goldens = golden_blockers(opts.build, listing)
        if blockers:
            text = "\n".join([f"smoke-gate: {opts.rounds} of {opts.rounds} rounds passed, but an open P0 journey blocks the "
                              f".pass ({OPEN_P0}; --build must be the full job id):"]
                             + [f"  {line}: {why}" for line, why in blockers]
                             + [f"  waived FAIL {w['id']} {w['out']}: {w['reason']}" for w in waived])
            (out / "open-p0.txt").write_text(text + "\n")
            print(text, file=sys.stderr)
        if goldens:
            text = "\n".join([f"smoke-gate: {opts.rounds} of {opts.rounds} rounds passed, but a golden video case blocks "
                              f"the .pass ({VIDEO_GOLDENS}; ledger {GOLDEN_LEDGER}):"]
                             + [f"  {line}: {why}" for line, why in goldens])
            (out / "video-goldens.txt").write_text(text + "\n")
            print(text, file=sys.stderr)
        typing = typing_blockers(opts.build)
        if typing:
            text = "\n".join([f"smoke-gate: {opts.rounds} of {opts.rounds} rounds passed, but the typing rule blocks the "
                              f".pass (p95 <= {TYPING_P95}, max <= {TYPING_MAX} refreshes in {TYPING_PROFILE}, no lost or merged key):"]
                             + [f"  {line}: {why}" for line, why in typing])
            (out / "typing-load.txt").write_text(text + "\n")
            print(text, file=sys.stderr)
        if blockers or goldens or typing:
            return 75
        handoff = Path(opts.handoff)
        handoff.mkdir(parents=True, exist_ok=True)
        summary["video_goldens"] = {"list": listing[0], "checked": [f[0] for f in listing[1]]}
        summary["typing_rule"] = {"live": TYPING_RULE_ON.exists(), "profile": TYPING_PROFILE, "p95": TYPING_P95,
                                  "max": TYPING_MAX, "ledger": str(TYPING_LEDGER)}
        summary["open_p0_waived"] = waived
        summary["open_p0_checked"] = [l.split()[0] for l in OPEN_P0.read_text().splitlines()
                                      if l.strip() and not l.lstrip().startswith("#")]
        (handoff / f"{opts.build}.pass").write_text(json.dumps(summary, indent=1) + "\n")
        print(f"wrote {handoff / (opts.build + '.pass')}")
        return 0
    return 1 if verdict == "FAIL" or (opts.diagnostic and failed) else 75


if __name__ == "__main__":
    sys.exit(main())
