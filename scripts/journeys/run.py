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

Writes OUT (default artifacts/journeys/<job12>-<UTC time>/): results.jsonl (one line per journey:
id, priority, status pass|fail|not run, evidence, clip, build), <id>/result.json, <id>/check-NN.png
(each frame a check read), <id>/clip.mp4 (ffmpeg) or <id>/clip.png (an animated PNG; any browser
plays it). A journey that could not run is "not run" with the reason, never a pass.
Exit 0 when every selected journey passed, 1 when one failed, 75 when none failed but one did not run.

Capture hosts: capture-host reads the fleet registry (~/.ssh/config.d/fleet-registry.json), or
CAPTURE_HOST_SLOT_HOSTS (--hosts sets it). JOURNEYS_EXCLUDE_HOSTS (default cmux16) are never leased.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import shutil
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
                         r"|restore-trace\.json|diag-[a-z]+\.(?:json|png|txt)|diag-app-sample\.txt)|host\.json|summary\.json)")
RESULT_MAX_BYTES = 64 << 20
# The proof runs' load rule: a lease drives journeys only on a host whose 1-minute load is under LOAD_LIMIT; it
# waits for that at most LOAD_WAIT_SECONDS per lease (reading every LOAD_POLL_SECONDS), then drives anyway and
# the run is load-invalid. A failure on a loaded host stays a failure, with "(loaded host)" as a fact.
LOAD_LIMIT = 4.0
LOAD_WAIT_SECONDS = 600
LOAD_POLL_SECONDS = 30
RESULT_TAR_MAX_BYTES = 768 << 20
STEP_NAMES = {name[len("step_"):] for name in dir(driver.Journey) if name.startswith("step_")}


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


def host_load(host):
    """The host's 1-minute load average (one ssh read), or None when it cannot be read."""
    try:
        done = remote(host, "sysctl -n vm.loadavg", timeout=30, check=False)
    except subprocess.TimeoutExpired:
        return None
    numbers = re.findall(r"\d+(?:\.\d+)?", done.stdout.decode(errors="replace"))
    return float(numbers[0]) if done.returncode == 0 and numbers else None


class LoadedHost(Exception):
    """The leased host is loaded: the lease goes back while run_lease waits for the host to go quiet."""

    def __init__(self, host):
        super().__init__(host)
        self.host = host


def run_lease(specs, build, out, frame_interval):
    """Plays `specs` in one slot of a quiet host; {id: result} (driver results, or not run with the reason).
    A loaded host's lease goes back (a lease lasts at most 10 minutes) while the host is read again every
    LOAD_POLL_SECONDS; then the same host is preferred. After LOAD_WAIT_SECONDS it drives anyway, load-invalid."""
    gate = {"limit": LOAD_LIMIT, "reads": [], "waited_s": 0.0}
    began = time.monotonic()
    gate_end = began + LOAD_WAIT_SECONDS
    prefer = None
    while True:
        try:
            return play_lease(specs, build, out, frame_interval, gate, gate_end, prefer)
        except LoadedHost as loaded:
            prefer = loaded.host
            while time.monotonic() < gate_end:
                time.sleep(min(LOAD_POLL_SECONDS, gate_end - time.monotonic()))
                load = host_load(prefer)
                gate["reads"].append({"host": prefer, "load": load})
                if load is not None and load < LOAD_LIMIT:
                    break
            gate["waited_s"] = round(time.monotonic() - began, 1)


