#!/usr/bin/env python3
"""Streamed browser tab: video track vs reliable channel, measured black-box on
the E2E rig (verify/browser-video-track.md "Live verification").

One tagged cmux-next DEBUG Mac app (hidden, isolated, the rig's Mac class) and
the iOS app in ONE headless simulator on this Mac. The Mac's browser tab loads
bench-page/bench.html, which scrolls itself every frame and shows the Mac's
wall clock ("mac MM:SS.mmm") and, on each pointerdown, the time it arrived
("taps N at MM:SS.mmm"). The phone's measurement overlay shows the phone's
clock ("phone MM:SS.mmm") and the carrier ("· track", "· wg-rtp" or
"· channel"). The
simulator and the Mac app share this Mac's clock, so no offset applies.

Per configuration (carrier x path x loss), from the simulator's recording:
- glass to glass: phone clock - page clock in the same video frame (OCR);
- frame pacing: intervals between video frames whose page area changed;
- input to frame: tap sent (host time) -> first video frame showing that tap's
  count (its phone clock), split at the page's own receipt time.

Configurations: `[wg-]{track,channel}[-relay|-wss][-loss<permille>]`. A `wg-`
prefix dials WireGuard (`-cnx.settings.transport wireguard`), whose lane is RTP
inside the tunnel (overlay label `wg-rtp`); without it the link is WebRTC.
`-relay` is relay only (TURN when the service offers one); `-wss` is relay only
with TURN removed on the phone (CNX_DEV_NO_TURN), so WireGuard rides the
backend's WebSocket relay.

usage: browser-track-bench.py --mac-app APP [--configs track,channel,track-relay,channel-relay,track-loss30,wg-track,wg-channel,wg-track-relay,wg-track-wss,wg-track-loss30]
       [--seconds 12] [--taps 10] [--keep] [--no-build]
"""
import argparse
import datetime
import json
import os
import re
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CNX = os.path.abspath(os.path.join(HERE, "../.."))
sys.path.insert(0, os.path.join(CNX, "verify/e2e"))
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

import e2e  # noqa: E402
from journey import Journey, BUNDLE  # noqa: E402
from latency import frames as video_frames, diff  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

PORT = 8791
CLOCK = r"(\d{2}):(\d{2})[.,:](\d{3})"


def ms_of(m):
    return (int(m.group(1)) * 60 + int(m.group(2))) * 1000 + int(m.group(3))


def wrap(d):
    d %= 3_600_000
    return d - 3_600_000 if d > 1_800_000 else d


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    return round(v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))], 1)


def ocr(paths):
    out = {}
    for i in range(0, len(paths), 200):
        r = subprocess.run(["swift", os.path.join(HERE, "ocr-frames.swift"), *paths[i:i + 200]],
                           capture_output=True, text=True, timeout=1200)
        for line in r.stdout.splitlines():
            name, _, text = line.partition("\t")
            out[name] = text
    return out


def extract(video, out_dir, crop_pts, step=1):
    """Every `step`-th video frame, cropped (points), as JPEG; returns [(pts, path)]."""
    os.makedirs(out_dir, exist_ok=True)
    x, y, w, h = [int(v * 3) for v in crop_pts]
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
                            "-of", "csv=p=0", video], capture_output=True, text=True)
    times = [float(t.strip(",")) for t in probe.stdout.split() if t.strip(",") not in ("", "N/A")]
    subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough",
                    "-vf", f"crop={w}:{h}:{x}:{y}", "-q:v", "3", os.path.join(out_dir, "f%05d.jpg")], check=True)
    out = []
    for i, t in enumerate(times):
        p = os.path.join(out_dir, f"f{i + 1:05d}.jpg")
        if os.path.exists(p) and i % step == 0:
            out.append((t, p))
    return out


