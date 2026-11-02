#!/usr/bin/env python3
"""Run cmux NEXT user journeys against one exact fleet build, on a fleet capture Mac.

    scripts/journeys/run.py --build JOB [--priority P0 | --journey ID ... | --all] [--out DIR]
    scripts/journeys/run.py --commit SHA [...]      # builds SHA on the fleet first (or reuses its receipt)
    scripts/journeys/run.py --list | --check

The route is the one cmux-ci capture and restore-journey-slot.sh use (no new harness, no CI job):
capture-host leases one slot on a GUI capture mini (released in every case; a lease lasts at most
10 minutes), the slot downloads the build's artifact (`cmux-ci artifact JOB`), capture-host launches
it in the slot (own HOME, bundle id, socket, settings), and driver.py plays the journeys there over
the control socket, the bundled CLI on the app's daemon, the process table and the app's own
window snapshots. Journeys that do not fit one lease run in further leases.

Writes OUT (default artifacts/journeys/<job12>-<run id>/; the run id is <UTC time>-<8 hex>): run.json (the
run id and start time), results.jsonl (one line per journey: id, priority, status pass|fail|not run, evidence,
clip, build, run id), <id>/result.json, <id>/check-NN.png (each frame a check read), <id>/clip.mp4 (ffmpeg) or
<id>/clip.png (an animated PNG; any browser plays it). A journey that could not run is "not run" with the reason,
never a pass.

Each run writes a new folder (STATUS 1362: a round whose relaunch failed reported an older round's result.json from
its reused folder). An --out folder that holds an earlier run's results makes every journey "not run" (the earlier
results.jsonl, run.json and <id>/ folders are kept beside, named with this run's id). The driver writes this run's id and start time into
each result.json; run.py takes no result.json without them ("not run: stale or foreign result"), and a lease whose
launch or set-up failed before the driver started is "not run" with that reason, whatever the folder holds.

Run fleet rounds from a pinned, reviewed checkout, never from the worktree you edit in (coordinator 2026-10-31):
`git worktree add --detach DIR REVIEWED_SHA`, start run.py from DIR, and move DIR to a new sha only after that sha's
review. run.py loads the journey specs at its start and packs driver.py, ext_*.py, smoke_hog.py, build_names.py and
the text reader's source from disk at each lease, so it reads `git status` of the harness paths at the start and at each lease: a result from a checkout with uncommitted
harness files, or one whose commit moved during the run, is "not run" ("harness: unpinned ..."); its own status stays
in result.json's "harness" record (commit, uncommitted files, detached, pinned) for debugging.
Exit 0 when every selected journey passed, 1 when one failed, 75 when none failed but one did not run.

Capture hosts: capture-host reads the fleet registry (~/.ssh/config.d/fleet-registry.json), or
CAPTURE_HOST_SLOT_HOSTS (--hosts sets it). JOURNEYS_EXCLUDE_HOSTS (default cmux16) are never leased.
"""
from __future__ import annotations

import argparse
import calendar
import hashlib
import io
import json
import os
import re
import secrets
import shutil
import signal
import struct
import subprocess
import sys
import tarfile
import time
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts" / "cmux-next"))
import driver  # noqa: E402  (the step and condition names, for --check)

JOURNEYS = HERE / "journeys"
BUILD_NAMES = ROOT / "scripts" / "cmux-next" / "build_names.py"
OCR_SOURCE = ROOT / "scripts" / "ci" / "pr_media_ocr.swift"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
PRIORITIES = ("P0", "P1", "P2", "P3")
# capture-host's hard maximum is 600 s from acquire; keep room to fetch and release.
LEASE_SECONDS = 540
# Download, launch, the OCR compile (first time per mini) and its warm-up (about 60 s), before the first journey.
SETUP_RESERVE = 240
JOURNEY_SECONDS = LEASE_SECONDS - SETUP_RESERVE - 40
RESULT_FILE = re.compile(r"(?:\./)?((?:[a-z0-9][a-z0-9-]*/)?(?:result\.json|check-\d{2,3}\.png|clip/frame-\d{5}\.png"
                         r"|restore-trace\.json|fuzz\.json|diag-[a-z]+\.(?:json|png|txt)|diag-app-sample\.txt"
                         r"|video/[a-z0-9][a-z0-9-]*\.(?:mov|mov\.frames\.json|events\.json|json))|host\.json|summary\.json)")
RESULT_MAX_BYTES = 64 << 20
# A screen movie a journey recorded (`<id>/video/NAME.mov`, the debug.motion record_* recorder): kept up to this size.
RESULT_MOVIE_MAX_BYTES = 640 << 20
RESULT_TAR_MAX_BYTES = 768 << 20
STEP_NAMES = {name[len("step_"):] for name in dir(driver.Journey) if name.startswith("step_")}
# The files of a run in its OUT folder: a folder that holds one of them was used by an earlier run.
EARLIER_RUN_FILES = ("run.json", "results.jsonl", "host.json", "summary.json", "acquire.log")
# A journey that started this long before the run is logged (the mini's clock is late); the run id decides.
CLOCK_SKEW_SECONDS = 300
STAMP = "%Y-%m-%dT%H:%M:%SZ"
# What kit_tar packs to the mini and what judges a round: a result counts only when these are committed and unchanged.
HARNESS_PATHS = ("scripts/journeys", "scripts/cmux-next/build_names.py", "scripts/ci/pr_media_ocr.swift")


def log(message):
    print(f"journeys: {message}", file=sys.stderr, flush=True)


def q(text):
    return "'" + str(text).replace("'", "'\"'\"'") + "'"


def run(argv, *, input=None, timeout=None, check=True):
    done = subprocess.run(argv, input=input, capture_output=True, timeout=timeout)
    if check and done.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, argv[:3]))} ... exited {done.returncode}: "
                           f"{(done.stderr or done.stdout).decode(errors='replace').strip()[-500:]}")
    return done


