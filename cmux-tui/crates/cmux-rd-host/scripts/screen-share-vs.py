#!/usr/bin/env python3
"""cmux Mac Screen against macOS Screen Sharing on the same two Macs, the same link and the
same method: the marker app (mac-marker/main.swift) on the shared Mac, timestamps on the
viewing Mac at the decoded frame that shows it. One table:

  first_frame_ms   connect start -> first decoded frame that shows the marker (p50/p95 of trials)
  key_to_frame_ms  key press sent on the viewer -> decoded frame showing its effect (p50/p95)
  fps              distinct marker values decoded per second while the marker counts every
                   display refresh over a full-screen animation (`--tick --motion`)
  rtt_ms           the link's UDP round trip (min/p50), from the clock probe

and, for cmux under motion (the fps trials), the received Mbps (video and FEC datagram bytes
into the viewer: run average and peak second) and the host's smoothed datagram loss %.

plus, for cmux, where each key press's time went (host CMUX_RD_TIMING_LOG joined with the
bench's per-sample times; the two clocks are tied by an NTP-style UDP probe, min-RTT sample):

  up         viewer send -> host read the input datagram (network up + host read wait)
  inject     host read -> input injected (CGEvent)
  draw       injected -> the display showed the change (marker app + WindowServer + refresh)
  sck        display showed it -> ScreenCaptureKit handed the frame over
  gate       handed over -> encode started (frame pacing)
  encode     encode
  send       encode end -> last datagram handed to the link
  down       last datagram sent -> frame complete on the viewer (network down + transfer)
  decode     frame complete -> decoded (VideoToolbox)

The cmux leg is the product's session path: `cmux-rd serve` (what `cmux rd serve` runs in
the app) and `cmux-rd bench --link 1` (the secure link, UDP direct), with the device hub's
signaling played by this script as screen-share-netem.py does. The macOS Screen Sharing leg is
an RFB client (the cua-vnc client, imported from --cua-vnc) on port 5900 asking only for the
marker's strip: Screen Sharing.app's own viewer (and its high-performance mode) is not used, and
asking for a strip instead of the whole screen favours it, so its numbers are a lower bound on
its latency and an upper bound on its frame rate.

Both legs exclude the viewer's present (about one refresh for either).

Subcommands (each Mac gets this file and bin/ under ROOT, default ~/cmux-rd-test):
  run         the orchestrator, from any Mac that reaches both with `reach NAME CMD` (or ssh)
  rig         on the shared Mac, inside an app that holds Screen Recording and Accessibility
              (a terminal in cmux NEXT: `cmux workspace create -- /usr/bin/python3 ... rig`);
              serves ROOT/state/rig.sock (0700 dir) with a fixed command set
  rig-call    on the shared Mac, over SSH: one rig command, stdio bridged
  clock-serve / clock-probe   the UDP clock probe
  rfb-bench   on the viewing Mac: the macOS Screen Sharing leg

  screen-share-vs.py run --host cmux20 --viewer cmux17 --host-ip 172.20.21.250 \
      --trials 10 --samples 30 --stacks cmux,apple --out results.jsonl

`--source synthetic` needs no rig, marker app or grant, so any two Macs reached over ssh do:
the shared Mac runs `cmux-rd serve --source synthetic-still` (key trials: viewer input bumps
the generated marker) or `--source synthetic-tick` (fps trials: moving bars, the marker counts
every frame) straight from the orchestrator; only the cmux leg runs.

  screen-share-vs.py run --source synthetic --stacks cmux --via ssh --host A --viewer B \
      --host-ip 10.0.0.5 --bin target/release/cmux-rd --trials 5 --samples 30

The macOS Screen Sharing leg logs in with the shared Mac's account (security type 30): it reads
the user from VNC_USERNAME and the password from VNC_PASSWORD_FILE (a 0600 file on the viewing
Mac) and never from argv. Without them it is skipped and the table says so.
"""
import argparse
import ipaddress
import json
import os
import queue
import select
import shlex
import signal
import socket
import statistics
import struct
import subprocess
import sys
import threading
import time

MONO = time.CLOCK_MONOTONIC  # the clock cmux-rd's now_ns() reads (clock.rs)
KEYSYM_A = 0x61
CELLS = 20
GUARD = (True, False, True, False)


def motion_link(series):
    """Received Mbps for each second of a `--input none` run (video and FEC datagram bytes into
    the viewer) and the host's smoothed datagram loss (its `stats` control, computed from the
    viewer's feedback), one value a second."""
    mbps = [b["bytes"] * 8 / max(b.get("duration_ms") or 1000, 1) / 1e3 for b in series]
    loss = [(b.get("host_stats") or {}).get("loss_pct") for b in series]
    loss = [x for x in loss if x is not None]
    kbps = [(b.get("host_stats") or {}).get("kbps") for b in series]
    kbps = [x for x in kbps if x is not None]
    return {
        "mbit_per_s_peak": round(max(mbps), 2) if mbps else None,
        "mbit_per_s_series": [round(x, 2) for x in mbps],
        "loss_pct_mean": round(statistics.mean(loss), 3) if loss else None,
        "loss_pct_max": round(max(loss), 3) if loss else None,
        "target_kbps_last": kbps[-1] if kbps else None,
        "target_kbps_series": kbps,
    }