def play_lease(specs, build, out, frame_interval, gate, gate_end, prefer):
    ch = capture_host()
    ids = [s["id"] for s in specs]
    try:
        acquired = run([ch, "acquire", "--slot"] + (["--prefer", prefer] if prefer else []), timeout=330).stdout.decode().split()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        return {i: {"status": "not run", "reason": f"no capture slot: {str(error)[-300:]}"} for i in ids}
    if not acquired:
        return {i: {"status": "not run", "reason": "capture-host acquire printed no lease"} for i in ids}
    lease, deadline = acquired[-1], time.monotonic() + LEASE_SECONDS
    left = lambda cap: max(10.0, min(cap, deadline - time.monotonic()))
    log(f"leased {lease}")
    facts, host = {}, None
    try:
        info = dict(kv.split("=", 1) for kv in run([ch, "slot-info", lease]).stdout.decode().split() if "=" in kv)
        host, root = info["host"], info["root"]
        load = host_load(host)
        gate["reads"].append({"host": host, "load": load})
        if load is not None and load >= LOAD_LIMIT and time.monotonic() < gate_end:
            log(f"{host} has a 1-minute load of {load:.1f} (limit {LOAD_LIMIT:g}): giving {lease} back until it is quieter")
            raise LoadedHost(host)
        gate.update(host=host, start=load, load_invalid=load is None or load >= LOAD_LIMIT)
        if gate["load_invalid"]:
            log(f"{host}: load {load} after {gate['waited_s']:.0f}s of waiting: driving anyway; the run is load-invalid")
        work = f"{root}/journeys"
        remote(host, f"mkdir -p {q(work + '/kit')} && tar x -C {q(work + '/kit')}", input=kit_tar(specs), timeout=left(120))
        # One compiled text reader per mini and source version, outside the slot (release removes the slot).
        digest = hashlib.sha256(OCR_SOURCE.read_bytes()).hexdigest()[:16]
        ocr = f"$HOME/.cache/cmux-journeys/ocr-{digest}"
        log(f"downloading build {build['id']} on {host} (and the text reader, once per mini)")
        app = remote(host, f"set -e; cd {q(work)}; mkdir -p $HOME/.cache/cmux-journeys; "
                           f"( [ -x {ocr} ] || {{ swiftc -O kit/ocr.swift -o {ocr}.$$ && mv -f {ocr}.$$ {ocr}; }} ) >ocr.log 2>&1 & "
                           f"cmux-ci artifact {q(build['id'])} app.zip >&2; ditto -x -k app.zip build; rm -f app.zip; wait || true; "
                           f"[ -x {ocr} ] || {{ cat ocr.log >&2; exit 3; }}; "
                           f"find \"$PWD/build\" -maxdepth 2 -name '*.app' -type d | head -1",
                     timeout=left(420)).stdout.decode().strip()
        if not app.endswith(".app"):
            raise RuntimeError(f"build {build['id']} has no app bundle")
        launched = run([ch, "launch", lease, app, build.get("tag") or "journeys", "--"], timeout=left(180), check=False)
        facts = launch_facts(launched.stdout.decode())
        if facts.get("socket", "none") == "none":
            raise RuntimeError(f"the app did not answer on its control socket: "
                               f"{(launched.stdout + launched.stderr).decode(errors='replace').strip()[-400:]}")
        budget = int(left(LEASE_SECONDS) - 45)
        if budget < 60:
            raise RuntimeError(f"the lease has {budget + 45}s left after setup: too little to run journeys")
        log(f"driving {', '.join(ids)} on {host} ({budget}s left on the lease)")
        drove = remote(host, f"/usr/bin/python3 -I {q(work + '/kit/driver.py')} --socket {q(facts['socket'])} "
                             f"--app {q(facts.get('app', app))} --home {q(root + '/home')} "
                             f"--journeys {q(work + '/kit/journeys.json')} --out {q(work + '/out')} --ocr {ocr} "
                             f"--deadline-seconds {budget} --frame-interval {frame_interval}",
                       timeout=budget + 90, check=False)
        for line in drove.stdout.decode(errors="replace").splitlines():
            log(f"[{host}] {line}")
        if drove.returncode not in (0, 1):
            log(f"driver exited {drove.returncode}: {drove.stderr.decode(errors='replace').strip()[-600:]}")
        files = remote(host, f"cd {q(work + '/out')} && tar c --exclude 'frames' . | head -c {RESULT_TAR_MAX_BYTES}",
                       timeout=left(150), check=False).stdout
        take_results(files, out, set(ids))
    except (RuntimeError, subprocess.TimeoutExpired, KeyError, ValueError) as error:
        log(f"lease {lease}: {error}")
        reason = f"{host or lease}: {str(error)[-400:]}"
        return collect(out, ids, host, missing_reason=reason, gate=gate)
    finally:
        released = subprocess.run([ch, "release", lease], capture_output=True, timeout=120)
        log(f"released {lease}" if released.returncode == 0 else
            f"release of {lease} exited {released.returncode} (it expires within 10 minutes)")
    return collect(out, ids, host, missing_reason=f"{host}: the driver wrote no result (driver exit {drove.returncode}: "
                                                  f"{drove.stderr.decode(errors='replace').strip()[-300:]})", gate=gate)