def remote(host, script, *, input=None, timeout=600, check=True):
    """A login shell on the mini (cmux-ci is on its login PATH only), as pr-capture does."""
    return run(SSH + [host, "zsh -lc " + q(script)], input=input, timeout=timeout, check=check)


# ---- journeys ------------------------------------------------------------------------------

def load_journeys(directory=JOURNEYS):
    specs, problems = [], []
    for path in sorted(Path(directory).rglob("*.json")):
        try:
            spec = json.loads(path.read_text())
        except ValueError as error:
            problems.append(f"{path}: {error}")
            continue
        spec["_path"] = str(path.relative_to(ROOT))
        problems += [f"{path.relative_to(ROOT)}: {p}" for p in validate(spec)]
        specs.append(spec)
    ids = [s.get("id") for s in specs]
    problems += [f"journey id {i!r} is used twice" for i in sorted({i for i in ids if ids.count(i) > 1})]
    specs.sort(key=lambda s: (PRIORITIES.index(s["priority"]) if s.get("priority") in PRIORITIES else 9, s.get("id", "")))
    return specs, problems


def validate(spec):
    problems = []
    for key in ("id", "priority", "title", "why", "budget_seconds", "steps"):
        if key not in spec:
            problems.append(f"missing {key!r}")
    if spec.get("priority") not in PRIORITIES:
        problems.append(f"priority {spec.get('priority')!r} is not one of {', '.join(PRIORITIES)}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", str(spec.get("id", ""))):
        problems.append("id must be lowercase letters, digits and dashes")
    if not isinstance(spec.get("budget_seconds"), (int, float)) or not 0 < spec["budget_seconds"] <= JOURNEY_SECONDS:
        problems.append(f"budget_seconds must be in (0, {JOURNEY_SECONDS}] (one lease)")
    kinds = set()
    for index, step in enumerate(spec.get("steps") or [], 1):
        if step.get("do") not in STEP_NAMES:
            problems.append(f"step {index}: unknown do {step.get('do')!r} (one of {', '.join(sorted(STEP_NAMES))})")
        for cond in step.get("all", []) if step.get("do") == "expect" else []:
            if not isinstance(cond, dict) or len(cond) != 1 or next(iter(cond)) not in driver.KIND:
                problems.append(f"step {index}: a condition is one of {', '.join(sorted(driver.KIND))}: {cond!r}")
            else:
                kinds.add(driver.KIND[next(iter(cond))])
    missing = [k for k in driver.REQUIRED_KINDS if k not in kinds]
    if missing:
        problems.append("checks no " + ", ".join(missing) + " evidence (a journey needs app state, daemon screen and a frame)")
    return problems


def select(specs, opts):
    if opts.journey:
        wanted = set(opts.journey)
        unknown = wanted - {s["id"] for s in specs}
        if unknown:
            raise SystemExit(f"journeys: unknown journey {', '.join(sorted(unknown))} (--list)")
        return [s for s in specs if s["id"] in wanted]
    if opts.all:
        return specs
    return [s for s in specs if s["priority"] == opts.priority]


def batches(specs):
    """Journeys in leases of at most JOURNEY_SECONDS each. A `first_in_app` journey (first launch) needs the
    app capture-host just launched from empty state, so each one starts a lease of its own and goes first."""
    out, current, used = [], [], 0
    firsts = [s for s in specs if s.get("first_in_app")]
    for first in firsts:
        out.append([first])
    rest = [s for s in specs if not s.get("first_in_app")]
    # The rest fill the first-launch leases first, then new ones.
    for batch in out:
        used = batch[0]["budget_seconds"]
        while rest and used + rest[0]["budget_seconds"] <= JOURNEY_SECONDS:
            used += rest[0]["budget_seconds"]
            batch.append(rest.pop(0))
    used = 0
    for spec in rest:
        if current and used + spec["budget_seconds"] > JOURNEY_SECONDS:
            out.append(current)
            current, used = [], 0
        current.append(spec)
        used += spec["budget_seconds"]
    return out + ([current] if current else [])


# ---- the build ---------------------------------------------------------------------------

def cmux_ci():
    return shutil.which("cmux-ci") or str(Path.home() / ".local/bin/cmux-ci")


def job_status(job):
    done = run([cmux_ci(), "status", job], timeout=120)
    return json.loads(done.stdout.decode())


