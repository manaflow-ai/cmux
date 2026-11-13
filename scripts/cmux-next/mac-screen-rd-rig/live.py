#!/usr/bin/env python3
"""Mac Screen between two real Macs through the device hub, end to end (both builds of a
comparison run the same steps). The host and viewer are tagged builds signed in as the agent
test account, each started from its Mac's own cmux (run.sh), so the host inherits cmux's
Screen Recording and Accessibility grants.

  live.py --tag TAG --host SSH --viewer SSH --out DIR [--relay-only] [--input] [--seconds 20]
          [--motion MARKER_BIN]

Steps: launch both apps (unless their sockets answer), wait for both to be signed in, share
the host, connect the viewer (full control), approve on the host (always), wait for a picture,
then sample the viewer's stats once a second (path, round trip, fps, throughput, drops). With
--input it clicks through the session (debug.mac_screen input) while InputProbe on the host
logs what arrives, and records window snapshots of the viewer for a video. --relay-only runs
the session with the viewer's Relay Only on. Writes DIR/result.json and the pulled files.
"""
import argparse, json, os, shlex, subprocess, sys, time

p = argparse.ArgumentParser()
p.add_argument("--tag", required=True)
p.add_argument("--host", required=True)
p.add_argument("--viewer", required=True)
p.add_argument("--out", required=True)
p.add_argument("--relay-only", action="store_true")
p.add_argument("--input", action="store_true")
p.add_argument("--seconds", type=int, default=20)
p.add_argument("--motion", help="the marker app on the host, run with --motion during the stats")
p.add_argument("--host-frame", default="1300,80,600,500")
p.add_argument("--viewer-frame", default="0,0,1500,950")
o = p.parse_args()
os.makedirs(o.out, exist_ok=True)
result = {"tag": o.tag, "host": o.host, "viewer": o.viewer, "relay_only": o.relay_only, "steps": []}


def log(step, ok, **detail):
    result["steps"].append({"step": step, "ok": ok, **detail})
    print(("PASS " if ok else "FAIL ") + step, json.dumps(detail)[:400], flush=True)
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(result, f, indent=1)


def ssh(host, command, timeout=120):
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", host, command], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def mini(host, *args, timeout=120):
    return ssh(host, "python3 ~/rd-hub-rig/mini.py " + " ".join(shlex.quote(a) for a in (o.tag, *args)), timeout)


def rpc(host, method, params=None):
    out = mini(host, "rpc", method, json.dumps(params or {}))
    try:
        return json.loads(out.splitlines()[-1]) if out else {"error": "no reply"}
    except (ValueError, IndexError):
        return {"error": out[-300:]}