def host_frames(lines, cap_fps):
    """Where a tick run's frames went, from the host's CMUX_RD_TIMING_LOG frame lines (µs on
    the host clock): how many the host encoded a second against the cap, the gaps between
    them, how long each waited at the frame gate (damage to release) and in the encoder
    (release to encoded), and the encoder's output a second (encoded bytes, before packets and
    FEC), to set beside the controller's target (`target_kbps_series`)."""
    frames = sorted((x for x in lines if x.get("release_us") is not None),
                    key=lambda x: x["release_us"])
    if len(frames) < 2:
        return {"frames": len(frames)}
    t0 = frames[0]["release_us"]
    span_s = (frames[-1]["release_us"] - t0) / 1e6
    slot_ms = 1000.0 / max(cap_fps, 1)
    gaps = [(b["release_us"] - a["release_us"]) / 1e3 for a, b in zip(frames, frames[1:])]
    gate = [(x["release_us"] - x["damage_us"]) / 1e3 for x in frames if x.get("damage_us")]
    encode = [(x["encoded_us"] - x["release_us"]) / 1e3 for x in frames if x.get("encoded_us")]
    seconds = int(span_s) + 1
    kbps = [0.0] * seconds
    count = [0] * seconds
    for x in frames:
        s = min(int((x["release_us"] - t0) / 1e6), seconds - 1)
        kbps[s] += x.get("encoded_bytes", 0) * 8 / 1000
        count[s] += 1
    whole = int(span_s)  # the last bucket is a part second
    return {
        "frames": len(frames),
        "host_fps": round((len(frames) - 1) / max(span_s, 1e-6), 2),
        "cap_fps": cap_fps,
        "gap_ms": summary(gaps),
        "gaps_over_1_5_slots": sum(g > 1.5 * slot_ms for g in gaps),
        "missed_slots": sum(max(0, round(g / slot_ms) - 1) for g in gaps),
        "gate_wait_ms": summary(gate),
        "encode_ms": summary(encode),
        "idr": sum(bool(x.get("idr")) for x in frames),
        "encoded_kbps_series": [round(k) for k in kbps[:whole]],
        "frames_series": count[:whole],
    }


def mono_ns():
    return time.clock_gettime_ns(MONO)


def pct(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    return s[min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))]


def summary(xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        return None
    return {"n": len(xs), "p50": round(pct(xs, 50), 2), "p95": round(pct(xs, 95), 2),
            "min": round(min(xs), 2), "max": round(max(xs), 2)}


# --- marker reading (RGB framebuffer) ---------------------------------------------------


def read_marker_rgb(rgb, width, origin, cell):
    """The marker counter from an RGB framebuffer (3 bytes a pixel), or None."""
    ox, oy = origin
    y = oy + cell // 2
    bits = []
    for i in range(CELLS):
        x = ox + i * cell + cell // 2
        o = (y * width + x) * 3
        if o + 2 >= len(rgb):
            return None
        r, g, b = rgb[o], rgb[o + 1], rgb[o + 2]
        luma = (r * 299 + g * 587 + b * 114) // 1000
        if 64 < luma < 192:
            return None  # mid-gray: not a marker cell
        bits.append(luma >= 128)
    if tuple(bits[16:]) != GUARD:
        return None
    return sum(1 << i for i, on in enumerate(bits[:16]) if on)


# --- the clock probe --------------------------------------------------------------------


def cmd_clock_serve(args):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((args.bind, args.port))
    print(json.dumps({"listening": s.getsockname()[1]}), flush=True)
    end = time.time() + args.seconds
    while time.time() < end:
        r, _, _ = select.select([s, sys.stdin], [], [], 0.5)
        if sys.stdin in r and not os.read(sys.stdin.fileno(), 4096):
            return  # the orchestrator went away
        if s not in r:
            continue
        data, peer = s.recvfrom(64)
        s.sendto(data[:8] + struct.pack("!Q", mono_ns()), peer)


def cmd_clock_probe(args):
    host, port = args.addr.rsplit(":", 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(0.5)
    best = None
    rtts = []
    misses = 0
    for i in range(args.count):
        t0 = mono_ns()
        s.sendto(struct.pack("!Q", i), (host, int(port)))
        try:
            data, _ = s.recvfrom(64)
        except socket.timeout:
            misses += 1
            if misses >= 10 and not rtts:
                break  # nothing is answering
            continue
        t1 = mono_ns()
        if struct.unpack("!Q", data[:8])[0] != i:
            continue
        th = struct.unpack("!Q", data[8:16])[0]
        rtt = t1 - t0
        rtts.append(rtt / 1e6)
        # host clock minus viewer clock, at the midpoint of the exchange
        offset = th - (t0 + rtt // 2)
        if best is None or rtt < best[0]:
            best = (rtt, offset)
        time.sleep(args.gap_ms / 1000.0)
    if best is None:
        print(json.dumps({"error": "no clock replies"}))
        sys.exit(2)
    print(json.dumps({"offset_ns": best[1], "rtt_min_ms": best[0] / 1e6,
                      "rtt_ms": summary(rtts), "replies": len(rtts)}))


# --- the rig: the shared Mac's side, inside an app with the grants ------------------------

SERVE_FLAGS = {"--profile": ("high", "baseline"), "--codec": ("videotoolbox", "openh264")}
MARKER_FLAGS = ("--motion", "--tick", "--verbose")


def rig_paths(root):
    root = os.path.expanduser(root)
    return root, os.path.join(root, "bin"), os.path.join(root, "state")


def cmd_rig(args):
    root, bindir, state = rig_paths(args.root)
    os.makedirs(state, exist_ok=True)
    os.chmod(root, 0o700)
    os.chmod(state, 0o700)
    path = os.path.join(state, "rig.sock")
    if os.path.exists(path):
        os.unlink(path)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o600)
    srv.listen(4)
    procs = {}
    timing = os.path.join(state, "timing.jsonl")

    def stop(name):
        p = procs.pop(name, None)
        if p and p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()

    def quit_rig(*_):
        for name in list(procs):
            stop(name)
        try:
            os.unlink(path)
        except OSError:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, quit_rig)
    signal.signal(signal.SIGHUP, quit_rig)
    print("rig ready: " + path, flush=True)
    while True:
        conn, _ = srv.accept()
        f = conn.makefile("rwb", buffering=0)
        try:
            req = json.loads(f.readline() or b"{}")
        except ValueError:
            f.close()
            conn.close()
            continue
        cmd = req.get("cmd")
        reply = {"ok": True}
        try:
            if cmd == "ping":
                reply["pid"] = os.getpid()
            elif cmd == "marker":
                stop("marker")
                flags = [x for x in req.get("flags", []) if x in MARKER_FLAGS]
                log = os.path.join(state, "marker.log")
                out = open(log, "w")
                procs["marker"] = subprocess.Popen([os.path.join(bindir, "cmux-rd-marker"), *flags],
                                                   stdout=out, stderr=out)
                deadline = time.time() + 10
                while time.time() < deadline:
                    with open(log) as lf:
                        text = lf.read()
                    if "marker-origin" in text and "stream width" in text:
                        break
                    time.sleep(0.05)
                for line in text.splitlines():
                    if line.startswith("marker-origin "):
                        x, y = line.split()[1].split(",")
                        reply["origin"] = [int(x), int(y)]
                    if "stream width" in line:
                        reply["geometry"] = line
                if "origin" not in reply:
                    reply = {"ok": False, "error": "marker printed no origin", "log": text[-400:]}
            elif cmd == "serve":
                stop("serve")
                argv = [os.path.join(bindir, "cmux-rd"), "serve"]
                for k, v in (req.get("flags") or {}).items():
                    if k in SERVE_FLAGS and v in SERVE_FLAGS[k]:
                        argv += [k, v]
                bind = req.get("link_bind")
                if bind:
                    socket.inet_aton(bind)  # an IPv4 literal, or this request fails
                    argv += ["--link-bind", f"{bind}:0"]
                env = dict(os.environ)
                if req.get("timing"):
                    open(timing, "w").close()
                    env["CMUX_RD_TIMING_LOG"] = timing
                err = open(os.path.join(state, "serve.err"), "w")
                p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=err, env=env)
                procs["serve"] = p
                bridge(conn, p)
                stop("serve")
                f.close()
                conn.close()
                continue
            elif cmd == "timing":
                lines = []
                if os.path.exists(timing):
                    with open(timing) as tf:
                        lines = [json.loads(x) for x in tf if x.strip()]
                    open(timing, "w").close()
                reply["lines"] = lines
            elif cmd == "stop":
                for name in list(procs):
                    stop(name)
            elif cmd == "quit":
                f.write((json.dumps(reply) + "\n").encode())
                f.close()
                conn.close()
                quit_rig()
            else:
                reply = {"ok": False, "error": "unknown command"}
        except Exception as e:  # noqa: BLE001 - one bad request never ends the rig
            reply = {"ok": False, "error": repr(e)}
        try:
            f.write((json.dumps(reply) + "\n").encode())
        except OSError:
            pass
        f.close()
        conn.close()