def wait_build(job, wait_seconds):
    """Waits for JOB (a wait timeout leaves it running: wait again, never resubmit); its record."""
    end = time.monotonic() + wait_seconds
    while True:
        status = job_status(job)
        if status.get("state") in ("done", "failed", "cancelled"):
            return status
        left = end - time.monotonic()
        if left <= 0:
            return status
        log(f"build {job} is {status.get('state')}; waiting (up to {left / 60:.0f} more min)")
        subprocess.run([cmux_ci(), "wait", job, "--timeout", str(int(min(left, 1800)) or 1)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_for_commit(sha, out_root):
    """The fleet build of SHA: an earlier receipt's job, else one new submission (never a second one)."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit("journeys: --commit takes an exact 40-character SHA (pushed)")
    receipts = out_root / "builds"
    receipts.mkdir(parents=True, exist_ok=True)
    receipt = receipts / f"{sha}.json"
    if receipt.exists():
        return json.loads(receipt.read_text())["id"]
    submit = receipts / f"{sha}-submit.json"
    if submit.exists():
        job = json.loads(submit.read_text()).get("id")
        if job:
            receipt.write_text(json.dumps({"id": job, "sha": sha}) + "\n")
            return job
        raise SystemExit(f"journeys: {submit} has no job id: reconcile it (cmux-ci status), never resubmit blindly")
    log(f"building {sha[:12]} on the fleet")
    run([cmux_ci(), "build", "cmux", "--ref", sha, "--tag", f"journeys-{sha[:8]}-v1", "--backend-mode", "local",
         "--workspace", "user-journeys", "--reason", "user journeys (scripts/journeys/run.py)",
         "--receipt", str(submit)], timeout=600, check=False)
    job = json.loads(submit.read_text()).get("id") if submit.exists() else None
    if not job:
        raise SystemExit(f"journeys: the build submission left no receipt at {submit}; check `cmux-ci status` before retrying")
    receipt.write_text(json.dumps({"id": job, "sha": sha}) + "\n")
    return job


# ---- the run's identity --------------------------------------------------------------------

def new_run(started=None):
    """{"run_id", "run_started_at"}: a run's own id (UTC time and 8 random hex digits) and start time. Every
    result.json the driver writes carries both; run.py takes no other result.json."""
    started = time.time() if started is None else started
    return {"run_id": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(started)) + "-" + secrets.token_hex(4),
            "run_started_at": time.strftime(STAMP, time.gmtime(started))}


def earlier_run(out):
    """What in OUT an earlier run wrote (a reused folder), or None when OUT is new or has none of a run's files."""
    if not out.is_dir():
        return None
    found = [name for name in EARLIER_RUN_FILES if (out / name).exists()]
    found += sorted(str(p.relative_to(out)) for p in out.glob("*/result.json"))
    return ", ".join(found[:4]) + (f" (and {len(found) - 4} more)" if len(found) > 4 else "") if found else None


def stale_reason(result, ident):
    """Why `result` (a parsed result.json) is not the run `ident`'s, or None when it is."""
    if not isinstance(result, dict):
        return "stale or foreign result: result.json is not an object"
    if result.get("run_id") != ident["run_id"] or result.get("run_started_at") != ident["run_started_at"]:
        return (f"stale or foreign result: run id {result.get('run_id')!r} started {result.get('run_started_at')!r}, "
                f"this run is {ident['run_id']!r} started {ident['run_started_at']!r}")
    try:  # the random run id proves the run; a journey start before the run only means the mini's clock is late
        began = calendar.timegm(time.strptime(str(result.get("started_at")), STAMP))
        if began < calendar.timegm(time.strptime(ident["run_started_at"], STAMP)) - CLOCK_SKEW_SECONDS:
            log(f"{result.get('id')}: the journey started {result.get('started_at')}, before this run "
                f"({ident['run_started_at']}): is the mini's clock late?")
    except ValueError:
        pass
    return None


def harness_state():
    """{"commit", "dirty": [git status lines of HARNESS_PATHS, untracked files too], "detached"} of this checkout, now."""
    def git(*args):
        return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=60)
    try:
        commit = git("rev-parse", "HEAD").stdout.strip() or None
        status = git("status", "--porcelain", "--untracked-files=all", "--", *HARNESS_PATHS)
        dirty = status.stdout.splitlines() if status.returncode == 0 else [f"(git status exited {status.returncode})"]
        detached = git("symbolic-ref", "-q", "HEAD").returncode != 0
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"commit": None, "dirty": [f"(git: {error})"], "detached": None}
    return {"commit": commit, "dirty": dirty, "detached": detached}


def stamp_harness(results, out, start, lease):
    """Records the harness (`lease`: its state when this lease packed the kit) in each result and its result.json; a
    pass or fail from an unpinned harness (uncommitted harness files at the start or at the lease, or the commit moved
    since the start) becomes "not run", its own status kept in the record. No record when the kit was never packed."""
    if lease is None:
        return results
    start = start or lease
    why = None
    if not lease["commit"] or not start["commit"]:
        why = "no harness commit: " + "; ".join(start["dirty"] + lease["dirty"])[:200]
    elif start["dirty"] or lease["dirty"]:
        files = sorted(set(start["dirty"]) | set(lease["dirty"]))
        why = f"{len(files)} uncommitted harness files: " + ", ".join(f.strip() for f in files[:5])
    elif lease["commit"] != start["commit"]:
        why = f"the checkout moved from {start['commit'][:12]} to {lease['commit'][:12]} during the run"
    record = {"commit": lease["commit"], "dirty": sorted(set(start["dirty"]) | set(lease["dirty"])),
              "detached": lease["detached"], "pinned": why is None}
    for i, result in results.items():
        result["harness"] = dict(record, **({"status": result.get("status")} if why else {}))
        if why and result.get("status") in ("pass", "fail"):
            result["status"], result["reason"] = "not run", f"harness: unpinned ({why}); was {result['status']}: {result.get('reason') or ''}"[:600]
        path = out / i / "result.json"
        if result.get("run_id"):  # only this run's own file (collect checked its run id), never a stale one
            try:
                on_disk = json.loads(path.read_text())
                if on_disk.get("run_id") == result["run_id"]:
                    # A reader of result.json alone sees the same verdict as results.jsonl.
                    on_disk.update(harness=result["harness"], status=result["status"], reason=result.get("reason", ""))
                    path.write_text(json.dumps(on_disk, indent=1, default=str) + "\n")
            except (OSError, ValueError):
                pass
        if why:  # a step group's own report (fuzz.json) of an unpinned round is not evidence either, result.json or not
            for report in (out / i).glob("fuzz.json"):
                try:
                    report.rename(report.with_name("fuzz.json.unpinned"))
                except OSError as error:
                    log(f"{i}: {report.name} of an unpinned round not renamed: {error}")
    return results


# ---- one lease ---------------------------------------------------------------------------

def capture_host():
    found = os.environ.get("CAPTURE_HOST") or shutil.which("capture-host")
    installed = Path.home() / ".local/share/cmux/hq-tools/current/build-fleet/capture-host"
    return found or str(installed)