def take_results(files, out, ids):
    """Keeps only the expected regular files of the mini's tarball: the app there could plant links or paths."""
    if not files:
        return
    with tarfile.open(fileobj=io.BytesIO(files)) as tar:
        for member in tar:
            match = RESULT_FILE.fullmatch(member.name)
            if not match or not member.isreg() or member.size > RESULT_MAX_BYTES:
                continue
            name = match.group(1)
            if "/" in name and name.split("/", 1)[0] not in ids:
                continue
            target = out / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(tar.extractfile(member).read())


def collect(out, ids, host, missing_reason, gate=None):
    results = {}
    lease_load = {k: (gate or {}).get(k) for k in ("start", "waited_s", "reads")}
    for i in ids:
        path = out / i / "result.json"
        if path.is_file():
            result = json.loads(path.read_text())
            result["host"] = host
        else:
            result = {"status": "not run", "reason": missing_reason, "host": host}
        result["lease_load"], result["load_invalid"] = lease_load, bool((gate or {}).get("load_invalid"))
        results[i] = result
    return results


def load_facts(result):
    """(load, load_invalid, loaded_host) of one journey's result: its own start and end load (the driver's),
    else the lease's start load. loaded_host only for a fail: it stays a fail, the load is a fact beside it."""
    load = result.get("load") if isinstance(result.get("load"), dict) else {}
    load = {"start": load.get("start", (result.get("lease_load") or {}).get("start")), "end": load.get("end")}
    loaded = any(isinstance(v, (int, float)) and v >= LOAD_LIMIT for v in load.values())
    invalid = bool(result.get("load_invalid")) or loaded
    return load, invalid, loaded and result.get("status") == "fail"


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


def main(argv=None):
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
    if opts.hosts:
        os.environ["CAPTURE_HOST_SLOT_HOSTS"] = os.environ["CAPTURE_HOST_HOSTS"] = opts.hosts
    exclude = os.environ.get("JOURNEYS_EXCLUDE_HOSTS", "cmux16")
    os.environ["CAPTURE_HOST_EXCLUDE"] = " ".join(x for x in (os.environ.get("CAPTURE_HOST_EXCLUDE", ""), exclude) if x)

    out_root = ROOT / "artifacts" / "journeys"
    job = opts.build or build_for_commit(opts.commit, out_root)
    status = wait_build(job, opts.build_wait_minutes * 60)
    build = {"id": status.get("id", job), "commit": status.get("ref") or status.get("commit"), "tag": status.get("tag"),
             "state": status.get("state")}
    out = Path(opts.out) if opts.out else out_root / f"{build['id'][:12]}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    out.mkdir(parents=True, exist_ok=True)
    log(f"build {build['id']} ({build['state']}) of {str(build['commit'])[:12]} tag {build['tag']}; results in {out}")

    results = {}
    if build["state"] != "done":
        why = f"build {build['id']} is {build['state']}" + ("" if build["state"] in ("failed", "cancelled") else " (still building)")
        results = {s["id"]: {"status": "not run", "reason": why} for s in chosen}
    else:
        for group in batches(chosen):
            results.update(run_lease(group, build, out, opts.frame_interval))

    lines = []
    for spec in chosen:
        result = results.get(spec["id"], {"status": "not run", "reason": "no result"})
        load, load_invalid, loaded_host = load_facts(result)
        reason = result.get("reason", "")
        if loaded_host:
            reason = f"(loaded host) {reason}"
        clip = make_clip(out / spec["id"], opts.frame_interval) if (out / spec["id"]).is_dir() else None
        line = {"id": spec["id"], "priority": spec["priority"], "status": result.get("status", "not run"),
                "reason": reason, "loaded_host": loaded_host, "load": load, "load_invalid": load_invalid,
                "lease_load": result.get("lease_load"), "evidence": compact(result.get("evidence")),
                "clip": str(clip) if clip else None, "checks": sorted(str(p) for p in (out / spec["id"]).glob("check-*.png")),
                "build_job": build["id"], "commit": build["commit"], "tag": build["tag"], "host": result.get("host"),
                "path": spec["_path"], "nonce": result.get("nonce"), "seconds": result.get("seconds"),
                "run_at": result.get("started_at") or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        lines.append(line)
    with open(out / "results.jsonl", "w") as f:
        for line in lines:
            f.write(json.dumps(line) + "\n")
    for line in lines:
        print(json.dumps({k: line[k] for k in ("id", "priority", "status", "reason", "loaded_host", "load_invalid", "clip")}))
    log(f"results: {out / 'results.jsonl'}")
    statuses = {line["status"] for line in lines}
    return 1 if "fail" in statuses else 75 if "not run" in statuses else 0


if __name__ == "__main__":
    sys.exit(main())
