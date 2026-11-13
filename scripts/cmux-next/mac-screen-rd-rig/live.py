#!/usr/bin/env python3
"""Mac Screen between two real Macs through the device hub, end to end (both builds of a
comparison run the same steps). The host and viewer are tagged builds signed in as the agent
test account, each started from its Mac's own cmux (run.sh), so the host inherits cmux's
Screen Recording and Accessibility grants.

  live.py --tag TAG --host SSH --viewer SSH --out DIR [--relay-only] [--input] [--seconds 20]
          [--motion MARKER_BIN] --source-readiness SOURCE_READINESS.json

Steps: launch both apps (unless their sockets answer), wait for both to be signed in, share
the host, connect the viewer (full control), approve on the host (always), wait for a picture,
then sample the viewer's stats once a second (path, explicit transport marker, round trip, fps, throughput, drops). With
--input it clicks through the session (debug.mac_screen input) while InputProbe on the host
logs what arrives, and records window snapshots of the viewer for a video. --relay-only runs
the session with the viewer's Relay Only on. The source readiness JSON must be fresh for this run;
the adapter invokes cmux-rd's common presented observer only after it matches the selected pane's
window, approved hub session/scope, viewport geometry, and an explicit transport marker
(`rd_wg`, `link`, or `webrtc`). A generic `path` never proves transport. Missing proof or
an incomplete observer receipt leaves `comparison_ready=false`. Writes DIR/result.json and the
pulled files.
"""
import argparse, hashlib, json, os, shlex, subprocess, sys, time
import select
from pathlib import Path
import math
import re

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
p.add_argument("--source-readiness", help="fresh JSON {nonce, ready, issued_unix_ms} from the scene observer")
p.add_argument("--observer-bin", default="~/rd-hub-rig/cmux-rd",
               help="cmux-rd binary on the viewer, with `observe` support")
p.add_argument("--display", default="main", help="viewer display; only main is supported by this adapter")
o = p.parse_args()
os.makedirs(o.out, exist_ok=True)
run_started_ms = time.time_ns() // 1_000_000
result = {"tag": o.tag, "host": o.host, "viewer": o.viewer, "relay_only": o.relay_only,
          "comparison_ready": False, "steps": []}


def log(step, ok, **detail):
    result["steps"].append({"step": step, "ok": ok, **detail})
    print(("PASS " if ok else "FAIL ") + step, json.dumps(detail)[:400], flush=True)
    with open(os.path.join(o.out, "result.json"), "w") as f:
        json.dump(result, f, indent=1)


def ssh(host, command, timeout=120):
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", host, command], capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()


