#!/usr/bin/env python3
"""Screen Sharing under netem: the real `cmux-rd serve` host and `cmux-rd bench --link`
viewer, in two network namespaces joined by a veth whose ends carry `tc netem`.

  sudo screen-share-netem.py BIN --rtt MS --loss PCT [--attempts N] [--samples S]
                             [--blip-at S --blip-s S]
                             [--drop-seconds S --drop-seconds S]
                             [--workload marker|motion]
                             [--out FILE.jsonl]

It is the connectivity harness's netem leg (cmuxterm-hq docs/architecture/connectivity-harness)
applied to Mac Screen's own session path: `serve` is the host Mac Screen runs (`CmuxNextMacScreen`),
the device hub's signaling is played by this script the way `hub-session-local.py` does, and the
link is cmux-rd-link over UDP between the namespaces. Only the capture differs: an Xvfb display with
`cmux-rd testapp` drawing the marker, not ScreenCaptureKit.

Each attempt is one fresh session (new keys, new link). Per attempt it records:
  connect_ms      answer handed to the viewer -> host prints {"connected":true}
  first_frame_ms  the viewer's own clock: answer read -> first decoded marker
  g2g_ms          key press -> decoded marker, p50/p95 (input to photon)
  frames_per_s, mbit_per_s
  stalls_ms       with --blip-at: 100 % loss both ways for the selected drop duration, then the time from
                  the first lost key press to the next one that showed
  recovered_after_drop
                  true when a marker arrived after the selected full-drop interval
An attempt that does not connect, or ends before its samples, counts as a failed connect.
"""
import argparse, json, os, select, shutil, subprocess, sys, time

HOST_NS, VIEW_NS = "rdshare-h", "rdshare-v"
HOST_IP, VIEW_IP = "10.77.0.1", "10.77.0.2"


def sh(cmd, check=True):
    return subprocess.run(cmd, shell=True, check=check, capture_output=True, text=True)


# --rate: a bottleneck on both veth ends, in Mbit/s (0: none). A slow path drops a large
# keyframe's tail the way loss alone does not (hq#19915).
RATE_MBIT = 0.0


def netem(rtt, loss, extra=""):
    half = rtt / 2
    if RATE_MBIT > 0:
        extra = f"rate {RATE_MBIT}mbit {extra}"
    for ns, dev in ((HOST_NS, "vh"), (VIEW_NS, "vv")):
        sh(f"ip netns exec {ns} tc qdisc replace dev {dev} root netem delay {half}ms "
           f"loss {loss}% {extra} limit 100000")