def kit_tar(specs):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        tar.add(HERE / "driver.py", arcname="driver.py")
        for ext in sorted(HERE.glob("ext_*.py")):  # step and condition groups the driver loads
            tar.add(ext, arcname=ext.name)
        tar.add(BUILD_NAMES, arcname="build_names.py")
        tar.add(HERE / "smoke_hog.py", arcname="smoke_hog.py")  # run only with --hog-swap-gb
        tar.add(OCR_SOURCE, arcname="ocr.swift")
        data = json.dumps([{k: v for k, v in s.items() if not k.startswith("_")} for s in specs]).encode()
        info = tarfile.TarInfo("journeys.json")
        info.size, info.mode = len(data), 0o644
        tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def launch_facts(text):
    line = next((l for l in reversed(text.splitlines()) if "socket=" in l), "")
    head, _, app = line.partition(" app=")
    facts = dict(kv.split("=", 1) for kv in head.split() if "=" in kv)
    if app.strip():
        facts["app"] = app.strip()
    return facts


ACQUIRE_SLACK_SECONDS = 60


def set_phase(ch, lease, name):
    """`capture-host phase LEASE download|journey|idle`: what the lease does now, which the controller reads in the lease
    heartbeat (the scheduler's rule that releases an idle lease). A failure is logged and never fails the round."""
    try:
        done = subprocess.run([ch, "phase", lease, name], capture_output=True, timeout=30)
        if done.returncode != 0:
            log(f"phase {name} of {lease}: exit {done.returncode}: {done.stderr.decode(errors='replace').strip()[-200:]}")
    except (OSError, subprocess.TimeoutExpired) as error:
        log(f"phase {name} of {lease}: {error}")


