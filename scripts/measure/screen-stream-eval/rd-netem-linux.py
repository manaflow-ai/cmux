#!/usr/bin/env python3
"""cmux.rd/1 under kernel netem jitter on one Linux machine, no Mac.

  rd-netem-linux.py --commit SHA [--commit SHA ...] --out DIR [--deps]
  rd-netem-linux.py --bin LABEL=PATH [--bin ...] --out DIR
  rd-netem-linux.py table RESULTS.jsonl

For each cmux commit it builds `cmux-rd` (`cmux-tui/crates/cmux-rd-host`, release, features
`bench,openh264,link`) in a fresh sparse source tree, then runs the real host and viewer in two network
namespaces joined by a veth whose two ends each carry `tc netem`:

  host ns:   Xvfb, `cmux-rd testapp --workload motion`, `cmux-rd host --profile baseline`
  viewer ns: `cmux-rd bench --carrier udp` (OpenH264 decode, hence the baseline profile)

Profiles (the netem line is applied to each direction's egress, so media and feedback both
see it; jitter is netem's default distribution, which reorders packets):

  clean            delay 0ms
  jitter-5         delay 5ms 5ms
  jitter-15-burst  delay 15ms 15ms, Gilbert-Elliott loss averaging 1 % in bursts of ~4 packets
  jitter-30-loss2  delay 30ms 30ms, 2 % random loss

Each profile starts a fresh host and runs two viewer sessions against it:
  passive  `bench --input none --duration-s N`: received Mbps per second and the host's target
           bitrate per second (the `kbps` of the host's newest stats message in that second)
  key      `bench --input key --samples N`: key press to decoded marker, p50/p95, lost
IDRs are the host's own per-frame timing records (CMUX_RD_TIMING_LOG) during each session.
`stage_ledger` (schema cmux.rd-stage-ledger/1) is copied from each bench line that has it.

Writes DIR/results.jsonl (one line per commit and profile, also printed) and DIR/results.md.
Needs root for `ip netns` and `tc` (it prefixes `sudo -n` when not root) and a kernel with
sch_netem. On the fleet: cmuxterm-hq `cmux-ci test --setup netem` (README.md here).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = "cmux.rd-netem-linux/1"
LEDGER_SCHEMA = "cmux.rd-stage-ledger/1"
REPO_URL = "https://github.com/manaflow-ai/cmux.git"
BUILD_FEATURES = "bench,openh264,link"
HOST_IP, VIEW_IP, PORT ="10.78.0.1", "10.78.0.2", 4103

# name -> netem arguments for each direction's egress (after `netem`).
PROFILES = {
    "clean": "delay 0ms",
    "jitter-5": "delay 5ms 5ms",
    # Gilbert-Elliott: p=0.25 % into the bad state, r=25 % out (mean burst 4 packets), every
    # packet lost in the bad state and none in the good one: p/(p+r) = 0.99 % lost on average.
    "jitter-15-burst": "delay 15ms 15ms loss gemodel 0.25% 25% 100% 0%",
    "jitter-30-loss2": "delay 30ms 30ms loss random 2%",
}
PROFILE_LABELS = {
    "clean": "clean",
    "jitter-5": "5±5 ms",
    "jitter-15-burst": "15±15 ms, 1% burst loss",
    "jitter-30-loss2": "30±30 ms, 2% loss",
}


# ---------------------------------------------------------------- pure parsing and table


def netem_args(profile: str) -> list[str]:
    return ["netem", *PROFILES[profile].split(), "limit", "100000"]


def last_json_line(text: str) -> dict | None:
    """The bench prints one JSON report as its last stdout line."""
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                return value
    return None


def _num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def ledger_of(report: dict | None):
    """The bench line's stage ledger, or None when this commit's bench has none."""
    ledger = (report or {}).get("stage_ledger")
    return ledger if isinstance(ledger, dict) else None


def summarize_passive(report: dict | None) -> dict:
    """Per-second received Mbps and host target kbps from a `--input none` bench line."""
    if not report:
        return {"ok": False}
    mbps, target, keyframes, fps = [], [], [], []
    for row in report.get("series") or []:
        b, ms = _num(row.get("bytes")), _num(row.get("duration_ms"))
        mbps.append(round(b * 8 / (ms / 1000) / 1e6, 3) if b is not None and ms else None)
        n = _num(row.get("decoded_frames"))
        fps.append(round(n / (ms / 1000), 2) if n is not None and ms else None)
        stats = row.get("host_stats") or {}
        target.append(_num(stats.get("kbps")))
        keyframes.append(_num(stats.get("keyframes")))
    seen = [k for k in keyframes if k is not None]
    seconds = _num(report.get("seconds"))
    total = _num(report.get("bytes"))
    return {
        "ok": bool(mbps) and report.get("ended") is None,
        "seconds": seconds,
        "mbps_per_s": mbps,
        "mbps_mean": round(total * 8 / seconds / 1e6, 3) if total is not None and seconds else None,
        "target_kbps_per_s": target,
        "decoded_fps_per_s": fps,
        "target_s_to_15mbps": seconds_to(target, 15_000),
        "received_s_to_15mbps": seconds_to(mbps, 15),
        "host_keyframes_delta": (seen[-1] - seen[0]) if len(seen) >= 2 else None,
        "fps": _num(report.get("fps")),
        "decoded_frames": _num(report.get("decoded_frames")),
        "decode_errors": report.get("decode_errors"),
        "first_frame_ms": _num(report.get("first_frame_ms")),
        "ended": report.get("ended"),
        "stage_ledger": ledger_of(report),
    }


def seconds_to(series: list, level: float):
    """The 1-based second in which a per-second series first reaches level, or None."""
    return next((i + 1 for i, v in enumerate(series) if v is not None and v >= level), None)


def summarize_key(report: dict | None) -> dict:
    """Key press to decoded marker from a `--input key` bench line."""
    if not report:
        return {"ok": False}
    g2g = report.get("g2g_ms") or {}
    stats = report.get("host_stats_last") or {}
    return {
        "ok": bool(g2g.get("n")),
        "n": g2g.get("n"),
        "p50_ms": _num(g2g.get("p50")),
        "p95_ms": _num(g2g.get("p95")),
        "lost": report.get("lost"),
        "stalls_ms": report.get("stalls_ms"),
        "mbit_per_s": _num(report.get("mbit_per_s")),
        "frames_per_s": _num(report.get("frames_per_s")),
        "target_kbps_last": _num(stats.get("kbps")),
        "host_loss_pct_last": _num(stats.get("loss_pct")),
        "ended": report.get("ended"),
        "stage_ledger": ledger_of(report),
    }


def count_idrs(timing_text: str) -> dict:
    """Encoded frames and IDRs in a slice of the host's CMUX_RD_TIMING_LOG.

    `reasons` counts each IDR's `idr_reason` (or `force_idr`) for a host that logs one. No host
    does yet (`Timing::frame` in cmux-rd-host's stream.rs writes only `idr`), so today every IDR
    counts under "unlogged"."""
    frames = idrs = 0
    reasons: dict[str, int] = {}
    for line in timing_text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue  # a line the host was still writing
        if not isinstance(row, dict) or not isinstance(row.get("idr"), bool):
            continue  # input lines carry no encode
        if (_num(row.get("encoded_bytes")) or 0) <= 0:
            continue
        frames += 1
        idrs += row["idr"]
        if row["idr"]:
            reason = row.get("idr_reason")
            if reason is None and isinstance(row.get("force_idr"), bool):
                reason = "requested" if row["force_idr"] else "encoder"
            reason = str(reason) if reason is not None else "unlogged"
            reasons[reason] = reasons.get(reason, 0) + 1
    return {"frames": frames, "idrs": idrs, "reasons": reasons}


def _fmt(value, digits=1):
    if value is None:
        return "–"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def _series(values, digits=1, limit=30):
    shown = [_fmt(v, digits) for v in values[:limit]]
    return " ".join(shown) + (" …" if len(values) > limit else "") if shown else "–"


def markdown_table(rows: list[dict]) -> str:
    head = ("| cmux-rd | profile | key p50 / p95 ms (lost) | Mbps median (min–max) | Mbps per second "
            "| target kbps per second | s to 15 Mbps target / received | decoded fps median "
            "| IDRs / frames passive, key (reasons) | stage ledger |")
    out = [head, "|" + "---|" * 10]
    for r in rows:
        if r.get("error"):
            out.append(f"| `{r.get('commit', '?')[:12]}` | {PROFILE_LABELS.get(r.get('profile'), r.get('profile'))} "
                       f"| error: {' '.join(str(r['error']).split())[:120]} | | | | | | | |")
            continue
        key, passive = r.get("key") or {}, r.get("passive") or {}
        mbps = [v for v in passive.get("mbps_per_s") or [] if v is not None]
        target = [v for v in passive.get("target_kbps_per_s") or []]
        spread = (f"{statistics.median(mbps):.2f} ({min(mbps):.2f}–{max(mbps):.2f})" if mbps else "–")
        def idr_cell(c):
            c = c or {}
            why = ", ".join(f"{k} {v}" for k, v in sorted((c.get("reasons") or {}).items()))
            return f"{_fmt(c.get('idrs'))}/{_fmt(c.get('frames'))}" + (f" ({why})" if why else "")
        idr = f"{idr_cell(r.get('idr_passive'))}, {idr_cell(r.get('idr_key'))}"
        fps = [v for v in passive.get("decoded_fps_per_s") or [] if v is not None]
        fps_cell = f"{statistics.median(fps):.1f}" if fps else _fmt(passive.get("fps"))
        t15 = f"{_fmt(passive.get('target_s_to_15mbps'))} / {_fmt(passive.get('received_s_to_15mbps'))}"
        ledgers = [x for x in (passive.get("stage_ledger"), key.get("stage_ledger")) if x]
        ledger = "yes" if ledgers else "no"
        out.append(
            f"| `{r['commit'][:12]}` | {PROFILE_LABELS.get(r['profile'], r['profile'])} "
            f"| {_fmt(key.get('p50_ms'))} / {_fmt(key.get('p95_ms'))} ({_fmt(key.get('lost'))}) "
            f"| {spread} | {_series(passive.get('mbps_per_s') or [], 1)} "
            f"| {_series(target, 0)} | {t15} | {fps_cell} | {idr} | {ledger} |")
    return "\n".join(out) + "\n"


def read_rows(path: Path) -> list[dict]:
    rows = []
    for line in path.read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


# ---------------------------------------------------------------- privileged plumbing


def priv(cmd: list[str]) -> list[str]:
    return cmd if os.geteuid() == 0 else ["sudo", "-n", *cmd]


def run(cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, capture_output=True, text=True, **kw)


class Rig:
    """Two namespaces and a veth, named after this process so parallel runs never collide."""

    def __init__(self):
        tag = os.getpid()
        self.host_ns, self.view_ns = f"rdnh-{tag}", f"rdnv-{tag}"
        self.host_dev, self.view_dev = f"rdh{tag % 100000}", f"rdv{tag % 100000}"

    def up(self):
        run(priv(["ip", "netns", "add", self.host_ns]))
        run(priv(["ip", "netns", "add", self.view_ns]))
        run(priv(["ip", "link", "add", self.host_dev, "netns", self.host_ns, "type", "veth",
                  "peer", "name", self.view_dev, "netns", self.view_ns]))
        for ns, dev, ip in ((self.host_ns, self.host_dev, HOST_IP), (self.view_ns, self.view_dev, VIEW_IP)):
            run(priv(["ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up"]))
            run(priv(["ip", "netns", "exec", ns, "ip", "addr", "add", f"{ip}/24", "dev", dev]))
            run(priv(["ip", "netns", "exec", ns, "ip", "link", "set", dev, "mtu", "1500", "up"]))
            # Segmentation offload would hand netem 64 KB super-packets instead of datagrams.
            run(priv(["ip", "netns", "exec", ns, "ethtool", "-K", dev, "gso", "off", "tso", "off", "gro", "off"]),
                check=False)

    def shape(self, profile: str) -> list[str]:
        lines = []
        for ns, dev in ((self.host_ns, self.host_dev), (self.view_ns, self.view_dev)):
            run(priv(["ip", "netns", "exec", ns, "tc", "qdisc", "replace", "dev", dev, "root", *netem_args(profile)]))
            lines.append(run(priv(["ip", "netns", "exec", ns, "tc", "qdisc", "show", "dev", dev])).stdout.strip())
        return lines

    def down(self):
        for ns in (self.host_ns, self.view_ns):
            run(priv(["ip", "netns", "del", ns]), check=False)

    def spawn(self, ns: str, argv: list[str], env: dict | None = None, token: Path | None = None,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) -> subprocess.Popen:
        # sudo closes inherited descriptors, so the token reaches fd 3 inside the namespace, as a
        # pipe: cmux-rd refuses a token fd that is a file.
        inner = ["env", *(f"{k}={v}" for k, v in (env or {}).items())]
        if token is not None:
            inner += ["bash", "-c", 'exec "$@" 3< <(cat "$0")', str(token)]
        return subprocess.Popen(priv(["ip", "netns", "exec", ns, *inner, *argv]),
                                stdout=stdout, stderr=stderr, start_new_session=True)


def stop(proc: subprocess.Popen | None):
    """Stops a child this script started (by its own pid; sudo forwards the signal)."""
    if proc is None or proc.poll() is not None:
        return
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


# ---------------------------------------------------------------- build


def ensure_deps():
    run(priv(["apt-get", "update", "-qq"]))
    run(priv(["apt-get", "install", "-y", "-qq", "--no-install-recommends", "build-essential", "pkg-config",
              "libssl-dev", "nasm", "curl", "iproute2", "ethtool", "xvfb", "x11-xkb-utils"]))


def build(commit: str, work: Path, repo_url: str) -> Path:
    src = work / f"src-{commit[:12]}"
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    git = ["git", "-C", str(src)]
    run(git + ["init", "-q"])
    run(git + ["remote", "add", "origin", repo_url])
    run(git + ["fetch", "-q", "--depth=1", "--filter=blob:none", "origin", commit])
    run(git + ["sparse-checkout", "set", "cmux-tui/crates"])
    run(git + ["checkout", "-q", "--detach", commit])
    full = run(git + ["rev-parse", "HEAD"]).stdout.strip()
    if not full.startswith(commit):
        raise SystemExit(f"fetched {full}, asked for {commit}")
    found = re.search(r'channel\s*=\s*"([^"]+)"', (src / "cmux-tui/rust-toolchain.toml").read_text())
    if not found:
        raise SystemExit(f"{commit}: no toolchain channel in cmux-tui/rust-toolchain.toml")
    toolchain = found.group(1)
    env = dict(os.environ, RUSTUP_TOOLCHAIN=toolchain, CARGO_TARGET_DIR=str(work / "target"))
    cargo_bin = Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")) / "bin"
    env["PATH"] = f"{cargo_bin}:{env['PATH']}"
    if not shutil.which("rustup", path=env["PATH"]):
        installer = work / "rustup-init.sh"
        subprocess.run(["curl", "--fail", "-sS", "https://sh.rustup.rs", "-o", str(installer)], check=True)
        subprocess.run(["sh", str(installer), "-y", "--profile", "minimal", "--default-toolchain", "none",
                        "--no-modify-path"], check=True)
    subprocess.run(["rustup", "toolchain", "install", toolchain, "--profile", "minimal"], check=True, env=env)
    t0 = time.time()
    # The release build's features plus the bench viewer; `portal` (Wayland capture through PipeWire)
    # is left out like cmux-rd-release.yml does: Xvfb needs none of it.
    subprocess.run(["cargo", "build", "--release", "--locked", "--bin", "cmux-rd", "--no-default-features",
                    "--features", BUILD_FEATURES, "--manifest-path",
                    str(src / "cmux-tui/crates/cmux-rd-host/Cargo.toml")], check=True, env=env)
    print(f"rd-netem-linux: built {full[:12]} in {time.time() - t0:.0f} s", file=sys.stderr, flush=True)
    out = work / "bin" / f"cmux-rd-{full}"
    out.parent.mkdir(exist_ok=True)
    shutil.copy2(work / "target/release/cmux-rd", out)
    shutil.rmtree(src)
    return out


# ---------------------------------------------------------------- measure


def wait_for(path: Path, needle: str, proc: subprocess.Popen, seconds: float) -> bool:
    deadline = time.time() + seconds
    while time.time() < deadline:
        if path.exists() and needle in path.read_text(errors="replace"):
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.1)
    return False


def bench(rig: Rig, binary: Path, token: Path, args: list[str], timeout: float) -> tuple[dict | None, str]:
    argv = [str(binary), "bench", "--addr", f"{HOST_IP}:{PORT}", "--carrier", "udp", "--user", "owner",
            "--token-fd", "3", *args]
    proc = rig.spawn(rig.view_ns, argv, token=token, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        stop(proc)
        out, err = proc.communicate()
        err = (err or b"") + b"\nrd-netem-linux: bench timed out"
    return last_json_line(out.decode(errors="replace")), err.decode(errors="replace")[-800:]


def measure_profile(rig: Rig, binary: Path, commit: str, profile: str, scratch: Path, display: str,
                    passive_s: int, samples: int) -> dict:
    row = {"schema": SCHEMA, "commit": commit, "profile": profile, "netem_each_direction": PROFILES[profile],
           "workload": "motion", "carrier": "udp"}
    row["qdisc"] = rig.shape(profile)
    # The token lives in the private 0700 scratch, never under --out (an uploaded artifact).
    token = scratch / "token"
    token.write_text(os.urandom(32).hex())
    token.chmod(0o600)
    timing = scratch / f"timing-{profile}.jsonl"
    host_log = scratch / f"host-{profile}.log"
    timing.touch()
    host_log.touch()
    with open(host_log, "wb") as log:
        host = rig.spawn(rig.host_ns, [str(binary), "host", "--owner", "owner", "--bind", HOST_IP,
                                       "--single-tenant-overlay", "1", "--display", display, "--port", str(PORT),
                                       "--profile", "baseline", "--token-fd", "3"],
                         env={"CMUX_RD_TIMING_LOG": str(timing)}, token=token, stdout=log, stderr=log)
    try:
        if not wait_for(host_log, "listening", host, 20):
            row["error"] = "host did not listen: " + host_log.read_text(errors="replace")[-600:]
            return row
        start = timing.stat().st_size
        passive, perr = bench(rig, binary, token, ["--input", "none", "--duration-s", str(passive_s)], passive_s + 60)
        mid = timing.stat().st_size
        key, kerr = bench(rig, binary, token, ["--input", "key", "--samples", str(samples)], samples * 3 + 90)
        end = timing.stat().st_size
        data = timing.read_bytes()  # st_size offsets are bytes: slice bytes, then decode
        row["passive"] = summarize_passive(passive)
        row["key"] = summarize_key(key)
        row["idr_passive"] = count_idrs(data[start:mid].decode(errors="replace"))
        row["idr_key"] = count_idrs(data[mid:end].decode(errors="replace"))
        if not row["passive"]["ok"]:
            row["passive"]["stderr"] = perr
        if not row["key"]["ok"]:
            row["key"]["stderr"] = kerr
        return row
    finally:
        stop(host)
        time.sleep(0.5)  # the next host binds the same port


def measure_binary(binary: Path, commit: str, profiles: list[str], out: Path, args) -> list[dict]:
    rig = Rig()
    rig.down()
    # Private scratch (token, logs); --keep-logs copies only the logs into --out afterwards.
    scratch = Path(tempfile.mkdtemp(prefix=f"rd-netem-{commit[:12]}-"))
    rows, procs = [], []
    try:
        try:
            rig.up()
        except subprocess.CalledProcessError as error:
            for profile in profiles:
                row = {"schema": SCHEMA, "commit": commit, "profile": profile,
                       "error": f"netns setup: {error.cmd}: {(error.stderr or '').strip()}"}
                print(json.dumps(row), flush=True)
                with open(out / "results.jsonl", "a") as f:
                    f.write(json.dumps(row) + "\n")
                rows.append(row)
            return rows
        display = f":{170 + os.getpid() % 50}"
        procs.append(rig.spawn(rig.host_ns, ["Xvfb", display, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"]))
        time.sleep(1.5)
        procs.append(rig.spawn(rig.host_ns, [str(binary), "testapp", "--display", display, "--workload", "motion"]))
        time.sleep(1.5)
        for profile in profiles:
            try:
                row = measure_profile(rig, binary, commit, profile, scratch, display, args.passive_s, args.samples)
            except Exception as error:  # noqa: BLE001 - one profile's failure is that row's data
                row = {"schema": SCHEMA, "commit": commit, "profile": profile, "error": repr(error)}
            row["kernel"] = os.uname().release
            line = json.dumps(row)
            print(line, flush=True)
            with open(out / "results.jsonl", "a") as f:
                f.write(line + "\n")
            rows.append(row)
    finally:
        for proc in reversed(procs):
            stop(proc)
        rig.down()
        if args.keep_logs:
            keep = out / f"logs-{commit[:12]}"
            keep.mkdir(exist_ok=True)
            for log in scratch.glob("*.log*"):
                shutil.copy2(log, keep / log.name)
            for log in scratch.glob("timing-*.jsonl"):
                shutil.copy2(log, keep / log.name)
        shutil.rmtree(scratch, ignore_errors=True)
    return rows


def main(argv: list[str]) -> int:
    if argv[:1] == ["table"]:
        if len(argv) != 2:
            raise SystemExit("usage: rd-netem-linux.py table RESULTS.jsonl")
        sys.stdout.write(markdown_table(read_rows(Path(argv[1]))))
        return 0
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--commit", action="append", default=[], help="full cmux commit to build and measure")
    ap.add_argument("--bin", action="append", default=[], metavar="COMMIT=PATH", help="a prebuilt cmux-rd")
    ap.add_argument("--profile", action="append", choices=sorted(PROFILES), help="default: all four")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--repo-url", default=REPO_URL)
    ap.add_argument("--passive-s", type=int, default=20)
    ap.add_argument("--samples", type=int, default=60)
    ap.add_argument("--deps", action="store_true", help="apt-get the build and rig packages first")
    ap.add_argument("--keep-logs", action="store_true", help="keep host logs and timing records under --out")
    args = ap.parse_args(argv)
    if not args.commit and not args.bin:
        ap.error("give --commit or --bin")
    if any("=" not in b for b in args.bin):
        ap.error("--bin takes LABEL=PATH")
    for c in args.commit:
        if not re.fullmatch(r"[0-9a-f]{40}", c):
            ap.error(f"--commit {c}: a full 40-hex sha")
    profiles = args.profile or list(PROFILES)
    args.out.mkdir(parents=True, exist_ok=True)
    if args.deps:
        ensure_deps()
    preflight = run(priv(["modprobe", "sch_netem"]), check=False)
    if preflight.returncode:
        print(f"rd-netem-linux: modprobe sch_netem failed: {preflight.stderr.strip()} (the kernel needs sch_netem; "
              "cmuxterm-hq docs/handbook/netem-route-without-host-module.md)", file=sys.stderr)
        return 3
    work = Path(tempfile.mkdtemp(prefix="rd-netem-build-"))
    rows = []
    try:
        targets = [(label, Path(path)) for label, path in (b.split("=", 1) for b in args.bin)]
        for label, path in targets:
            rows += measure_binary(path, label, profiles, args.out, args)
        for commit in args.commit:
            try:
                binary = build(commit, work, args.repo_url)
            except (subprocess.CalledProcessError, SystemExit, OSError) as error:
                for profile in profiles:
                    row = {"schema": SCHEMA, "commit": commit, "profile": profile, "error": f"build: {error!r}"}
                    print(json.dumps(row), flush=True)
                    with open(args.out / "results.jsonl", "a") as f:
                        f.write(json.dumps(row) + "\n")
                    rows.append(row)
                continue
            rows += measure_binary(binary, commit, profiles, args.out, args)
            print(markdown_table([r for r in rows if r["commit"] == commit]), file=sys.stderr, flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    table = markdown_table(rows)
    (args.out / "results.md").write_text(table)
    print(table)
    return 0 if rows and not any(r.get("error") for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