def bridge(conn, p):
    """Socket <-> process stdio until either side ends."""
    out = p.stdout.fileno()
    sock = conn.fileno()
    while p.poll() is None:
        r, _, _ = select.select([sock, out], [], [], 0.5)
        if sock in r:
            data = os.read(sock, 65536)
            if not data:
                try:
                    p.stdin.write(b'{"stop":true}\n')
                    p.stdin.flush()
                except OSError:
                    pass
                break
            p.stdin.write(data)
            p.stdin.flush()
        if out in r:
            data = os.read(out, 65536)
            if not data:
                break
            conn.sendall(data)


def cmd_rig_call(args):
    _, _, state = rig_paths(args.root)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(os.path.join(state, "rig.sock"))
    s.sendall((args.request + "\n").encode())
    if json.loads(args.request).get("cmd") != "serve":
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            data += chunk
        sys.stdout.write(data.decode())
        return
    inp = sys.stdin.fileno()
    while True:
        r, _, _ = select.select([inp, s], [], [])
        if inp in r:
            data = os.read(inp, 65536)
            if not data:
                s.shutdown(socket.SHUT_WR)
                inp = -1
            else:
                s.sendall(data)
        if s in r:
            data = s.recv(65536)
            if not data:
                return
            os.write(1, data)
        if inp == -1:
            # stdin closed: drain the rest of the host's output, then end
            while True:
                data = s.recv(65536)
                if not data:
                    return
                os.write(1, data)


# --- the macOS Screen Sharing leg (viewing Mac) ------------------------------------------


def load_cua_vnc(path):
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("cua_vnc", path)
    spec = importlib.util.spec_from_loader("cua_vnc", loader)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["cua_vnc"] = mod  # dataclasses look the module up by name
    loader.exec_module(mod)
    return mod


def cmd_rfb_bench(args):
    vnc = load_cua_vnc(os.path.expanduser(args.cua_vnc))
    user = os.environ.get("VNC_USERNAME")
    pw_file = os.environ.get("VNC_PASSWORD_FILE")
    if not user or not pw_file:
        print(json.dumps({"error": "no credentials: set VNC_USERNAME and VNC_PASSWORD_FILE"}))
        sys.exit(3)
    with open(os.path.expanduser(pw_file), encoding="utf8") as f:
        password = f.read().rstrip("\r\n")
    ox, oy = args.origin
    cell = args.cell
    strip = (ox, oy, cell * CELLS, cell)
    t_start = mono_ns()
    client = vnc.RfbClient(vnc.TcpTransport(args.host, args.port, 10.0), password, user,
                           "apple", ["raw"])
    password = None
    client.connect()
    t_auth = mono_ns()
    client.t.set_timeout(10.0)

    def request(incremental):
        client.send(struct.pack("!BBHHHH", 3, 1 if incremental else 0, *strip))

    def value():
        d = client.desktop
        return read_marker_rgb(d.rgb, d.width, (ox, oy), cell)

    request(False)
    marker = None
    while marker is None:
        if client.read_message() == 0:
            marker = value()
            request(marker is not None)
        if mono_ns() - t_start > 30e9:
            print(json.dumps({"error": "no marker within 30 s"}))
            sys.exit(2)
    first_frame_ms = (mono_ns() - t_start) / 1e6
    report = {"stack": "apple", "first_frame_ms": first_frame_ms,
              "auth_ms": (t_auth - t_start) / 1e6, "security_type": client.security_type,
              "screen": [client.desktop.width, client.desktop.height]}
    if args.mode == "key":
        g2g, lost = [], 0
        for _ in range(args.samples):
            expected = (marker + 1) & 0xFFFF
            t0 = mono_ns()
            client.key(KEYSYM_A, True)
            client.key(KEYSYM_A, False)
            shown = None
            while shown is None:
                client.t.set_timeout(1.0)
                try:
                    msg = client.read_message()
                except (socket.timeout, TimeoutError, OSError):
                    lost += 1
                    break
                if msg == 0:
                    v = value()
                    request(True)
                    if v is not None and v != marker:
                        marker = v
                        if v == expected:
                            shown = mono_ns()
                        else:
                            break
            if shown is not None:
                g2g.append((shown - t0) / 1e6)
            time.sleep(0.04 + (os.urandom(1)[0] / 255.0) * 0.12)
        report.update({"key_to_frame_ms": g2g, "lost": lost})
    else:
        changes, t_begin = 0, mono_ns()
        end = t_begin + args.duration_s * 1e9
        client.t.set_timeout(1.0)
        while mono_ns() < end:
            try:
                msg = client.read_message()
            except (socket.timeout, TimeoutError, OSError):
                request(True)
                continue
            if msg == 0:
                v = value()
                request(True)
                if v is not None and v != marker:
                    changes += 1
                    marker = v
        secs = (mono_ns() - t_begin) / 1e9
        report.update({"marker_changes": changes, "marker_fps": changes / secs, "seconds": secs})
    client.close()
    print(json.dumps(report))