def acquire_lease(ch, exclusive, log_path=None, whole_host=False):
    """`capture-host acquire --slot [--exclusive]` (or, whole_host, `acquire [--exclusive]`: the whole mini); the
    lease words it prints. An exclusive acquire waits for the
    mini's running fleet steps (the drain), and capture-host moves its own acquire deadline on by the time
    drained, so its bound here is its acquire timeout plus its drain budget. On that bound the acquire gets TERM
    first: its trap ends the controller reservation the drain made (a KILL would leave it until it expires)."""
    env_seconds = lambda name, default: int(os.environ.get(name, default))
    bound = (env_seconds("CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS", 120) + env_seconds("CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS", 3600)
             + ACQUIRE_SLACK_SECONDS) if exclusive else 330
    # A blocked signal mask is inherited across exec: the acquire must take TERM (its trap unreserves).
    proc = subprocess.Popen([ch, "acquire", *([] if whole_host else ["--slot"]), *(["--exclusive"] if exclusive else [])],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_UNBLOCK, STOP_SIGNALS))
    deadline = time.monotonic() + bound
    while True:
        try:
            out, err = proc.communicate(timeout=1.0)
            break
        except subprocess.TimeoutExpired:
            pass
        # The caller blocks STOP_SIGNALS around this call: a stop waits here as a pending signal. Take it (sigwait clears
        # it) and end the acquire, whose trap unreserves; no lease was handed out.
        if signal.sigpending() & STOP_SIGNALS:
            got = signal.sigwait(STOP_SIGNALS)
            proc.terminate()
            try:
                late, _ = proc.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    late, _ = proc.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    late = b""
            # The acquire may have handed out a lease just before the TERM reached it (cmux19, 2026-10-31T09:36Z: the
            # lease stayed until released by hand): release whatever it printed before stopping.
            for word in (late or b"").decode(errors="replace").split():
                if re.fullmatch(r"(slot-)?[A-Za-z0-9._-]+", word):
                    subprocess.run([ch, "release", word], capture_output=True, timeout=120)
            raise Terminated(f"signal {got} while acquiring")
        if time.monotonic() > deadline:
            proc.terminate()  # our own child: capture-host's acquire_interrupted unreserves and exits
            try:
                out, err = proc.communicate(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:  # a child of the acquire may still hold the pipes: never wait on them without a bound
                    out, err = proc.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    out, err = b"", b"(no output: the acquire's children still hold its pipes)"
            raise RuntimeError(f"capture-host acquire gave no lease within {bound}s: "
                               f"{err.decode(errors='replace').strip()[-400:]}")
    if log_path:  # capture-host's own lines (each host tried and why it was skipped), for a round with no lease
        Path(log_path).write_bytes(err or b"")
    if proc.returncode != 0:
        raise RuntimeError(f"capture-host acquire exited {proc.returncode}: "
                           f"{(err or out).decode(errors='replace').strip()[-500:]}")
    return out.decode().split()


HOG_WARMUP_SECONDS = 45  # at least this long from the hog's start (before the download) to the first journey
# Builds kept in each mini's journeys build cache (about 1 GB each).
BUILD_CACHE_KEEP = 3
# The signals that stop a round (fuzz.py's TERM, the gate's, ^C). They are blocked from the acquire until the lease is
# inside run_lease's try, and again for the whole release, so neither a second signal nor one at the wrong moment can
# leave a lease held until it expires (review of 22115f33db6).
STOP_SIGNALS = {signal.SIGINT, signal.SIGTERM}


def run_lease(specs, build, out, frame_interval, exclusive=False, hog_swap_gb=0.0, whole_host=False, run_ident=None):
    """Plays `specs` in one slot (or, whole_host, on the whole mini with the app active); {id: result} (driver results, or not run with the reason). `exclusive`: the
    lease owns the whole mini (`capture-host acquire --slot --exclusive`: no fleet step runs there meanwhile;
    the fleet rule for any result that is evidence, such as the dogfood smoke gate). `run_ident` ({"run_id",
    "run_started_at"}, new_run()): the driver stamps it into each result.json and only results with it count."""
    ch = capture_host()
    ids = [s["id"] for s in specs]
    ident = run_ident or new_run()
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)  # see STOP_SIGNALS: no stop between lease and try
    try:
        out.mkdir(parents=True, exist_ok=True)
        set_aside_old_results(out, ids)
        acquired = acquire_lease(ch, exclusive, out / "acquire.log", whole_host=whole_host)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        return {i: {"status": "not run", "reason": f"no capture slot: {str(error)[-300:]}"} for i in ids}
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        raise
    if not acquired:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
        return {i: {"status": "not run", "reason": "capture-host acquire printed no lease"} for i in ids}
    lease, deadline = acquired[-1], time.monotonic() + LEASE_SECONDS
    left = lambda cap: max(10.0, min(cap, deadline - time.monotonic()))
    log(f"leased {lease}")
    facts, host, hog_started, work, drove, harness = {}, None, None, None, None, None
    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)  # a stop from here on raises inside the try: finally releases
        set_phase(ch, lease, "download")
        info = dict(kv.split("=", 1) for kv in run([ch, "slot-info", lease]).stdout.decode().split() if "=" in kv)
        host, root = info["host"], info["root"]
        work = f"{root}/journeys"
        # What kit_tar packs, from disk: the checkout's state before and after packing must agree.
        before, kit, harness = harness_state(), kit_tar(specs), harness_state()
        if before != harness:
            harness = dict(harness, dirty=harness["dirty"] + ["(the harness changed while the kit was packed)"])
        # A slot root the mini reuses (a whole-host lease) may still hold an earlier run's out/: never fetch it.
        remote(host, f"rm -rf {q(work + '/out')} && mkdir -p {q(work + '/kit')} && tar x -C {q(work + '/kit')}",
               input=kit, timeout=left(120))
        if hog_swap_gb > 0:
            # Memory pressure (the Austin's-day hog), from before the download and launch to the end of the
            # journeys: it holds incompressible memory until swap used is hog_swap_gb above the start, gives
            # memory back near the edge, and ends by itself at its deadline. Started by this lease, stopped by its
            # own pid in `finally` (never a pid this run did not start). Marked started before the call, so a
            # call that times out after the hog began still stops it.
            hog_end = int(left(LEASE_SECONDS) - 30)
            hog_started = time.monotonic()
            remote(host, f"mkdir -p {q(work + '/out')} && cd {q(work)} && "
                         f"nohup /usr/bin/python3 -I kit/smoke_hog.py --swap-gb {float(hog_swap_gb)} "
                         f"--deadline $(( $(date +%s) + {hog_end} )) --log {q(work + '/hog.jsonl')} </dev/null >/dev/null 2>&1 & "
                         f"echo $! > {q(work + '/hog.pid')}", timeout=left(30))
            log(f"memory hog on {host}: swap +{hog_swap_gb} GB, {HOG_WARMUP_SECONDS}s at least before the journeys")
        # One compiled text reader per mini and source version, outside the slot (release removes the slot).
        digest = hashlib.sha256(OCR_SOURCE.read_bytes()).hexdigest()[:16]
        ocr = f"$HOME/.cache/cmux-journeys/ocr-{digest}"
        # The build, once per mini and job, outside the slot (cmux-ad 09:05Z: a lease is held only while journey steps
        # run): ~/.cache/cmux-journeys/builds/<job>/, filled atomically by the first lease of that job on the mini and
        # reused by every later round (the newest BUILD_CACHE_KEEP jobs are kept). capture-host launch clones it into
        # the slot, so the slot never changes it.
        if not re.fullmatch(r"[A-Za-z0-9_-]+", str(build["id"])):
            raise RuntimeError(f"build id {build['id']!r} is not a plain job id")
        cache = f"$HOME/.cache/cmux-journeys/builds/{build['id']}"
        log(f"build {build['id']} on {host}: cached there, else downloaded once (and the text reader, once per mini)")
        app = remote(host, f"set -e; cd {q(work)}; mkdir -p $HOME/.cache/cmux-journeys/builds; "
                           f"( [ -x {ocr} ] || {{ swiftc -O kit/ocr.swift -o {ocr}.$$ && mv -f {ocr}.$$ {ocr}; }} ) >ocr.log 2>&1 & "
                           f"c={cache}; find $HOME/.cache/cmux-journeys/builds -maxdepth 1 -name '*.tmp.*' -mmin +60 -exec rm -rf {{}} + 2>/dev/null || true; "
                           f"if [ -f \"$c/ok\" ]; then echo 'journeys: build cache hit' >&2; touch \"$c\"; else "
                           f"t=\"$c.tmp.$$\"; rm -rf \"$t\"; mkdir -p \"$t\"; cmux-ci artifact {q(build['id'])} \"$t/app.zip\" >&2; "
                           f"ditto -x -k \"$t/app.zip\" \"$t/build\"; rm -f \"$t/app.zip\"; rm -rf \"$c\"; mv \"$t\" \"$c\"; touch \"$c/ok\" \"$c\"; "
                           f"ls -1t $HOME/.cache/cmux-journeys/builds | grep -v '\\.tmp\\.' | tail -n +{BUILD_CACHE_KEEP + 1} | "
                           f"while read -r old; do rm -rf \"$HOME/.cache/cmux-journeys/builds/$old\"; done; fi; wait || true; "
                           f"[ -x {ocr} ] || {{ cat ocr.log >&2; exit 3; }}; "
                           f"a=$(find \"$c/build\" -maxdepth 2 -name '*.app' -type d | head -1); "
                           # The commit the build job names, beside the bundle unpacked from that job's artifact:
                           # capture-host launch --commit checks it (and the bundle's own CMUXCommit, if any, must agree).
                           f"[ -z \"$a\" ] || {{ [ {len(str(build.get('commit') or ''))} -ne 40 ] || "
                           f"printf '%s\\n' {q(build.get('commit') or '')} > \"$(dirname \"$a\")/capture-commit\"; }}; echo \"$a\"",
                     timeout=left(420)).stdout.decode().strip()
        if not app.endswith(".app"):
            raise RuntimeError(f"build {build['id']} has no app bundle")
        # capture-host (hq main since 2026-10-30) launches only the build of --commit, checked against the bundle.
        commit = str(build.get("commit") or "")
        if not re.fullmatch(r"[0-9a-f]{7,40}", commit):
            raise RuntimeError(f"build {build['id']} names no commit sha ({commit!r}): capture-host launch needs --commit")
        # --whole-host: the app launches active (--activate, which capture-host allows on a whole-host lease
        # only): it is the active app with a key window, as on a person's Mac.
        launched = run([ch, "launch", "--commit", commit, *(["--activate"] if whole_host else []), lease, app,
                        build.get("tag") or "journeys", "--"],
                       timeout=left(180), check=False)
        facts = launch_facts(launched.stdout.decode())
        if facts.get("socket", "none") == "none":
            raise RuntimeError(f"the app did not answer on its control socket: "
                               f"{(launched.stdout + launched.stderr).decode(errors='replace').strip()[-400:]}")
        if hog_started:
            # The rest of the warm-up: the pressure builds before the journeys start.
            time.sleep(max(0.0, HOG_WARMUP_SECONDS - (time.monotonic() - hog_started)))
        budget = int(left(LEASE_SECONDS) - 45)
        if budget < 60:
            raise RuntimeError(f"the lease has {budget + 45}s left after setup: too little to run journeys")
        log(f"driving {', '.join(ids)} on {host} ({budget}s left on the lease)")
        set_phase(ch, lease, "journey")
        drove = remote(host, f"/usr/bin/python3 -I {q(work + '/kit/driver.py')} --socket {q(facts['socket'])} "
                             f"--app {q(facts.get('app', app))} --home {q(root + '/home')} "
                             f"--journeys {q(work + '/kit/journeys.json')} --out {q(work + '/out')} --ocr {ocr} "
                             f"--deadline-seconds {budget} --frame-interval {frame_interval} "
                             f"--run-id {q(ident['run_id'])} --run-started-at {q(ident['run_started_at'])}"
                             + (" --activate" if whole_host else ""),
                       timeout=budget + 90, check=False)
        for line in drove.stdout.decode(errors="replace").splitlines():
            log(f"[{host}] {line}")
        if drove.returncode not in (0, 1):
            log(f"driver exited {drove.returncode}: {drove.stderr.decode(errors='replace').strip()[-600:]}")
        files = remote(host, f"cd {q(work + '/out')} && tar c --exclude 'frames' --exclude '*.scan' . | head -c {RESULT_TAR_MAX_BYTES}",
                       timeout=left(150), check=False).stdout
        take_results(files, out, set(ids))
        set_phase(ch, lease, "idle")  # the journeys ran and their results are here: only the clean-up and release left
        if hog_started:
            hog_log = remote(host, f"tail -c 2000000 {q(work + '/hog.jsonl')}", timeout=left(60), check=False).stdout
            (out / f"hog-{lease}.jsonl").write_bytes(hog_log or b"")
    except (RuntimeError, subprocess.TimeoutExpired, KeyError, ValueError, OSError, tarfile.TarError) as error:
        log(f"lease {lease}: {error}")
        reason = f"{host or lease}: {str(error)[-400:]}"
        if drove is None:
            # The launch (or a relaunch in a capture-host wrapper) or the set-up failed: no journey started, so no
            # result.json in OUT can be this run's (STATUS 1362: a failed relaunch reported an older round's result).
            return {i: {"status": "not run", "reason": reason, "host": host} for i in ids}
        return stamp_harness(collect(out, ids, host, missing_reason=reason, ident=ident), out, ident.get("harness"), harness)
    finally:
        # The whole clean-up with stops blocked: a second TERM (^C reaches run.py and fuzz.py, which then sends TERM)
        # must not kill the release; a stop that came meanwhile is raised when the mask is restored, after it.
        signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
        if hog_started and host:
            # Our own hog only: the pid it wrote, checked to still be smoke_hog.py (its deadline ends it anyway).
            # A stop that times out must not skip the release below.
            try:
                remote(host, f"p=$(cat {q(work + '/hog.pid')} 2>/dev/null) && [ -n \"$p\" ] && "
                             f"ps -p \"$p\" -o command= | grep -q smoke_hog.py && kill \"$p\"; true", timeout=30, check=False)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                log(f"stopping the memory hog on {host} failed ({error}); it ends by itself at its deadline")
        try:
            released = subprocess.run([ch, "release", lease], capture_output=True, timeout=120)
            log(f"released {lease}" if released.returncode == 0 else
                f"release of {lease} exited {released.returncode} (it expires within 10 minutes)")
        except (OSError, subprocess.TimeoutExpired) as error:
            log(f"release of {lease} failed ({error}); it expires within 10 minutes")
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)
    return stamp_harness(collect(out, ids, host, missing_reason=f"{host}: the driver wrote no result (driver exit {drove.returncode}: "
                                                               f"{drove.stderr.decode(errors='replace').strip()[-300:]})",
                                 ident=ident), out, ident.get("harness"), harness)