def ssh_background(host, command):
    """Start one remote command whose lifetime is owned by this rig process."""
    return subprocess.Popen(["ssh", "-o", "BatchMode=yes", host, command],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


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


def source_readiness():
    """Load the scene's fresh nonce; an absent/stale proof must fail closed."""
    if not o.source_readiness:
        return {"ok": False, "error": "source readiness proof was not supplied"}
    try:
        proof = json.loads(Path(o.source_readiness).read_text())
    except (OSError, ValueError) as error:
        return {"ok": False, "error": f"source readiness proof unreadable: {error}"}
    nonce = proof.get("nonce")
    issued = proof.get("issued_unix_ms")
    if (proof.get("ready") is not True or not isinstance(nonce, str) or
            not re.fullmatch(r"[0-9a-f]{32}", nonce) or type(issued) not in (int, float) or
            not math.isfinite(issued)):
        return {"ok": False, "error": "source readiness needs ready=true, lowercase nonce, and finite issued_unix_ms"}
    now_ms = time.time_ns() / 1_000_000
    if issued < run_started_ms or issued > now_ms + 1000:
        return {"ok": False, "error": "source readiness nonce is stale", "issued_unix_ms": issued}
    return {"ok": True, "nonce_sha256": hashlib.sha256(nonce.encode()).hexdigest(),
            "nonce": nonce, "issued_unix_ms": issued,
            "marker_origin": proof.get("marker_origin"), "cell_size": proof.get("cell_size")}


def pane_attestation(row, host_id):
    """Bind the observer to the approved production pane and an explicit transport marker.

    `path` is a diagnostic label only. The transport marker is emitted by the session's
    DEBUG getter, so this adapter never turns a generic path into an rd/1 claim.
    """
    errors = []
    window_pid = row.get("window_pid")
    window_id = row.get("window_id")
    if (row.get("window_attestation") is not True or type(window_pid) is not int or window_pid <= 0 or
            type(window_id) is not int or window_id <= 0):
        errors.append("selected pane has no valid window attestation")
    if not isinstance(row.get("content_rect_points"), dict) or row.get("geometry_origin") != "bottom-left":
        errors.append("selected pane has no AppKit bottom-left content geometry")
    if row.get("host_device") != host_id:
        errors.append("selected pane is bound to a different host device")
    if not row.get("hub_session"):
        errors.append("selected pane has no approved hub session")
    if row.get("session_scope") != "full":
        errors.append("selected pane is not the approved full-control scope")
    if row.get("phase") != "connected" or row.get("has_frame") is not True:
        errors.append("selected pane is not connected with a frame")
    if row.get("transport") not in {"rd_wg", "link", "webrtc"}:
        errors.append("selected validated transport carrier is missing or invalid")
    if row.get("window_on_primary_display") is not True:
        errors.append("selected pane is not proven to be on the primary display")
    if not rect_inside(row.get("window_frame_points"), row.get("primary_screen_frame_points")):
        errors.append("selected window is not wholly inside the primary display")
    return {"ok": not errors, "errors": errors,
            "window_pid": window_pid, "window_id": window_id,
            "window_frame_points": row.get("window_frame_points"),
            "content_rect_points": row.get("content_rect_points"),
            "screen_frame_points": row.get("screen_frame_points"),
            "primary_screen_frame_points": row.get("primary_screen_frame_points"),
            "window_display_id": row.get("window_display_id"),
            "primary_display_id": row.get("primary_display_id"),
            "window_on_primary_display": row.get("window_on_primary_display"),
            "geometry_coordinate_space": row.get("geometry_coordinate_space"),
            "geometry_origin": row.get("geometry_origin"),
            "host_device": row.get("host_device"), "hub_session": row.get("hub_session"),
            "session_scope": row.get("session_scope"), "transport": row.get("transport"),
            "path_diagnostic": row.get("path")}


def rect_inside(inner, outer):
    if not isinstance(inner, dict) or not isinstance(outer, dict):
        return False
    vals = tuple(inner.get(k) for k in ("x", "y", "width", "height")) + tuple(outer.get(k) for k in ("x", "y", "width", "height"))
    if not all(type(v) in (int, float) and math.isfinite(v) for v in vals):
        return False
    ix, iy, iw, ih, ox, oy, ow, oh = vals
    return min(iw, ih, ow, oh) > 0 and ox <= ix and oy <= iy and ix + iw <= ox + ow and iy + ih <= oy + oh


def geometry_matches(received, expected, screen):
    """Compare Rust's top-left [x,y,w,h] points with AppKit bottom-left points."""
    if isinstance(received, dict):
        received = [received.get(k) for k in ("x", "y", "width", "height")]
    if not isinstance(expected, dict) or not isinstance(received, (list, tuple)) or len(received) != 4:
        return False
    expected = [expected.get(k) for k in ("x", "y", "width", "height")]
    if not isinstance(screen, dict):
        return False
    sx, sy, sw, sh = (screen.get(k) for k in ("x", "y", "width", "height"))
    if not all(type(v) in (int, float) and math.isfinite(v) for v in (*received, *expected, sx, sy, sw, sh)):
        return False
    if min(sw, sh, received[2], received[3], expected[2], expected[3]) <= 0:
        return False
    # CGWindow bounds use a top-left origin; AppKit uses a bottom-left origin.
    expected[1] = sy + sh - expected[1] - expected[3]
    return all(abs(float(a) - float(b)) <= 0.5 for a, b in zip(received, expected))


def viewport_inside_window(row):
    window = row.get("window_frame_points")
    viewport = row.get("content_rect_points")
    if not isinstance(window, dict) or not isinstance(viewport, dict):
        return False
    wx, wy, ww, wh = (window.get(k) for k in ("x", "y", "width", "height"))
    vx, vy, vw, vh = (viewport.get(k) for k in ("x", "y", "width", "height"))
    vals = (wx, wy, ww, wh, vx, vy, vw, vh)
    if not all(type(v) in (int, float) and math.isfinite(v) for v in vals) or min(ww, wh, vw, vh) <= 0:
        return False
    return wx <= vx and wy <= vy and vx + vw <= wx + ww and vy + vh <= wy + wh


def observe_pane(row, host_id):
    """Run cmux-rd's common presented observer only after source/pane evidence agree."""
    source = source_readiness()
    pane = pane_attestation(row, host_id)
    cell_size = source.get("cell_size")
    ready = (o.display == "main" and source["ok"] and pane["ok"] and viewport_inside_window(row) and
             isinstance(source.get("marker_origin"), str) and
             type(cell_size) in (int, float) and math.isfinite(cell_size) and int(cell_size) == cell_size and
             2 <= int(cell_size) <= 1024)
    evidence = {"comparison_ready": False, "source": source, "pane": pane}
    if ready:
        viewer_home = ssh(o.viewer, 'printf %s "$HOME"')
        root = f"{viewer_home}/rd-hub-rig"
        run_template = f"{root}/presented-{o.tag}.XXXXXX"
        run_dir = ssh(o.viewer, f"mktemp -d {shlex.quote(run_template)}", timeout=10)
        if not run_dir.startswith(root + "/"):
            evidence["observer"] = {"error": "viewer returned an invalid observer run directory"}
            return evidence
        start_file = f"{run_dir}/start"
        observer_bin = o.observer_bin
        observer_path = f"{viewer_home}/{observer_bin[2:]}" if observer_bin.startswith("~/") else observer_bin
        observer_word = shlex.quote(observer_path)
        observer_cmd = [observer_word, "observe", "--mode", "passive",
                        "--pid", str(int(pane["window_pid"])), "--window", str(int(pane["window_id"])),
                        "--display", o.display, "--marker-origin", source["marker_origin"],
                        "--cell-size", str(int(source["cell_size"])), "--expected-nonce", source["nonce"],
                        "--start-file", start_file, "--duration-s", "1", "--interval-ms", "500"]
        command = " ".join([observer_cmd[0]] + [shlex.quote(part) for part in observer_cmd[1:]])
        if not o.motion:
            evidence["observer"] = {"error": "source/start trigger is required; pass --motion MARKER_BIN"}
            return evidence
        host_home = ssh(o.host, 'printf %s "$HOME"')
        host_root = f"{host_home}/rd-hub-rig"
        source_dir = ssh(o.host, f"mktemp -d {shlex.quote(host_root + f'/source-{o.tag}.XXXXXX')}", timeout=10)
        if not source_dir.startswith(host_root + "/"):
            evidence["observer"] = {"error": "host returned an invalid source run directory"}
            return evidence
        source_pid_file = f"{source_dir}/pid"
        cleanup_errors = []

        def stop_source():
            cleanup = (
                f"p=$(cat {shlex.quote(source_pid_file)} 2>/dev/null || true); "
                f"case \"$p\" in ''|*[!0-9]*) ;; *) kill \"$p\" 2>/dev/null || true ;; esac; "
                f"rm -f {shlex.quote(source_pid_file)}"
            )
            try:
                ssh(o.host, cleanup, timeout=10)
            except (OSError, subprocess.SubprocessError) as error:
                cleanup_errors.append(str(error))

        observer = ssh_background(o.viewer, f"printf 'OBSERVER_READY\\n'; exec {command}")
        # The passive observer waits for a caller-created start signal. The
        # readiness line proves only that the remote command was launched; the
        # receipt remains the authority for capture validity. Start the owned
        # source marker after launch, then create the signal in this unique run
        # directory.
        ready_line = ""
        if observer.stdout and select.select([observer.stdout], [], [], 10)[0]:
            ready_line = observer.stdout.readline().strip()
        if ready_line != "OBSERVER_READY":
            observer.terminate()
            try:
                observer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait(timeout=5)
            evidence["observer"] = {"error": "observer did not report command readiness", "ready_line": ready_line}
            return evidence
        motion_script = (f"export CMUX_SOURCE_NONCE={shlex.quote(source['nonce'])} "
                         f"CMUX_SOURCE_MARKER_ORIGIN={shlex.quote(source['marker_origin'])} "
                         f"CMUX_SOURCE_CELL_SIZE={int(source['cell_size'])}; "
                         f"printf '%s' $$ > {shlex.quote(source_pid_file)}; "
                         f"exec {shlex.quote(o.motion)} --motion")
        motion_command = f"~/.local/bin/cmux new-workspace --name {shlex.quote(f'rd-rig motion {o.tag}')} " \
                         f"--command {shlex.quote('sh -c ' + shlex.quote(motion_script))} --focus false"
        try:
            started = ssh(o.host, motion_command)
        except (OSError, subprocess.SubprocessError) as error:
            stop_source()
            observer.terminate()
            evidence["observer"] = {"error": "source/start trigger failed", "trigger_error": str(error),
                                     "cleanup_errors": cleanup_errors}
            return evidence
        if "OK workspace" not in started:
            stop_source()
            observer.terminate()
            try:
                observer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait(timeout=5)
            evidence["observer"] = {"error": "source/start trigger failed", "trigger_reply": started,
                                     "cleanup_errors": cleanup_errors}
            return evidence
        try:
            source_ready = ssh(o.host, f"test -s {shlex.quote(source_pid_file)} && printf READY", timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            source_ready = ""
            cleanup_errors.append(str(error))
        if source_ready != "READY":
            stop_source()
            observer.terminate()
            try:
                observer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait(timeout=5)
            evidence["observer"] = {"error": "source trigger did not publish an owned pid",
                                     "cleanup_errors": cleanup_errors}
            return evidence
        try:
            signaled = ssh(o.viewer, f"touch {shlex.quote(start_file)} && printf READY", timeout=10)
        except (OSError, subprocess.SubprocessError) as error:
            signaled = ""
            cleanup_errors.append(str(error))
        if signaled != "READY":
            stop_source()
            observer.terminate()
            try:
                observer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait(timeout=5)
            evidence["observer"] = {"error": "observer start signal could not be created", "signal_reply": signaled,
                                     "cleanup_errors": cleanup_errors}
            return evidence
        try:
            observer.wait(timeout=30)
            raw = observer.stdout.read() if observer.stdout else ""
            err = observer.stderr.read() if observer.stderr else ""
        except subprocess.TimeoutExpired:
            observer.terminate()
            try:
                observer.wait(timeout=5)
            except subprocess.TimeoutExpired:
                observer.kill()
                observer.wait(timeout=5)
            raw = observer.stdout.read() if observer.stdout else ""
            err = observer.stderr.read() if observer.stderr else ""
            raw = raw or err or "observer timed out waiting for a presented marker"
        except (OSError, subprocess.SubprocessError) as error:
            stop_source()
            observer.terminate()
            evidence["observer"] = {"error": "observer process failed", "detail": str(error),
                                     "cleanup_errors": cleanup_errors}
            return evidence
        stop_source()
        try:
            receipt = json.loads(raw.splitlines()[-1])
        except (ValueError, IndexError):
            receipt = {"error": raw[-1000:]}
        evidence["observer"] = receipt
        if cleanup_errors:
            evidence["observer_cleanup_errors"] = cleanup_errors
        evidence["observer_command"] = command
        valid = (receipt.get("schema") == "cmux.presented-marker-series/2" and
                 receipt.get("complete") is True and receipt.get("host_identity_verified") is True and
                 receipt.get("nonce_observed") is True and receipt.get("expected_nonce") == source["nonce"] and
                 type(receipt.get("pid")) is int and receipt["pid"] == int(pane["window_pid"]) and
                 type(receipt.get("window")) is int and receipt["window"] == int(pane["window_id"]) and
                 geometry_matches(receipt.get("window_geometry_points"), pane.get("window_frame_points"), pane.get("primary_screen_frame_points")) and
                 type(receipt.get("first_changed_marker_ms")) in (int, float) and
                 math.isfinite(receipt["first_changed_marker_ms"]))
        evidence["comparison_ready"] = valid and not cleanup_errors
    else:
        evidence["observer"] = {"skipped": "source, pane, marker, geometry, or supported-display readiness was incomplete",
                                 "display": o.display}
    return evidence


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

readiness = observe_pane(row, host_id)
result["comparison_ready"] = bool(readiness.get("comparison_ready"))
log("pane/source observer is bound", result["comparison_ready"], **readiness)
if not result["comparison_ready"]:
    log("comparison measurement blocked", False, reason="missing same-session pane, transport, or fresh source nonce")

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

# The presented observer returns a verified receipt rather than a screenshot. A screenshot
# can still be requested separately for visual evidence, but it never upgrades readiness.
log("presented observer receipt", result["comparison_ready"],
    receipt=readiness.get("observer"), skipped=(not result["comparison_ready"]))
if "--quit" in sys.argv[1:] or os.environ.get("RD_RIG_QUIT") == "1":
    for host in (o.viewer, o.host):
        rpc(host, "action.run", {"id": "quitEndEverything"})
print(json.dumps({"out": o.out}))