# --- the orchestrator ---------------------------------------------------------------------


class Remote:
    def __init__(self, name, via):
        self.name, self.via = name, via

    def argv(self, cmd):
        if self.via == "ssh":
            return ["ssh", "-o", "BatchMode=yes", self.name, cmd]
        return ["reach", self.name, cmd]

    def run(self, cmd, timeout=120, stdin=None):
        p = subprocess.run(self.argv(cmd), input=stdin, capture_output=True, text=True,
                           timeout=timeout)
        if p.returncode != 0:
            raise RuntimeError(f"{self.name}: {cmd[:80]}: exit {p.returncode}: {p.stderr.strip()[-400:]}")
        return p.stdout

    def popen(self, cmd):
        p = subprocess.Popen(self.argv(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, bufsize=1)
        # A reader thread owns stdout. select() on a buffered pipe misses lines that one
        # read already pulled into the buffer (a signaling line then never gets relayed).
        p.lines = queue.Queue()

        def pump():
            for line in p.stdout:
                p.lines.put(line)
            p.lines.put(None)

        threading.Thread(target=pump, daemon=True).start()
        return p

    def put(self, local, remote_path, mode="0755"):
        with open(local, "rb") as f:
            data = f.read()
        p = subprocess.run(self.argv(f"mkdir -p {shlex.quote(os.path.dirname(remote_path))} && "
                                     f"cat > {shlex.quote(remote_path)}.tmp && chmod {mode} "
                                     f"{shlex.quote(remote_path)}.tmp && mv {shlex.quote(remote_path)}.tmp "
                                     f"{shlex.quote(remote_path)}"),
                           input=data, capture_output=True, timeout=300)
        if p.returncode != 0:
            raise RuntimeError(f"{self.name}: put {remote_path}: {p.stderr.decode()[-300:]}")


def readline(proc, deadline):
    """The next stdout line of a Remote.popen process, or None at EOF or the deadline."""
    left = deadline - time.time()
    if left <= 0:
        return None
    try:
        return proc.lines.get(timeout=left)
    except queue.Empty:
        return None


class Orchestrator:
    def __init__(self, args):
        self.a = args
        self.ff_rows = []
        self.motion_rows = []  # cmux fps trials: received Mbps and loss under motion
        self.host = Remote(args.host, args.via)
        self.viewer = Remote(args.viewer, args.via)
        self.root = args.root
        self.py = args.python
        self.me = f"{self.root}/screen-share-vs.py"
        self.out = open(args.out, "a") if args.out else None
        self.synthetic = args.source == "synthetic"

    def log(self, rec):
        line = json.dumps(rec)
        print(line, flush=True)
        if self.out:
            self.out.write(line + "\n")
            self.out.flush()

    def rig(self, request, timeout=30):
        out = self.host.run(f"{self.py} {self.me} rig-call --root {self.root} "
                            f"{shlex.quote(json.dumps(request))}", timeout=timeout)
        reply = json.loads(out.strip().splitlines()[-1])
        if not reply.get("ok"):
            raise RuntimeError(f"rig {request.get('cmd')}: {reply}")
        return reply

    def setup(self):
        if not self.root.startswith("/"):
            homes = {r.run('printf %s "$HOME"').strip() for r in (self.host, self.viewer)}
            if len(homes) != 1:
                raise SystemExit(f"the two Macs have different homes {homes}: pass an absolute --root")
            self.root = f"{homes.pop()}/{self.root}"
            self.me = f"{self.root}/screen-share-vs.py"
        here = os.path.abspath(__file__)
        for r in (self.host, self.viewer):
            r.put(here, self.me)
        if self.a.bin:
            self.viewer.put(self.a.bin, f"{self.root}/bin/cmux-rd")
            self.host.put(self.a.bin, f"{self.root}/bin/cmux-rd")
        if self.a.marker_src:
            self.host.put(self.a.marker_src, f"{self.root}/bin/marker-main.swift", "0644")
            self.host.run(f"cd {self.root}/bin && swiftc -O -o cmux-rd-marker marker-main.swift",
                          timeout=600)
        if self.a.cua_vnc:
            self.viewer.put(self.a.cua_vnc, f"{self.root}/bin/cua-vnc")
        if self.synthetic:
            # No rig and no marker app: `cmux-rd serve --source synthetic-*` needs no grant.
            state = shlex.quote(f"{self.root}/state")
            self.host.run(f"mkdir -p {state} && chmod 700 {shlex.quote(self.root)} {state}")
            return
        try:
            self.rig({"cmd": "ping"})
        except Exception:
            if not self.a.rig_launch:
                raise SystemExit(
                    "the rig is not running on the shared Mac; start it inside an app that holds "
                    "Screen Recording and Accessibility, or pass --rig-launch cmux-next")
            app_cli = "/Applications/cmux NEXT.app/Contents/Resources/bin/cmux"
            self.host.run(f"{shlex.quote(app_cli)} workspace create --name rd-share-rig -- "
                          f"/usr/bin/python3 {self.me} rig --root {self.root}")
            for _ in range(50):
                try:
                    self.rig({"cmd": "ping"})
                    break
                except Exception:
                    time.sleep(0.2)
            else:
                raise SystemExit("the rig did not start in cmux NEXT")

    def clock(self):
        # Port 0: a clock server still draining from the last probe never collides.
        srv = self.host.popen(f"{self.py} {self.me} clock-serve --bind {self.a.host_ip} "
                              f"--port 0 --seconds 120")
        line = readline(srv, time.time() + 15)
        try:
            port = json.loads(line or "{}").get("listening")
            if not port:
                raise RuntimeError(f"clock-serve on {self.a.host} did not start: {line!r}")
            out = self.viewer.run(f"{self.py} {self.me} clock-probe --addr {self.a.host_ip}:{port} "
                                  f"--count {self.a.clock_count}", timeout=60)
        finally:
            srv.terminate()
        return json.loads(out.strip().splitlines()[-1])

    # cmux ------------------------------------------------------------------------------

    def cmux_attempt(self, origin, mode):
        rec = {"stack": "cmux", "mode": mode, "ok": False}
        session = "vs-" + os.urandom(8).hex()
        bench = (f"{self.root}/bin/cmux-rd bench --link 1 --marker-origin {origin[0]},{origin[1]} ")
        if mode == "key":
            bench += f"--input key --samples {self.a.samples}"
        else:
            bench += f"--input none --duration-s {self.a.fps_seconds}"
        viewer = self.viewer.popen(bench)
        host = None
        try:
            line = readline(viewer, time.time() + 20)
            viewer_key = json.loads(line)["key"]
            if self.synthetic:
                host = self.host.popen(self.synthetic_serve(mode))
            else:
                host = self.host.popen(f"{self.py} {self.me} rig-call --root {self.root} "
                                       + shlex.quote(json.dumps({"cmd": "serve", "timing": mode == "key",
                                                                 "flags": {"--profile": "high"},
                                                                 "link_bind": self.a.link_bind})))
            setup = {"session": session, "peer_key": viewer_key, "scope": "control", "stun": [],
                     "display": "main", "max_fps": self.a.max_fps,
                     "viewer": {"user": "viewer", "install": "screen-share-vs"}}
            host.stdin.write(json.dumps(setup) + "\n")
            host.stdin.flush()
            host_key, cands = None, []
            dl = time.time() + 20
            while True:
                line = readline(host, min(dl, time.time() + 0.3) if host_key and cands else dl)
                if not line:
                    break
                msg = json.loads(line)
                if "key" in msg:
                    host_key = msg["key"]
                elif "candidate" in msg:
                    cands.append(msg["candidate"])
                elif msg.get("candidates_done"):
                    break
            rec["host_candidates"] = cands
            cands = [c for c in cands if self.a.host_ip in c] or cands
            t0 = time.time()
            viewer.stdin.write(json.dumps({"session": session, "peer_key": host_key, "stun": [],
                                           "candidates": cands}) + "\n")
            viewer.stdin.flush()
            streams = {"host": host, "viewer": viewer}
            deadline = t0 + self.a.timeout
            while streams and time.time() < deadline and "report" not in rec:
                for who, p in list(streams.items()):
                    try:
                        line = p.lines.get(timeout=0.01)
                    except queue.Empty:
                        continue
                    if line is None:
                        del streams[who]
                        continue
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    if who == "viewer" and "candidate" in msg:
                        host.stdin.write(json.dumps(msg) + "\n")
                        host.stdin.flush()
                    elif who == "host" and msg.get("connected"):
                        rec["connect_ms"] = round((time.time() - t0) * 1000, 1)
                    elif who == "host" and "path" in msg:
                        rec.setdefault("paths", []).append(msg["path"])
                    elif who == "viewer" and ("g2g_ms" in msg or "marker_fps" in msg):
                        rec["report"] = msg
            rep = rec.pop("report", None)
            if rep:
                rec["ok"] = True
                rec["first_frame_ms"] = rep.get("first_frame_ms")
                if mode == "key":
                    rec["g2g_ms"] = rep.get("g2g_ms")
                    rec["lost"] = rep.get("lost")
                    rec["sample_times"] = rep.get("sample_times")
                    rec["first_frame_times"] = rep.get("first_frame_times")
                    rec["frames_per_s"] = rep.get("frames_per_s")
                else:
                    rec["marker_fps"] = rep.get("marker_fps")
                    rec["fps"] = rep.get("fps")
                    rec["mbit_per_s"] = rep.get("bytes", 0) * 8 / max(rep.get("seconds", 1), 1e-3) / 1e6
                    rec.update(motion_link(rep.get("series") or []))
            else:
                rec["error"] = (viewer.stderr.read() if viewer.poll() is not None else "timeout")[-400:]
        except Exception as e:  # noqa: BLE001 - a broken attempt is a failed attempt
            rec["error"] = repr(e)
        finally:
            for p in (viewer, host):
                if p and p.poll() is None:
                    try:
                        p.stdin.write(json.dumps({"stop": True}) + "\n")
                        p.stdin.flush()
                        p.stdin.close()
                    except Exception:  # noqa: BLE001
                        pass
            for p in (viewer, host):
                if p:
                    try:
                        p.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        p.kill()
                        p.wait()
        return rec

    def first_frame_breakdown(self, rec, timing, offset_ns):
        """connect -> first decoded frame, split with the host's log (ms, viewer clock)."""
        t = rec.get("first_frame_times")
        opened = next((x for x in timing if "open_us" in x), None)
        f = next((x for x in timing if t and x.get("release_us") == t.get("capture_us")), None)
        if not (t and opened and f):
            return None
        off_us = offset_ns / 1000.0
        start = t["start_ns"] / 1000.0
        arrived = f.get("arrived_us")

        def ms(us):
            return None if us is None else round(us / 1000.0, 3)

        return {
            # the viewer has the answer -> the host opens the session (handshake, hello, start)
            "signal": ms(opened["open_us"] - off_us - start),
            # capture stream and encoder start
            "capture_start": ms(opened["desktop_ready_us"] - opened["open_us"]),
            # the capture's first frame arrives
            "first_capture": ms(arrived - opened["desktop_ready_us"]) if arrived else None,
            "gate": ms(f["release_us"] - arrived) if arrived else None,
            "encode": ms(f["encoded_us"] - f["release_us"]),
            "send": ms(f["sent_us"] - f["encoded_us"]),
            "down": ms(t["complete_ns"] / 1000.0 - (f["sent_us"] - off_us)),
            "decode": ms((t["decoded_ns"] - t["complete_ns"]) / 1000.0),
            "total": ms((t["decoded_ns"] - t["start_ns"]) / 1000.0),
            "bytes": f.get("encoded_bytes"),
            "idr": f.get("idr"),
        }

    def breakdown(self, rec, timing, offset_ns):
        """Per key press: where the time went, on the viewer's clock (ms)."""
        frames = {}
        injects = []
        for line in timing:
            if "inject_us" in line:
                injects.append(line)
            elif "release_us" in line:
                frames[line["release_us"]] = line
        injects.sort(key=lambda x: x["inject_us"])
        rows = []
        off_us = offset_ns / 1000.0

        def v(host_us):  # a host time (µs) on the viewer's clock
            return host_us - off_us

        def ms(us):
            return None if us is None else round(us / 1000.0, 3)

        for s in rec.get("sample_times") or []:
            f = frames.get(s["capture_us"])
            sent = s["sent_ns"] / 1000.0
            # The first injection the host read after this press was sent (1 ms of slack for
            # the clock estimate).
            inj = next((i for i in injects if i.get("recv_us") and v(i["recv_us"]) >= sent - 1000), None)
            if not f or not inj:
                continue
            shown, arrived = f.get("shown_us"), f.get("arrived_us")
            rows.append({
                "up": ms(v(inj["recv_us"]) - sent),
                "inject": ms(inj["inject_us"] - inj["recv_us"]),
                "draw": ms(shown - inj["inject_us"]) if shown else None,
                "sck": ms(arrived - shown) if shown and arrived else None,
                "gate": ms(f["release_us"] - arrived) if arrived else None,
                "encode": ms(f["encoded_us"] - f["release_us"]),
                "send": ms(f["sent_us"] - f["encoded_us"]),
                "first_packet": ms(s["first_rx_ns"] / 1000.0 - v(f["sent_us"])),
                "down": ms(s["complete_ns"] / 1000.0 - v(f["sent_us"])),
                "decode": ms((s["decoded_ns"] - s["complete_ns"]) / 1000.0),
                "total": ms((s["decoded_ns"] - s["sent_ns"]) / 1000.0),
                "bytes": f.get("encoded_bytes"),
            })
        return rows

    # --source synthetic: the host streams a generated picture (`cmux-rd serve --source
    # synthetic-still|synthetic-tick`), its marker at 0,0, and viewer input bumps the marker.
    # No rig, marker app or grant: any two Macs over ssh.

    def synthetic_timing_path(self):
        return shlex.quote(f"{self.root}/state/timing.jsonl")

    def synthetic_serve(self, mode):
        """The host command of one synthetic attempt: key trials show a still picture whose
        marker counts key presses (the marker app alone); fps trials move the bars and count
        every frame (the marker app's `--tick --motion`)."""
        source = "synthetic-still" if mode == "key" else "synthetic-tick"
        argv = [f"{self.root}/bin/cmux-rd", "serve", "--profile", "high", "--source", source]
        if self.a.synthetic_size:
            argv += ["--synthetic-size", self.a.synthetic_size]
        if getattr(self.a, "synthetic_scene", None):
            argv += ["--synthetic-scene", self.a.synthetic_scene]
        if self.a.link_bind:
            ipaddress.IPv4Address(self.a.link_bind)  # an IPv4 literal, or this attempt fails
            argv += ["--link-bind", f"{self.a.link_bind}:0"]
        # Both modes log timing: key trials for the breakdown, fps trials for `host_frames`.
        timing = self.synthetic_timing_path()
        env = f": > {timing} && CMUX_RD_TIMING_LOG={timing} "
        err = shlex.quote(f"{self.root}/state/serve.err")
        return env + " ".join(shlex.quote(a) for a in argv) + f" 2> {err}"

    def marker(self, flags):
        """The marker's origin for the next attempt: the marker app's (the rig), or 0,0."""
        if self.synthetic:
            return [0, 0]
        origin = self.rig({"cmd": "marker", "flags": flags})["origin"]
        time.sleep(0.5)
        return origin

    def host_timing(self):
        """The host's CMUX_RD_TIMING_LOG lines of the last attempt (then cleared)."""
        if not self.synthetic:
            return self.rig({"cmd": "timing"}, timeout=60).get("lines", [])
        timing = self.synthetic_timing_path()
        out = self.host.run(f"cat {timing} 2>/dev/null; : > {timing}", timeout=60)
        return [json.loads(x) for x in out.splitlines() if x.strip()]

    def run_cmux(self, clock):
        firsts, g2g, fps, rows = [], [], [], []
        # The first session after the rig starts can miss every key (the marker window is
        # not key yet), so warm-up attempts are logged but not counted.
        for n in range(1 - self.a.warmup, self.a.trials + 1):
            origin = self.marker([])
            rec = self.cmux_attempt(origin, "key")
            timing = self.host_timing()
            if n < 1:
                rec.pop("sample_times", None)
                self.log(dict(rec, warmup=True))
                continue
            rec["trial"] = n
            if rec["ok"]:
                firsts.append(rec["first_frame_ms"])
                g2g += [(s["decoded_ns"] - s["sent_ns"]) / 1e6 for s in rec.get("sample_times") or []]
                rec["breakdown"] = self.breakdown(rec, timing, clock["offset_ns"])
                rows += rec["breakdown"]
                ff = self.first_frame_breakdown(rec, timing, clock["offset_ns"])
                if ff:
                    rec["first_frame_breakdown"] = ff
                    self.ff_rows.append(ff)
            rec.pop("sample_times", None)
            self.log(rec)
        for n in range(1, self.a.fps_trials + 1):
            origin = self.marker(["--tick", "--motion"])
            rec = self.cmux_attempt(origin, "fps")
            rec["trial"] = n
            if self.synthetic:
                rec["host_frames"] = host_frames(self.host_timing(), self.a.max_fps)
            if rec["ok"]:
                fps.append(rec["marker_fps"])
                self.motion_rows.append(rec)
            self.log(rec)
        if not self.synthetic:
            self.rig({"cmd": "stop"})
        return firsts, g2g, fps, rows

    # macOS Screen Sharing -----------------------------------------------------------------

    def run_apple(self):
        if not (self.a.vnc_user and self.a.vnc_password_file):
            return None
        firsts, g2g, fps = [], [], []
        env = (f"VNC_USERNAME={shlex.quote(self.a.vnc_user)} "
               f"VNC_PASSWORD_FILE={shlex.quote(self.a.vnc_password_file)} ")
        for mode, trials, flags in (("key", self.a.trials, []),
                                    ("fps", self.a.fps_trials, ["--tick", "--motion"])):
            for n in range(1 - (self.a.warmup if mode == "key" else 0), trials + 1):
                origin = self.rig({"cmd": "marker", "flags": flags})["origin"]
                time.sleep(0.5)
                cmd = (env + f"{self.py} {self.me} rfb-bench --host {self.a.host_ip} "
                       f"--cua-vnc {self.root}/bin/cua-vnc --origin {origin[0]} {origin[1]} "
                       f"--cell 32 --mode {mode} --samples {self.a.samples} "
                       f"--duration-s {self.a.fps_seconds}")
                rec = {"stack": "apple", "mode": mode, "trial": n}
                try:
                    rep = json.loads(self.viewer.run(cmd, timeout=self.a.timeout).strip().splitlines()[-1])
                    rec.update(rep)
                    rec["ok"] = "error" not in rep
                except Exception as e:  # noqa: BLE001
                    rec.update({"ok": False, "error": repr(e)[-400:]})
                if n < 1:
                    rec["warmup"] = True
                self.log(rec)
                if n < 1:
                    time.sleep(2)
                    continue
                if rec["ok"]:
                    firsts.append(rec["first_frame_ms"])
                    if mode == "key":
                        g2g += rec["key_to_frame_ms"]
                    else:
                        fps.append(rec["marker_fps"])
                # Screen Sharing keeps a closed session's state for a moment.
                time.sleep(2)
        self.rig({"cmd": "stop"})
        return firsts, g2g, fps

    def main(self):
        self.setup()
        clock0 = self.clock()
        self.log({"clock": clock0, "host": self.a.host, "viewer": self.a.viewer,
                  "host_ip": self.a.host_ip, "link": self.a.link})
        results = {}
        stacks = self.a.stacks.split(",")
        rows = []
        if "cmux" in stacks:
            f, g, fps, rows = self.run_cmux(clock0)
            results["cmux Mac Screen" + (" (synthetic)" if self.synthetic else "")] = (f, g, fps)
        if "apple" in stacks and self.synthetic:
            # Screen Sharing shows the real display; the synthetic picture is cmux's alone.
            self.log({"skipped": "apple", "why": "--source synthetic streams no display"})
        elif "apple" in stacks:
            r = self.run_apple()
            results["macOS Screen Sharing"] = r
        try:
            clock1 = self.clock()
            self.log({"clock_end": clock1,
                      "drift_ms": (clock1["offset_ns"] - clock0["offset_ns"]) / 1e6})
        except Exception as e:  # noqa: BLE001 - the drift check never costs the table
            self.log({"clock_end_error": repr(e)[-400:]})
        self.table(results, clock0, rows)

    def table(self, results, clock, rows):
        rtt = clock.get("rtt_ms") or {}
        print()
        print(f"link {self.a.link} {self.a.host} -> {self.a.viewer} ({self.a.host_ip}): "
              f"udp rtt min {clock['rtt_min_ms']:.2f} ms, p50 {rtt.get('p50')} ms, p95 {rtt.get('p95')} ms")
        print(f"{'stack':<22} {'first_frame_ms p50/p95':>24} {'key_to_frame_ms p50/p95':>25} "
              f"{'fps (motion) p50':>17} {'n':>10}")
        summ = {}
        for name, r in results.items():
            if r is None:
                print(f"{name:<22} {'skipped: no VNC_USERNAME / VNC_PASSWORD_FILE given':>60}")
                continue
            f, g, fps = r
            sf, sg, sp = summary(f), summary(g), summary(fps)
            summ[name] = {"first_frame_ms": sf, "key_to_frame_ms": sg, "fps": sp}
            fmt = lambda s: f"{s['p50']:.1f} / {s['p95']:.1f}" if s else "-"  # noqa: E731
            print(f"{name:<22} {fmt(sf):>24} {fmt(sg):>25} {(sp['p50'] if sp else '-'):>17} "
                  f"{len(f)}tr/{len(g)}k")
        if self.motion_rows:
            m = self.motion_rows
            peak = [r["mbit_per_s_peak"] for r in m if r.get("mbit_per_s_peak") is not None]
            loss = [r["loss_pct_mean"] for r in m if r.get("loss_pct_mean") is not None]
            loss_max = [r["loss_pct_max"] for r in m if r.get("loss_pct_max") is not None]
            link = {"mbit_per_s_avg": round(statistics.mean(r["mbit_per_s"] for r in m), 2),
                    "mbit_per_s_peak": round(max(peak), 2) if peak else None,
                    "loss_pct_mean": round(statistics.mean(loss), 3) if loss else None,
                    "loss_pct_max": round(max(loss_max), 3) if loss_max else None}
            summ["cmux_motion_link"] = link
            print()
            print(f"cmux under motion ({len(m)} x {self.a.fps_seconds} s): received "
                  f"{link['mbit_per_s_avg']} Mbps avg, {link['mbit_per_s_peak']} Mbps peak (1 s); "
                  f"host loss {link['loss_pct_mean']} % mean, {link['loss_pct_max']} % max")

        def stage_table(title, rows, keys):
            print()
            print(title)
            stages = {}
            for k in keys:
                xs = [row[k] for row in rows if row.get(k) is not None]
                if xs:
                    stages[k] = {"p50": round(pct(xs, 50), 2), "p95": round(pct(xs, 95), 2),
                                 "mean": round(statistics.mean(xs), 2)}
                    print(f"  {k:<13} {stages[k]['p50']:>8} {stages[k]['p95']:>8} {stages[k]['mean']:>8}")
            return stages

        if rows:
            summ["cmux_breakdown"] = stage_table(
                "cmux key-to-frame breakdown (ms, viewer clock; p50 / p95 / mean over samples)", rows,
                ["up", "inject", "draw", "sck", "gate", "encode", "send", "first_packet", "down",
                 "decode", "total"])
        if self.ff_rows:
            summ["cmux_first_frame_breakdown"] = stage_table(
                "cmux first-frame breakdown (ms, viewer clock; p50 / p95 / mean over trials)",
                self.ff_rows, ["signal", "capture_start", "first_capture", "gate", "encode", "send",
                               "down", "decode", "total"])
        self.log({"summary": summ, "link": self.a.link, "rtt": clock})


def cmd_run(args):
    Orchestrator(args).main()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--host", required=True, help="the shared Mac (reach/ssh name)")
    r.add_argument("--viewer", required=True, help="the viewing Mac (reach/ssh name)")
    r.add_argument("--host-ip", required=True, help="the shared Mac's address on the measured link")
    r.add_argument("--link", default="wired", help="a label for the table")
    r.add_argument("--link-bind", help="bind the shared Mac's link socket to this address (its "
                   "Wi-Fi address when Ethernet shares the subnet), so both directions use it")
    r.add_argument("--via", choices=["reach", "ssh"], default="reach")
    r.add_argument("--root", default="cmux-rd-test", help="relative to the remote home")
    r.add_argument("--python", default="/usr/bin/python3")
    r.add_argument("--bin", help="local cmux-rd (macOS arm64, features bench,link) to install")
    r.add_argument("--marker-src", help="local mac-marker/main.swift to build on the shared Mac")
    r.add_argument("--cua-vnc", help="local cua-vnc/bin/cua-vnc to install on the viewing Mac")
    r.add_argument("--rig-launch", choices=["cmux-next"], help="start the rig in cmux NEXT")
    r.add_argument("--stacks", default="cmux,apple")
    r.add_argument("--source", choices=["screen", "synthetic"], default="screen",
                   help="synthetic: the host streams a generated picture with the marker "
                   "(`cmux-rd serve --source synthetic-*`), input bumps the marker; no rig, "
                   "marker app or Screen Recording/Accessibility grant (cmux leg only)")
    r.add_argument("--synthetic-size", help="WxH of the synthetic picture (default 1920x1080)")
    r.add_argument("--synthetic-scene", choices=["bars", "text", "noise"],
                   help="what the synthetic picture shows under the marker (default bars; text "
                   "and noise make the encoder spend)")
    r.add_argument("--trials", type=int, default=10)
    r.add_argument("--warmup", type=int, default=1, help="uncounted key attempts first")
    r.add_argument("--fps-trials", type=int, default=3)
    r.add_argument("--samples", type=int, default=30)
    r.add_argument("--fps-seconds", type=int, default=10)
    r.add_argument("--max-fps", type=int, default=60)
    r.add_argument("--clock-count", type=int, default=200)
    r.add_argument("--timeout", type=float, default=120)
    r.add_argument("--vnc-user", default=os.environ.get("VNC_USERNAME"))
    r.add_argument("--vnc-password-file", help="path on the viewing Mac (0600)")
    r.add_argument("--out")
    r.set_defaults(fn=cmd_run)
    g = sub.add_parser("rig")
    g.add_argument("--root", default="~/cmux-rd-test")
    g.set_defaults(fn=cmd_rig)
    c = sub.add_parser("rig-call")
    c.add_argument("--root", default="~/cmux-rd-test")
    c.add_argument("request")
    c.set_defaults(fn=cmd_rig_call)
    s = sub.add_parser("clock-serve")
    s.add_argument("--bind", default="0.0.0.0")
    s.add_argument("--port", type=int, default=47123)
    s.add_argument("--seconds", type=float, default=30)
    s.set_defaults(fn=cmd_clock_serve)
    p = sub.add_parser("clock-probe")
    p.add_argument("--addr", required=True)
    p.add_argument("--count", type=int, default=200)
    p.add_argument("--gap-ms", type=float, default=5)
    p.set_defaults(fn=cmd_clock_probe)
    b = sub.add_parser("rfb-bench")
    b.add_argument("--host", required=True)
    b.add_argument("--port", type=int, default=5900)
    b.add_argument("--cua-vnc", required=True)
    b.add_argument("--origin", type=int, nargs=2, required=True)
    b.add_argument("--cell", type=int, default=32)
    b.add_argument("--mode", choices=["key", "fps"], default="key")
    b.add_argument("--samples", type=int, default=30)
    b.add_argument("--duration-s", type=float, default=10)
    b.set_defaults(fn=cmd_rfb_bench)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