def take_results(files, out, ids):
    """Keeps only the expected regular files of the mini's tarball: the app there could plant links or paths."""
    if not files:
        return
    with tarfile.open(fileobj=io.BytesIO(files)) as tar:
        for member in tar:
            match = RESULT_FILE.fullmatch(member.name)
            limit = RESULT_MOVIE_MAX_BYTES if member.name.endswith(".mov") else RESULT_MAX_BYTES
            if not match or not member.isreg() or member.size > limit:
                continue
            name = match.group(1)
            if "/" in name and name.split("/", 1)[0] not in ids:
                continue
            target = out / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(member).read())


def set_aside_old_results(out, ids):
    """Moves an earlier run's journey folders out of the way before this lease, so `collect` can never report an old
    result.json as this round's: a reused --out folder plus a launch that fails before the driver writes anything gave
    the earlier round's result (resize P0, 2026-10-31: the 11:32Z rounds reported the 11:22Z ones)."""
    for i in ids:
        old = out / i
        if old.exists():
            old.rename(out / f"{i}.old-{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}-{os.getpid()}")


def set_aside_foreign(out, i, ident):
    """Moves a refused <id>/ folder aside (<id>.foreign-<run id>); a failure is logged, never raised out of run_lease."""
    try:
        (out / i).rename(out / f"{i}.foreign-{ident['run_id']}")
    except OSError as error:
        log(f"{i}: the refused result folder was not moved aside: {error}")