class Bench:
    def __init__(self, a, log):
        self.a, self.log = a, log

    # ---- Mac side ----------------------------------------------------------------
    def mac_env(self, mac, drop_permille):
        """CNX_VIDEO_DROP_PERMILLE in the rig app's LSEnvironment (the app passes its
        environment to cnx-hostd); re-signs the rig copy when it changes."""
        cur = pb(mac.info, "Print :LSEnvironment:CNX_VIDEO_DROP_PERMILLE", check=False)
        want = str(drop_permille)
        if (cur or "0") == want:
            return False
        pb(mac.info, "Delete :LSEnvironment:CNX_VIDEO_DROP_PERMILLE", check=False)
        pb(mac.info, f"Add :LSEnvironment:CNX_VIDEO_DROP_PERMILLE string {want}")
        subprocess.run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,requirements,flags,runtime",
                        mac.app], check=True, capture_output=True)
        return True

    def hostd_env(self, mac):
        pids = mac.hostd_pids()
        if not pids:
            return {}
        r = subprocess.run(["ps", "eww", "-p", str(pids[0])], capture_output=True, text=True)
        return dict(re.findall(r"(CNX_[A-Z_]+)=(\S+)", r.stdout))

    # ---- phone side --------------------------------------------------------------
    def open_bench(self, j, sim):
        if j is not None:
            j.back_to_list()
        else:
            # Remote Mac: dismiss an "offline" note about a cached Mac, then pick
            # the remote Mac in the list's Filter (its device id).
            ok = sim.find(label="OK", kind="Button")
            if ok:
                sim.tap_el(ok[0]); time.sleep(0.8)
            f = sim.wait(ident="workspaces.filter", timeout=15)
            if f:
                sim.press(*f.center, hold=0.1)
                item = sim.wait(ident=f"workspaces.filter.{self.a.mac_device}", timeout=8)
                if item:
                    sim.press(*item.center, hold=0.1)
                    time.sleep(2)
        row = sim.wait(prefix="bench", kind="Button", timeout=60)
        if not row:
            raise RuntimeError("workspace bench not on the phone")
        sim.tap_el(row)
        deadline = time.time() + 40
        while time.time() < deadline:
            text = " ".join(o[4] for o in sim.ocr())
            if re.search(r"fps", text) and re.search(r"mac\s+" + CLOCK, text):
                return text
            time.sleep(1)
        raise RuntimeError("the streamed page never showed (no overlay or page clock)")

    def run_config(self, name, mac, sim, j, out):
        wg = name.startswith("wg-")
        base = name[3:] if wg else name
        carrier = "channel" if base.startswith("channel") else ("wg-rtp" if wg else "track")
        wss = "wss" in base
        relay = "relay" in base or wss
        m = re.search(r"loss(\d+)", name)
        drop = int(m.group(1)) if m else 0
        self.log(f"=== {name}: transport {'wireguard' if wg else 'webrtc'}, carrier {carrier}, relay only {relay}"
                 f"{' (no TURN)' if wss else ''}, drop {drop}/1000")
        args = ["-cnx.dev.relayOnly", "YES" if relay else "NO",
                "-cnx.settings.transport", "wireguard" if wg else "webrtc",
                "-cnx.dev.browserVideoOnChannel", "YES" if carrier == "channel" else "NO"]
        sim_env = {"CNX_DEV_NO_TURN": "1"} if wss else None
        if self.a.remote:
            # The Mac app runs on a fleet Mac (browser-track-mac.sh); hostd reads the
            # drop share from its state folder at each new link.
            subprocess.run(["ssh", self.a.remote, f"echo {drop} > \"$HOME/Library/Application Support/{self.a.remote_bundle}/cnx-host/video-drop-permille\""],
                           check=True, timeout=60)
            env = {"CNX_VIDEO_DROP_PERMILLE(file)": str(drop)}
            args += [f"-cnx.live.mac.{self.a.team}", self.a.mac_device, "-cnx-tab", "workspaces"]
        else:
            if self.mac_env(mac, drop) or not mac.main_pids():
                mac.quit()
                mac.launch()
                mac.wait_hostd(120)
                time.sleep(3)
            env = self.hostd_env(mac)
        sim.launch(BUNDLE, args=args, env=sim_env)
        time.sleep(4)
        shown = self.open_bench(j, sim)
        # Wait for the carrier the configuration asks for.
        deadline = time.time() + 20
        while time.time() < deadline and f"· {carrier}" not in shown and f"- {carrier}" not in shown \
                and not re.search(rf"\b{carrier}\b", shown):
            time.sleep(1)
            shown = " ".join(o[4] for o in sim.ocr())
        status = j.link_status() if j is not None else ""
        cfg_dir = os.path.join(out, name)
        os.makedirs(cfg_dir, exist_ok=True)
        video = os.path.join(cfg_dir, "screen.mp4")
        sim.record_start(video)
        rec_t0 = time.time()
        time.sleep(self.a.seconds)
        taps = []
        for _ in range(self.a.taps):
            t = time.time()
            sim.tap(200, 520)
            taps.append(t)
            time.sleep(1.3)
        time.sleep(1.5)
        sim.record_stop()
        shot = sim.shot(f"{name}-end")
        result = {"config": name, "transport": "wireguard" if wg else "webrtc", "no_turn": wss,
                  "carrier_expected": carrier, "relay_only": relay, "drop_permille": drop,
                  "hostd_env": env, "overlay_at_start": shown[:300], "link_status": status,
                  "recording_started_host": rec_t0, "taps_host": taps, "screenshot": shot}
        json.dump(result, open(os.path.join(cfg_dir, "capture.json"), "w"), indent=2)
        if self.a.record_only:
            return result
        result.update(self.analyze(video, cfg_dir, rec_t0, taps))
        json.dump(result, open(os.path.join(cfg_dir, "result.json"), "w"), indent=2)
        self.log(f"    {name}: {json.dumps({k: result.get(k) for k in ('carrier_seen', 'g2g_ms', 'pacing', 'input_to_frame_ms', 'mac_input_to_frame_ms')})}")
        return result

    # ---- analysis ------------------------------------------------------------------
    def analyze(self, video, cfg_dir, rec_t0, taps):
        # Pacing: page area (below the page HUD, above the overlay) frame to frame.
        fr = video_frames(video, (0, 260, 402, 300))
        changes = []
        prev = None
        for t, img in fr:
            if prev is not None and diff(prev, img) > 1.0:
                changes.append(t)
            prev = img
        scroll_end = self.a.seconds - 0.5
        moving = [t for t in changes if 1.0 <= t <= scroll_end]
        gaps = [round((b - a) * 1000, 1) for a, b in zip(moving, moving[1:])]
        pacing = {"fps": round(len(moving) / max(0.1, scroll_end - 1.0), 1), "interval_p50_ms": pct(gaps, 50),
                  "interval_p95_ms": pct(gaps, 95), "interval_max_ms": max(gaps) if gaps else None,
                  "stalls_over_100ms": sum(1 for g in gaps if g > 100), "jitter_ms": round(statistics.pstdev(gaps), 1) if len(gaps) > 1 else None}
        # OCR every frame of the whole screen's lower and upper strips: page HUD (top
        # of the page) and the overlay (bottom of the page).
        shots = extract(video, os.path.join(cfg_dir, "frames"), (0, 0, 402, 874), step=1)
        texts = ocr([p for _, p in shots])
        g2g, carriers, tap_frames = [], {}, {}
        for t, p in shots:
            text = texts.get(os.path.basename(p), "")
            mac = re.search(r"mac\s+" + CLOCK, text)
            phone = re.search(r"phone\s+" + CLOCK, text)
            for c in ("wg-rtp", "track", "channel"):
                if re.search(rf"\b{c}\b", text):
                    carriers[c] = carriers.get(c, 0) + 1
            if mac and phone:
                d = wrap(ms_of(phone) - ms_of(mac) - self.a.offset_ms)
                if -50 < d < 5000 and t <= self.a.seconds:
                    g2g.append(d)
            tap = re.search(r"taps\s+(\d+)\s+at\s+" + CLOCK, text)
            if tap and phone:
                n = int(tap.group(1))
                if n not in tap_frames:
                    m2 = re.search(CLOCK, text[tap.start():])
                    tap_frames[n] = (t, ms_of(phone), ms_of(m2) if m2 else None)
        # Taps: the count goes up by one per tap; tap k (0-based) shows count base+k+1.
        counts = sorted(tap_frames)
        inputs, mac_inputs, input_legs = [], [], []
        if counts:
            base = counts[0] - 1 if len(counts) >= len(taps) else max(0, counts[-1] - len(taps))
            for k, t_host in enumerate(taps):
                n = base + k + 1
                if n not in tap_frames:
                    continue
                _, phone_ms, mac_ms = tap_frames[n]
                host_ms = int(t_host * 1000) % 3_600_000
                d = wrap(phone_ms - host_ms)
                if 0 < d < 5000:
                    inputs.append(d)
                if mac_ms is not None:
                    mac_ms = (mac_ms - self.a.offset_ms) % 3_600_000
                    v = wrap(phone_ms - mac_ms)
                    if 0 < v < 5000:
                        mac_inputs.append(v)
                    leg = wrap(mac_ms - host_ms)
                    if -50 < leg < 5000:
                        input_legs.append(leg)
        summary = lambda v: {"n": len(v), "p50": pct(v, 50), "p90": pct(v, 90), "max": max(v) if v else None}
        return {"carrier_seen": carriers, "g2g_ms": summary(g2g), "pacing": pacing,
                "input_to_frame_ms": summary(inputs), "mac_input_to_frame_ms": summary(mac_inputs),
                "tap_to_mac_ms": summary(input_legs), "video_frames": len(fr)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app")
    ap.add_argument("--configs", default="track,channel,track-relay,channel-relay,track-loss30")
    ap.add_argument("--seconds", type=float, default=12)
    ap.add_argument("--taps", type=int, default=10)
    ap.add_argument("--sim-name", default="cnx-rbvideo-bench")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--skip-setup", action="store_true", help="the phone is signed in and the bench tab exists (a --keep run)")
    ap.add_argument("--record-only", action="store_true", help="record now, analyze later with --analyze")
    ap.add_argument("--out", help="evidence directory (default: a new one)")
    ap.add_argument("--analyze", help="analyze every configuration recorded in this directory")
    ap.add_argument("--remote", help="ssh host whose GUI session runs the Mac app (browser-track-mac.sh)")
    ap.add_argument("--team", help="remote mode: the phone's team id (personal-...)")
    ap.add_argument("--mac-device", help="remote mode: the Mac's cnx-hostd device id")
    ap.add_argument("--remote-bundle", default="com.cmuxterm.app.debug.cnx.rbvideo.b")
    ap.add_argument("--offset-ms", type=float, default=0.0, help="Mac clock minus this Mac's clock (clock-offset.py)")
    a = ap.parse_args()
    if a.remote:
        out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "browser-video-track",
                                    datetime.datetime.now().strftime("%H%M%S"))
        os.makedirs(out, exist_ok=True)
        udid = e2e.ensure_sim(a.sim_name, e2e.RUNTIMES["26"], print)
        sim = Sim(udid, os.path.join(out, "shots"))
        bench = Bench(a, print)
        results = []
        for name in a.configs.split(","):
            try:
                results.append(bench.run_config(name, None, sim, None, out))
            except Exception as e:
                print(f"    {name} FAILED: {e}")
                results.append({"config": name, "error": str(e)[:400]})
        json.dump(results, open(os.path.join(out, f"run-{datetime.datetime.now().strftime('%H%M%S')}.json"), "w"), indent=2)
        return
    if a.analyze:
        bench = Bench(a, print)
        results = []
        for name in sorted(os.listdir(a.analyze)):
            cap = os.path.join(a.analyze, name, "capture.json")
            if not os.path.exists(cap):
                continue
            result = json.load(open(cap))
            result.update(bench.analyze(os.path.join(a.analyze, name, "screen.mp4"), os.path.join(a.analyze, name),
                                        result["recording_started_host"], result["taps_host"]))
            json.dump(result, open(os.path.join(a.analyze, name, "result.json"), "w"), indent=2)
            print(json.dumps({k: result.get(k) for k in ("config", "carrier_seen", "g2g_ms", "pacing", "input_to_frame_ms",
                                                         "mac_input_to_frame_ms", "tap_to_mac_ms")}))
            results.append(result)
        json.dump(results, open(os.path.join(a.analyze, "results.json"), "w"), indent=2)
        return
    mac_app = os.path.abspath(a.mac_app)
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "browser-video-track",
                                datetime.datetime.now().strftime("%H%M%S"))
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    app_path = os.path.join(CNX, "build/dd/Build/Products/Demo-iphonesimulator/CnxApp.app") if a.no_build else e2e.build_ios(log, "Demo")
    rig = os.path.expanduser(f"~/cnx-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app)
    if not a.skip_setup:
        mac.prepare()
        mac.seed_pairing(names=[a.sim_name])
    page_dir = os.path.join(HERE, "bench-page")
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"], cwd=page_dir,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    udid = e2e.ensure_sim(a.sim_name, e2e.RUNTIMES["26"], log)
    sim = Sim(udid, os.path.join(out, "shots"))
    results = []
    j = None
    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}); cnx-hostd {'running' if mac.wait_hostd(120) else 'NOT running'}")
        j = Journey(sim, mac, out, app_path, log)
        if a.skip_setup:
            j.ws_name = "bench"
        for name in ([] if a.skip_setup else a.configs.split(",")[:0]):
            pass
        if a.skip_setup:
            bench = Bench(a, log)
            for name in a.configs.split(","):
                try:
                    results.append(bench.run_config(name, mac, sim, j, out))
                except Exception as e:
                    log(f"    {name} FAILED: {e}")
                    results.append({"config": name, "error": str(e)[:400]})
            return
        j.seed_mac()
        ws = mac.cmux("workspace", "create", "--name", "bench", json_out=True)["value"]
        url = f"http://127.0.0.1:{PORT}/bench.html?scroll=6"
        tab = mac.cmux("tab", "create", "browser", "--workspace", ws["workspace_id"], "--url", url, json_out=True)
        log(f"bench workspace {ws['workspace_id']}, browser tab {tab}")
        if tab and isinstance(tab, dict) and tab.get("value", {}).get("tab_id"):
            mac.cmux("tab", tab["value"]["tab_id"], "focus", check=False)
        mac.cmux("tab", ws["tab_id"], "close", check=False)
        for sid, title, owner, fn in j.plan():
            if sid in ("fresh_install", "sign_in", "choose_space", "mac_discovered"):
                j.step(sid, title, owner, fn)
        bench = Bench(a, log)
        for name in a.configs.split(","):
            try:
                results.append(bench.run_config(name, mac, sim, j, out))
            except Exception as e:  # one configuration's failure does not end the run
                log(f"    {name} FAILED: {e}")
                results.append({"config": name, "error": str(e)[:400]})
    finally:
        json.dump({"mac_app": os.path.basename(mac_app), "results": results},
                  open(os.path.join(out, f"run-{datetime.datetime.now().strftime('%H%M%S')}.json"), "w"), indent=2)
        server.terminate()
        if not a.keep:
            log(f"quitting the rig Mac app: {mac.quit()}")
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)
            log(f"simulator {a.sim_name} deleted")
        log(f"results: {os.path.join(out, 'results.json')}")


if __name__ == "__main__":
    main()