def setup(args):
    teardown()
    sh(f"ip netns add {HOST_NS}")
    sh(f"ip netns add {VIEW_NS}")
    sh(f"ip link add vh netns {HOST_NS} type veth peer name vv netns {VIEW_NS}")
    for ns, dev, ip in ((HOST_NS, "vh", HOST_IP), (VIEW_NS, "vv", VIEW_IP)):
        sh(f"ip netns exec {ns} ip link set lo up")
        sh(f"ip netns exec {ns} ip addr add {ip}/24 dev {dev}")
        sh(f"ip netns exec {ns} ip link set {dev} mtu 1500 up")
        sh(f"ip netns exec {ns} ethtool -K {dev} gso off tso off gro off", check=False)
    netem(args.rtt, args.loss)
    disp = args.display
    if not shutil.which("Xvfb"):
        sys.exit("screen-share-netem: Xvfb is not installed; the host has no display to capture")
    xvfb = subprocess.Popen(["ip", "netns", "exec", HOST_NS, "Xvfb", disp, "-screen", "0",
                             "1920x1080x24", "-nolisten", "tcp"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    time.sleep(1.0)
    started(xvfb, "Xvfb " + disp)
    app = subprocess.Popen(["ip", "netns", "exec", HOST_NS, args.bin, "testapp", "--display", disp,
                            "--workload", args.workload],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    time.sleep(1.0)
    started(app, "testapp")
    return [app, xvfb]


def started(proc, what):
    """Stops the run when a helper exited during start-up: every attempt after it would fail
    with the host's "Connection refused" and say nothing of why."""
    if proc.poll() is None:
        return
    err = (proc.stderr.read() if proc.stderr else "").strip()
    teardown()
    sys.exit(f"screen-share-netem: {what} exited {proc.returncode} at start: {err[-400:]}")


def run_status(records):
    """The run's exit status: 1 when no attempt reached a first frame (it measured nothing)."""
    return 0 if any(r.get("ok") for r in records) else 1


def teardown():
    for ns in (HOST_NS, VIEW_NS):
        sh(f"ip netns del {ns}", check=False)


def readline(proc, deadline):
    while True:
        left = deadline - time.time()
        if left <= 0:
            return None
        r, _, _ = select.select([proc.stdout], [], [], left)
        if r:
            return proc.stdout.readline()


def sample_budget(base_samples, drop_s, trigger_s=0):
    """Keep the bench alive through the trigger, full drop, and requested successes."""
    if drop_s is None:
        return base_samples
    # The bench counts each second without a marker as a lost sample. Reserve a
    # conservative ten samples per trigger second, one loss slot per dropped
    # second, then retain the requested successful samples.
    return max(base_samples, int(trigger_s * 10) + int(drop_s) + base_samples)


def recovered_after_drop(drop_s, drop_restored, stalls_ms, host_ended):
    """Only count a post-drop stall when the link was restored and stayed alive."""
    return drop_s is None or (drop_restored and not host_ended and bool(stalls_ms))


STAGES = ("up", "inject", "draw_damage", "gate", "capture", "encode", "send", "down", "decode",
          "total")


def capture_end(line):
    """When a timing-log frame's capture ended: `capture_us`, or `release_us` on an older host
    (before it became the gate's release it was the capture end). None on a non-frame line."""
    return line.get("capture_us", line.get("release_us")) if "encoded_us" in line else None


def stage_samples(samples, log_lines):
    """Per key press, where its time went: the bench's sample_times (viewer, ns) joined with the
    host's CMUX_RD_TIMING_LOG (µs) on the frame's capture end: `capture_us` on both (an older host
    logs it as `release_us`).

      up           key sent -> host read the input datagram
      inject       read -> XTest injected
      draw_damage  injected -> the session saw X damage (the app draws, the X server reports it)
      gate         damage seen -> capture start (settle window, frame-rate cap, encoder busy);
                   a host without `capture_start_us` counts the capture here, to encode start
      capture      capture start -> encode start (XShm readback and I420 convert)
      encode       encode start -> bitstream (OpenH264)
      send         bitstream -> last datagram handed to the carrier (pacer)
      down         last datagram handed over -> frame complete on the viewer
      decode       complete -> decoded
    A sample gets a stage only when both ends are known; every value is in ms."""
    frames = {capture_end(d): d for d in log_lines if capture_end(d) is not None}
    injects = sorted((d for d in log_lines if "inject_us" in d and d.get("recv_us")),
                     key=lambda d: d["recv_us"])
    out = []
    for s in samples:
        sent_us = s["sent_ns"] / 1000
        f = frames.get(s.get("capture_us"))
        inj = next((d for d in injects if d["recv_us"] >= sent_us), None)
        row = {"total": (s["decoded_ns"] - s["sent_ns"]) / 1e6}
        if inj and (f is None or inj["inject_us"] <= capture_end(f)):
            row["up"] = (inj["recv_us"] - sent_us) / 1000
            row["inject"] = (inj["inject_us"] - inj["recv_us"]) / 1000
            if f and f.get("damage_us"):
                row["draw_damage"] = (f["damage_us"] - inj["inject_us"]) / 1000
        if f:
            start = f.get("capture_start_us")
            if f.get("damage_us"):
                row["gate"] = ((start or capture_end(f)) - f["damage_us"]) / 1000
            if start:
                row["capture"] = (capture_end(f) - start) / 1000
            row["encode"] = (f["encoded_us"] - (f.get("encode_start_us") or capture_end(f))) / 1000
            if f.get("sent_us"):
                row["send"] = (f["sent_us"] - f["encoded_us"]) / 1000
                if s.get("complete_ns"):
                    row["down"] = (s["complete_ns"] / 1000 - f["sent_us"]) / 1000
            row["idr"] = f.get("idr")
            row["bytes"] = f.get("encoded_bytes")
        if s.get("complete_ns"):
            row["decode"] = (s["decoded_ns"] - s["complete_ns"]) / 1e6
        out.append(row)
    return out


def stage_table(rows):
    def pct(xs, q):
        xs = sorted(xs)
        return xs[min(len(xs) - 1, int(round(q / 100 * (len(xs) - 1))))] if xs else None
    lines = ["| stage | n | p50 ms | p95 ms |", "| --- | --- | --- | --- |"]
    for st in STAGES:
        xs = [r[st] for r in rows if r.get(st) is not None]
        if xs:
            lines.append(f"| {st} | {len(xs)} | {pct(xs, 50):.2f} | {pct(xs, 95):.2f} |")
    idr = sum(1 for r in rows if r.get("idr"))
    sizes = [r["bytes"] for r in rows if r.get("bytes")]
    lines.append(f"key frames that were IDR: {idr}/{len(rows)}; frame bytes p50 {pct(sizes, 50)}")
    return "\n".join(lines)


def attempt(args, n, drop_s=None):
    rec = {"attempt": n, "rtt_ms": args.rtt, "loss_pct": args.loss, "ok": False}
    rec["row"] = f"drop-{drop_s:g}s" if drop_s is not None else "baseline"
    if drop_s is not None:
        rec["drop_s"] = drop_s
    session = "netem-" + os.urandom(8).hex()
    bench_args = [args.bin, "bench", "--link", "1", "--samples",
                  str(sample_budget(args.samples, drop_s, args.blip_at or 0)),
                  "--input", "key"]
    viewer = subprocess.Popen(["ip", "netns", "exec", HOST_NS if args.one_ns else VIEW_NS, *bench_args], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    host = None
    try:
        line = readline(viewer, time.time() + 10)
        viewer_key = json.loads(line)["key"]
        timing_env = ["env", f"CMUX_RD_TIMING_LOG={args.timing_log}"] if args.timing_log else []
        host = subprocess.Popen(["ip", "netns", "exec", HOST_NS, *timing_env, *args.host_wrap.split(), args.bin, "serve", "--display",
                                 args.display, "--profile", "baseline", *args.serve_arg],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, bufsize=1)
        host.stdin.write(json.dumps({"session": session, "peer_key": viewer_key, "scope": "control",
                                     "stun": [], "display": args.display,
                                     "viewer": {"user": "viewer", "install": "bench"}}) + "\n")
        host.stdin.flush()
        host_key, cands = None, []
        dl = time.time() + 10
        while True:
            # Once the key and a candidate are in, wait only briefly for more: serve with
            # no STUN prints no candidates_done, and the handshake clock is already running.
            line = readline(host, min(dl, time.time() + 0.2) if host_key and cands else dl)
            if not line:
                break
            msg = json.loads(line)
            if "key" in msg:
                host_key = msg["key"]
            elif "candidate" in msg:
                cands.append(msg["candidate"])
            elif msg.get("candidates_done"):
                break
        # Only the veth's own candidate: what a LAN pair or a punched path gives.
        rec["host_candidates"] = cands
        cands = [c for c in cands if HOST_IP in c or args.one_ns] or cands
        t0 = time.time()
        viewer.stdin.write(json.dumps({"session": session, "peer_key": host_key, "stun": [],
                                       "candidates": cands}) + "\n")
        viewer.stdin.flush()
        blip_done = args.blip_at is None or drop_s is None
        blip_until = None
        drop_restored = drop_s is None
        streams = {host.stdout: "host", viewer.stdout: "viewer"}
        deadline = t0 + args.timeout
        while streams and time.time() < deadline:
            if not blip_done and "connect_ms" in rec and time.time() - t0 >= args.blip_at:
                netem(args.rtt, 100)
                blip_until = time.time() + drop_s
                blip_done = True
                rec["blip_s"] = drop_s
            if blip_until and time.time() >= blip_until:
                netem(args.rtt, args.loss)
                blip_until = None
                drop_restored = True
            r, _, _ = select.select(list(streams), [], [], 0.05)
            for s in r:
                line = s.readline()
                if not line:
                    del streams[s]
                    continue
                who = streams[s]
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if who == "viewer" and "candidate" in msg:
                    rec.setdefault("viewer_candidates", []).append(msg["candidate"])
                    host.stdin.write(json.dumps(msg) + "\n")
                    host.stdin.flush()
                elif who == "host" and msg.get("connected"):
                    rec["connect_ms"] = round((time.time() - t0) * 1000, 1)
                elif who == "host" and "path" in msg:
                    rec.setdefault("paths", []).append(msg["path"])
                elif who == "host" and "ended" in msg:
                    rec["host_ended"] = msg["ended"]
                elif who == "viewer" and "g2g_ms" in msg:
                    rec["report"] = msg
                    streams.pop(viewer.stdout, None)
            if "report" in rec:
                break
        if blip_until:
            netem(args.rtt, args.loss)
        rep = rec.get("report")
        if rep:
            rec["first_frame_ms"] = rep.get("first_frame_ms")
            rec["g2g_ms"] = rep.get("g2g_ms")
            rec["lost"] = rep.get("lost")
            rec["stalls_ms"] = rep.get("stalls_ms")
            rec["recovered_after_drop"] = recovered_after_drop(
                drop_s, drop_restored, rec["stalls_ms"], rec.get("host_ended")
            )
            rec["frames_per_s"] = rep.get("frames_per_s")
            rec["mbit_per_s"] = rep.get("mbit_per_s")
            rec["ended"] = rep.get("ended")
            rec["decode_ms"] = rep.get("decode_ms")
            if args.timing_log:
                rec["sample_times"] = rep.get("sample_times")
            rec["ok"] = bool(rep.get("g2g_ms")) and "connect_ms" in rec
            rec.pop("report")
        else:
            err = viewer.stderr.read() if viewer.poll() is not None else ""
            rec["error"] = err.strip()[-400:]
            if args.debug and host and host.poll() is not None:
                rec["host_stderr"] = host.stderr.read().strip()[-1500:]
    except Exception as e:  # noqa: BLE001 - a broken attempt is a failed attempt
        rec["error"] = repr(e)
    finally:
        for p in (viewer, host):
            if p and p.poll() is None:
                try:
                    p.stdin.write(json.dumps({"stop": True}) + "\n")
                    p.stdin.flush()
                except Exception:  # noqa: BLE001
                    pass
        for p in (viewer, host):
            if p:
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bin")
    ap.add_argument("--rtt", type=float, default=50)
    ap.add_argument("--loss", type=float, default=0)
    ap.add_argument("--rate", type=float, default=0,
                    help="link rate in Mbit/s on both ends (default: no cap)")
    ap.add_argument("--attempts", type=int, default=50)
    ap.add_argument("--samples", type=int, default=20)
    ap.add_argument("--workload", default="marker")
    ap.add_argument("--display", default=":173")
    ap.add_argument("--blip-at", type=float, default=None)
    ap.add_argument("--blip-s", type=float, default=2)
    ap.add_argument(
        "--drop-seconds",
        type=float,
        action="append",
        default=None,
        metavar="SECONDS",
        help="run a fresh-session row for each full-drop duration (repeat for 10 and 60)",
    )
    ap.add_argument("--timeout", type=float, default=90)
    ap.add_argument("--serve-arg", action="append", default=[])
    ap.add_argument("--out")
    ap.add_argument("--debug", action="store_true")
    ap.add_argument("--one-ns", action="store_true")
    ap.add_argument("--host-wrap", default="")
    ap.add_argument("--timing-log", help="the host's CMUX_RD_TIMING_LOG; with it each attempt keeps "
                    "the bench's sample_times and the run ends with the per-stage table (one machine, "
                    "one CLOCK_MONOTONIC: the join needs no clock probe)")
    args = ap.parse_args()
    global RATE_MBIT
    RATE_MBIT = args.rate
    if args.drop_seconds is not None and args.blip_at is None:
        ap.error("--drop-seconds requires --blip-at")
    drop_seconds = args.drop_seconds
    if drop_seconds is None:
        drop_seconds = [args.blip_s] if args.blip_at is not None else [None]
    if any(duration <= 0 for duration in drop_seconds if duration is not None):
        ap.error("drop durations must be positive")
    if args.blip_at is not None and any(duration is not None for duration in drop_seconds):
        # Leave enough wall time for the full loss interval and one recovery sample.
        args.timeout = max(args.timeout, args.blip_at + max(drop_seconds) + 30)
    procs = setup(args)
    out = open(args.out, "a") if args.out else None
    samples = []
    records = []
    try:
        n = 0
        for drop_s in drop_seconds:
            for _ in range(args.attempts):
                n += 1
                rec = attempt(args, n, drop_s)
                records.append(rec)
                samples += rec.get("sample_times") or []
                line = json.dumps(rec)
                print(line, flush=True)
                if out:
                    out.write(line + "\n")
                    out.flush()
        if args.timing_log and samples:
            with open(args.timing_log) as f:
                log = [json.loads(line) for line in f if line.startswith("{")]
            rows = stage_samples(samples, log)
            print(stage_table(rows), flush=True)
            if out:
                out.write(json.dumps({"stages": rows}) + "\n")
    finally:
        for p in procs:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        teardown()
    if run_status(records):
        sys.exit(f"screen-share-netem: none of {len(records)} attempts reached a first frame")


if __name__ == "__main__":
    main()