def collect(out, ids, host, missing_reason, ident):
    """{id: this run's result.json}, or not run: with missing_reason when there is none, "stale or foreign result"
    when its run id or start time is not `ident`'s (an earlier round's file, or one from a reused slot)."""
    results = {}
    for i in ids:
        path = out / i / "result.json"
        if not path.is_file():
            results[i] = {"status": "not run", "reason": missing_reason, "host": host}
            continue
        try:
            result = json.loads(path.read_text())
        except ValueError as error:
            set_aside_foreign(out, i, ident)
            results[i] = {"status": "not run", "reason": f"result.json does not parse: {error}", "host": host}
            continue
        why = stale_reason(result, ident)
        if why:
            log(f"{i}: {why}")
            # Moved aside, so no clip, check frame or reader of <id>/ takes another run's files as this run's.
            set_aside_foreign(out, i, ident)
            results[i] = {"status": "not run", "reason": why, "host": host}
            continue
        result["host"] = host
        results[i] = result
    return results


# ---- clips -------------------------------------------------------------------------------

def make_clip(directory, interval):
    """clip.mp4 with ffmpeg, else clip.png (APNG, standard library only) from <id>/clip/frame-*.png."""
    frames = sorted((directory / "clip").glob("frame-*.png"))
    if not frames:
        return None
    if shutil.which("ffmpeg"):
        listing, video = directory / "clip.txt", directory / "clip.mp4"
        listing.write_text("".join(f"file '{f.resolve()}'\nduration {interval:g}\n" for f in frames) + f"file '{frames[-1].resolve()}'\n")
        done = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
                               "-vf", "scale=1280:-2", "-pix_fmt", "yuv420p", str(video)], capture_output=True, timeout=600)
        listing.unlink()
        if done.returncode == 0:
            return video
    return apng(frames, directory / "clip.png", interval)