def until(seconds, probe, step=1.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(step)  # polling another Mac's socket over SSH
    return None


def launch(host, role, frame):
    state = rpc(host, "debug.device_hub", {"action": "state"})
    if "error" not in state:
        return
    command = f"zsh ~/rd-hub-rig/run.sh {o.tag} {role} {frame}"
    started = ssh(host, f"~/.local/bin/cmux new-workspace --name {shlex.quote(f'rd-rig {role} {o.tag}')} "
                        f"--command {shlex.quote(command)} --focus false 2>&1")
    if "OK workspace" in started:
        return
    if role == "host":
        sys.exit(f"the host needs its Mac's cmux (for the capture grants): {started}")
    # A viewer needs no grants: LaunchServices starts it in the GUI session, in the background.
    ssh(host, f"zsh ~/rd-hub-rig/run.sh {o.tag} {role} {frame} --open")


if o.relay_only:
    mini(o.viewer, "relay-only", "on")
launch(o.host, "host", o.host_frame)
launch(o.viewer, "viewer", o.viewer_frame)


def signed_in(host):
    s = rpc(host, "debug.device_hub", {"action": "state"})
    return s if s.get("signed_in") and s.get("this_device") and "connected" in str(s.get("connection", "")).lower() else None


host_state = until(120, lambda: signed_in(o.host), 2)
viewer_state = until(120, lambda: signed_in(o.viewer), 2)
log("both signed in to the hub", bool(host_state and viewer_state),
    host_device=(host_state or {}).get("this_device"), viewer_device=(viewer_state or {}).get("this_device"))
if not (host_state and viewer_state):
    sys.exit(1)
host_id = host_state["this_device"]

shared = rpc(o.host, "debug.device_hub", {"action": "set_shared", "shared": True})
share = rpc(o.host, "debug.mac_screen", {"action": "state"}).get("share", {})
log("host shares this Mac", "error" not in shared and share.get("screen_recording") is True, share=share)

# One connect: it opens a Mac Screen tab even when it answers "no pane" (no pane was named), so
# a retry would open a second tab that replaces the first session. The new tab is followed.
def tab_keys():
    return {t["tab"] for t in rpc(o.viewer, "debug.mac_screen", {"action": "state"}).get("tabs") or []}


before = tab_keys()
opened = rpc(o.viewer, "debug.device_hub", {"action": "connect", "device": host_id, "scope": "full"})
new_tabs = until(15, lambda: tab_keys() - before, 1) or set()
log("viewer opens a Mac Screen tab", len(new_tabs) == 1, reply=opened, tabs=sorted(new_tabs))
if len(new_tabs) != 1:
    sys.exit(1)
our_tab = next(iter(new_tabs))


def tab():
    rows = rpc(o.viewer, "debug.mac_screen", {"action": "state", "tab": our_tab}).get("tabs") or []
    return rows[0] if rows else {}


def approved_and_streaming():
    for request in rpc(o.host, "debug.device_hub", {"action": "state"}).get("pending_requests") or []:
        rpc(o.host, "debug.device_hub", {"action": "decide", "session": request["id"], "choice": "always_full"})
    row = tab()
    return row if row.get("phase") == "connected" and row.get("has_frame") else None


started = time.time()
row = until(90, approved_and_streaming, 1)
log("viewer shows the host's screen", bool(row), seconds=round(time.time() - started, 1), tab=row)
if not row:
    sys.exit(1)

motion = None
if o.motion:
    ssh(o.host, f"~/.local/bin/cmux new-workspace --name {shlex.quote('rd-rig motion')} "
                f"--command {shlex.quote(o.motion + ' --motion')} --focus false")
    time.sleep(3)  # the marker window's first frames

frames_job = None
if o.input:
    # A video: window snapshots of the viewer while the clicks run.
    frames_job = subprocess.Popen(["ssh", "-o", "BatchMode=yes", o.viewer,
                                   f"python3 ~/rd-hub-rig/mini.py {o.tag} frames ~/rd-hub-rig/frames-{o.tag} 14 8"],
                                  stdout=subprocess.PIPE, text=True)

samples = []
for _ in range(o.seconds):
    t = tab()
    samples.append({k: t.get(k) for k in ("path", "rtt_ms", "fps", "kilobytes_per_second", "frames_received",
                                          "frames_decoded", "frames_dropped", "frame", "encoding", "target_fps")})
    time.sleep(1)  # one sample a second
fps = sorted(s["fps"] for s in samples if isinstance(s.get("fps"), (int, float)))
rtt = sorted(s["rtt_ms"] for s in samples if isinstance(s.get("rtt_ms"), (int, float)))
paths = sorted({s.get("path") for s in samples if s.get("path")})
median = lambda xs: xs[len(xs) // 2] if xs else None
log("stats", bool(fps), paths=paths, fps_median=median(fps), fps_min=fps[0] if fps else None,
    rtt_median=median(rtt), rtt_max=rtt[-1] if rtt else None, samples=samples)

if o.input:
    size = (row.get("frame") or "1920x1080").split("x")
    x, y = int(size[0]) // 2, int(size[1]) // 2
    clicks = [json.loads(line) for line in mini(o.viewer, "clicks", "10", "400", str(x), str(y), timeout=60).splitlines() if line.startswith("{")]
    time.sleep(1)  # the last click's trip
    probe = [json.loads(line) for line in ssh(o.host, f"cat ~/rd-hub-rig/probe-{o.tag}.jsonl").splitlines() if line.startswith("{")]
    downs = [e["t"] * 1000 for e in probe if e.get("kind") == "left-down"]
    # Each Mac's offset from NTP, so the two clocks can be compared.
    def offset(host):
        out = ssh(host, "sntp -t 2 time.apple.com 2>/dev/null | tail -1")
        try:
            return float(out.split()[0]) * 1000
        except (ValueError, IndexError):
            return None
    host_offset, viewer_offset = offset(o.host), offset(o.viewer)
    latencies = []
    for click in clicks:
        sent = click.get("sent_ms")
        after = [d for d in downs if sent and d >= sent - 50]
        if sent and after:
            raw = after[0] - sent
            # Host clock + host offset = true time; the same for the viewer.
            if host_offset is not None and viewer_offset is not None:
                raw += host_offset - viewer_offset
            latencies.append(round(raw, 1))
    log("clicks reach the host", len(latencies) >= 8, clicks=len(clicks), received=len(downs), latencies_ms=latencies,
        host_ntp_offset_ms=host_offset, viewer_ntp_offset_ms=viewer_offset)
    if frames_job:
        frames_job.wait(timeout=60)
        subprocess.run(["rsync", "-a", f"{o.viewer}:rd-hub-rig/frames-{o.tag}/", os.path.join(o.out, "frames")], check=False)
    subprocess.run(["scp", "-q", f"{o.host}:rd-hub-rig/probe-{o.tag}.jsonl", o.out], check=False)

# The snapshot goes in the viewer's own ~/rd-hub-rig, never a guessable /tmp name another account there could plant.
viewer_home = ssh(o.viewer, 'printf %s "$HOME"')
snap = rpc(o.viewer, "debug.window_snapshot", {"path": f"{viewer_home}/rd-hub-rig/viewer-{o.tag}.png"})
subprocess.run(["scp", "-q", f"{o.viewer}:rd-hub-rig/viewer-{o.tag}.png", os.path.join(o.out, "viewer.png")], check=False)
log("viewer snapshot", "error" not in snap, reply=snap)
if "--quit" in sys.argv[1:] or os.environ.get("RD_RIG_QUIT") == "1":
    for host in (o.viewer, o.host):
        rpc(host, "action.run", {"id": "quitEndEverything"})
print(json.dumps({"out": o.out}))