def png_chunks(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, chunks = 8, []
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunks.append((kind, data[pos + 8:pos + 8 + length]))
        pos += 12 + length
    return chunks


def apng(frames, target, interval):
    """An animated PNG of same-format frames (others skipped), `interval` seconds each; identical frames merge."""
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    parsed, last = [], None
    for path in frames:
        data = path.read_bytes()
        if data == last and parsed:
            parsed[-1][2] += 1
            continue
        last = data
        chunks = png_chunks(data)
        ihdr = dict(chunks).get(b"IHDR")
        if ihdr is None or (parsed and ihdr[8:] != parsed[0][0][8:]):
            continue
        parsed.append([ihdr, b"".join(body for kind, body in chunks if kind == b"IDAT"), 1])
    if not parsed:
        return None
    width, height = struct.unpack(">II", parsed[0][0][:8])
    parsed = [p for p in parsed if struct.unpack(">II", p[0][:8]) == (width, height)]
    out, seq = [b"\x89PNG\r\n\x1a\n", chunk(b"IHDR", parsed[0][0]), chunk(b"acTL", struct.pack(">II", len(parsed), 0))], 0
    for index, (ihdr, idat, repeats) in enumerate(parsed):
        delay = max(1, round(interval * repeats * 100))
        out.append(chunk(b"fcTL", struct.pack(">IIIIIHHBB", seq, width, height, 0, 0, delay, 100, 0, 0)))
        seq += 1
        if index == 0:
            out.append(chunk(b"IDAT", idat))
        else:
            out.append(chunk(b"fdAT", struct.pack(">I", seq) + idat))
            seq += 1
    out.append(chunk(b"IEND", b""))
    target.write_bytes(b"".join(out))
    return target


# ---- report ------------------------------------------------------------------------------

def compact(evidence):
    rows = []
    for e in evidence or []:
        detail = e.get("detail")
        if isinstance(detail, dict):
            detail = {k: v for k, v in detail.items() if k in ("last_line", "tail", "image", "text", "pid", "tty", "matches", "got", "error")}
        rows.append({"kind": e.get("kind"), "check": e.get("check"), "want": e.get("want"), "pass": e.get("pass"),
                     "elapsed_ms": e.get("elapsed_ms"), "within_ms": e.get("within_ms"), "detail": detail})
    return rows


def threading_main():
    import threading
    return threading.current_thread() is threading.main_thread()


class Terminated(BaseException):
    """SIGTERM of run.py (fuzz.py or the gate stopping a round): raised so every `finally` runs, above all the lease
    release in run_lease (cmux-ad 09:05Z: an error or a stop inside a round must still release the lease)."""


def _terminated(signum, frame):
    raise Terminated(f"signal {signum}")


def main(argv=None):
    if threading_main():
        signal.signal(signal.SIGTERM, _terminated)
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 1)[1])
    target = ap.add_mutually_exclusive_group()
    target.add_argument("--build", help="a cmux fleet build job id (its artifact is the app under test)")
    target.add_argument("--commit", help="an exact pushed SHA: its fleet build (submitted once, receipt reused)")
    pick = ap.add_mutually_exclusive_group()
    pick.add_argument("--priority", choices=PRIORITIES, default="P0")
    pick.add_argument("--journey", action="append", help="a journey id (repeatable)")
    pick.add_argument("--all", action="store_true")
    ap.add_argument("--out", help="output folder (default artifacts/journeys/<job12>-<time>)")
    ap.add_argument("--hosts", help="capture hosts to lease from, spaces between (sets CAPTURE_HOST_SLOT_HOSTS)")
    ap.add_argument("--hog-swap-gb", type=float, default=0.0,
                    help="memory pressure during each lease: the Austin's-day hog to this much swap above the start")
    ap.add_argument("--whole-host", action="store_true",
                    help="lease the whole mini (capture-host acquire without --slot) and launch the app active "
                         "(--activate): it gets a key window. Needs CuaDriver's grants on the mini")
    ap.add_argument("--exclusive", action="store_true",
                    help="take each lease exclusive (the whole mini; capture-host acquire --slot --exclusive): for evidence")
    ap.add_argument("--journey-option", action="append", default=[], metavar="KEY=VALUE",
                    help="an option the chosen journeys' step groups read (spec `options`; e.g. the smoke gate's "
                         "smoke_mode=diagnostic); repeatable")
    ap.add_argument("--frame-interval", type=float, default=1.0, help="seconds between clip frames (>= 0.25)")
    ap.add_argument("--build-wait-minutes", type=float, default=90, help="how long to wait for a running build")
    ap.add_argument("--list", action="store_true", help="print the journeys and exit")
    ap.add_argument("--check", action="store_true", help="validate the journey files and exit")
    opts = ap.parse_args(argv)

    specs, problems = load_journeys()
    if problems:
        print("\n".join(f"journeys: {p}" for p in problems), file=sys.stderr)
        return 2
    if opts.list:
        for s in specs:
            print(f"{s['priority']}  {s['id']:<16} {s['_path']:<44} {s['title']}")
        return 0
    if opts.check:
        print(f"journeys: {len(specs)} journey files valid")
        return 0
    if not (opts.build or opts.commit):
        ap.error("name the build under test: --build JOB or --commit SHA")
    chosen = select(specs, opts)
    if not chosen:
        ap.error("no journey selected")
    options = {}
    for item in opts.journey_option:
        key, sep, value = item.partition("=")
        if not sep or not re.fullmatch(r"[a-z][a-z0-9_]*", key):
            ap.error(f"--journey-option takes KEY=VALUE (KEY lowercase letters, digits, _): {item!r}")
        options[key] = value
    if options:
        chosen = [dict(s, options=dict(s.get("options") or {}, **options)) for s in chosen]
    if opts.hosts:
        os.environ["CAPTURE_HOST_SLOT_HOSTS"] = os.environ["CAPTURE_HOST_HOSTS"] = opts.hosts
    exclude = os.environ.get("JOURNEYS_EXCLUDE_HOSTS", "cmux16")
    os.environ["CAPTURE_HOST_EXCLUDE"] = " ".join(x for x in (os.environ.get("CAPTURE_HOST_EXCLUDE", ""), exclude) if x)

    this_run = new_run()
    this_run["harness"] = harness_state()
    if this_run["harness"]["dirty"] or not this_run["harness"]["commit"]:
        log(f"harness: unpinned at the start ({len(this_run['harness']['dirty'])} uncommitted harness files): its results will "
            "be not run. Run fleet rounds from a pinned, reviewed checkout (git worktree add --detach DIR SHA)")
    out_root = ROOT / "artifacts" / "journeys"
    job = opts.build or build_for_commit(opts.commit, out_root)
    status = wait_build(job, opts.build_wait_minutes * 60)
    build = {"id": status.get("id", job), "commit": status.get("ref") or status.get("commit"), "tag": status.get("tag"),
             "state": status.get("state")}
    out = Path(opts.out) if opts.out else out_root / f"{build['id'][:12]}-{this_run['run_id']}"
    earlier = earlier_run(out)
    out.mkdir(parents=True, exist_ok=True)
    if earlier:
        # Kept beside under this run's id, never read again: a caller that reads results.jsonl, run.json or <id>/ sees
        # only this run's not-run lines.
        for name in ("results.jsonl", "run.json"):
            if (out / name).exists():
                (out / name).rename(out / f"{name}.earlier-{this_run['run_id']}")
        set_aside_old_results(out, [s["id"] for s in chosen])
    (out / "run.json").write_text(json.dumps(dict(this_run, build_job=build["id"], pid=os.getpid()), indent=1) + "\n")
    log(f"build {build['id']} ({build['state']}) of {str(build['commit'])[:12]} tag {build['tag']}; run {this_run['run_id']}; "
        f"results in {out}")

    results = {}
    if earlier:
        why = f"--out {out} holds an earlier run's results ({earlier}): each run needs a new folder"
        log(why)
        results = {s["id"]: {"status": "not run", "reason": why} for s in chosen}
    elif build["state"] != "done":
        why = f"build {build['id']} is {build['state']}" + ("" if build["state"] in ("failed", "cancelled") else " (still building)")
        results = {s["id"]: {"status": "not run", "reason": why} for s in chosen}
    else:
        for group in batches(chosen):
            results.update(run_lease(group, build, out, opts.frame_interval, exclusive=opts.exclusive,
                                     hog_swap_gb=opts.hog_swap_gb, whole_host=opts.whole_host, run_ident=this_run))

    lines = []
    for spec in chosen:
        result = results.get(spec["id"], {"status": "not run", "reason": "no result"})
        clip = make_clip(out / spec["id"], opts.frame_interval) if (out / spec["id"]).is_dir() and not earlier else None
        line = {"id": spec["id"], "priority": spec["priority"], "status": result.get("status", "not run"),
                "reason": result.get("reason", ""), "evidence": compact(result.get("evidence")),
                "clip": str(clip) if clip else None,
                "checks": [] if earlier else sorted(str(p) for p in (out / spec["id"]).glob("check-*.png")),
                "build_job": build["id"], "commit": build["commit"], "tag": build["tag"], "host": result.get("host"),
                "path": spec["_path"], "nonce": result.get("nonce"), "seconds": result.get("seconds"),
                "run_id": this_run["run_id"], "run_started_at": this_run["run_started_at"],
                "harness": result.get("harness") or dict({k: this_run["harness"][k] for k in ("commit", "dirty", "detached")},
                                                          pinned=None),
                "run_at": result.get("started_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        lines.append(line)
    with open(out / "results.jsonl", "w") as f:
        for line in lines:
            f.write(json.dumps(line) + "\n")
    for line in lines:
        print(json.dumps({k: line[k] for k in ("id", "priority", "status", "reason", "clip")}))
    log(f"results: {out / 'results.jsonl'}")
    statuses = {line["status"] for line in lines}
    return 1 if "fail" in statuses else 75 if "not run" in statuses else 0


if __name__ == "__main__":
    sys.exit(main())
