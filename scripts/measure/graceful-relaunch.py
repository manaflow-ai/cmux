#!/usr/bin/env python3
"""A relaunch, frame by frame on the window server: is any of the app's windows ever missing from the screen?

Leo, 2026-11-22: "we need to have far more graceful reloads that appear to just be instantly gracefully transitioned
... no shift, no anything, just... ok now it changed". The relaunch half of the graceful-swap measurements (the web
half is scripts/measure/graceful-swap.py, feat/graceful-web-swap; this writes the same one-JSON-per-run shape so the
two compare).

Drives a side copy (scripts/cmux-next/side-instance.sh; never the person's own app): reads the copy's windows on
screen, starts graceful-relaunch-windows.js (the window server's on-screen list, about 140 samples a second, no Screen
Recording grant: bounds, owner, alpha), relaunches the copy the way an update does (`debug.updater relaunch`, what
Sparkle runs before its installer relaunches: the quit keeps sessions; then `open` once the old process is gone, as
the installer and the relaunch helpers do), and reads, for every saved window frame, which process had a window
there in every sample: the old copy or the new copy (Restart to Update is a plain quit and relaunch, no afterimage).

  python3 scripts/measure/graceful-relaunch.py --app COPY.app --socket SOCK [--rounds 3] [--seconds 14] [--out DIR]

Per round (one JSON line `GRACEFUL-RELAUNCH {...}`, and DIR/round-N.json with the samples):
  blank_ms / blank_frames   time (and 60 Hz frames) some saved frame had no window of either copy over it
  first_blank_ms            when that started, from the trigger
  old_gone_ms               the old copy's last window left the screen
  new_first_ms              the new copy's first window at a saved frame
  restored_ms               every saved frame had a new copy's window (time to restored)
  windows_saved / windows_restored / frames_restored   counts, and whether every frame came back exactly
"""
import argparse, json, os, socket, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
FRAME_MS = 1000 / 60


def rpc(sock, method, params=None, timeout=20):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(sock)
    conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    try:
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    except OSError:
        pass
    conn.close()
    return json.loads(buf) if buf.strip() else None


def app_pid(app):
    exe = os.path.join(app, "Contents", "MacOS")
    out = subprocess.run(["pgrep", "-f", exe], capture_output=True, text=True).stdout.split()
    pids = [int(p) for p in out if p.strip()]
    return min(pids) if pids else None


def wait_socket(sock, limit):
    end = time.time() + limit
    while time.time() < end:
        try:
            if rpc(sock, "system.ping", timeout=2) is not None:
                return True
        except OSError:
            pass
        time.sleep(0.25)
    return False


def same(a, b, slack=2):
    return all(abs(x - y) <= slack for x, y in zip(a, b))


def analyze(samples, epoch, trigger_ms, old_pid, owner, mains=None):
    """samples: [(t, rows)]; rows [pid, owner, number, layer, alpha, x, y, w, h], front to back. `mains`: the app's
    document windows as (x, width, height) from debug.window_list (AppKit's y is flipped, so it is not compared);
    without it every on-screen layer-0 window of the old copy counts."""
    before = [s for s in samples if s[0] < trigger_ms]
    if not before:
        return {"error": "no sample before the trigger"}
    saved = sorted({tuple(r[5:9]) for r in before[-1][1] if r[0] == old_pid and r[3] == 0 and r[4] > 0
                    and (mains is None or any(same((r[5], r[7], r[8]), m) for m in mains))})
    out = {"windows_saved": len(saved), "blank_ms": 0.0, "first_blank_ms": None, "old_gone_ms": None,
           "new_first_ms": None, "restored_ms": None}
    if not saved:
        out["error"] = "the copy had no window on screen"
        return out
    after = [s for s in samples if s[0] >= trigger_ms]
    restored_frames = set()
    for i, (t, rows) in enumerate(after):
        dt = (after[i + 1][0] - t) if i + 1 < len(after) else 0
        rel = t - trigger_ms
        layer0 = [r for r in rows if r[3] == 0 and r[4] > 0.01]
        olds = [r for r in layer0 if r[0] == old_pid]
        news = [r for r in layer0 if r[0] != old_pid and r[1] == owner]
        if olds:
            out["old_gone_ms"] = None
        elif out["old_gone_ms"] is None:
            out["old_gone_ms"] = rel
        covered = 0
        new_here = set()
        for frame in saved:
            has_new = any(same(frame, tuple(r[5:9])) for r in news)
            if has_new:
                new_here.add(frame)
            if has_new or any(same(frame, tuple(r[5:9])) for r in olds):
                covered += 1
        if new_here and out["new_first_ms"] is None:
            out["new_first_ms"] = rel
        restored_frames |= new_here
        if len(new_here) == len(saved) and out["restored_ms"] is None:
            out["restored_ms"] = rel
        if covered < len(saved):
            out["blank_ms"] += dt
            if out["first_blank_ms"] is None:
                out["first_blank_ms"] = rel
    out["blank_ms"] = round(out["blank_ms"], 1)
    out["blank_frames"] = round(out["blank_ms"] / FRAME_MS, 1)
    out["windows_restored"] = len(restored_frames)
    out["frames_restored"] = len(restored_frames) == len(saved)
    return out


def one_round(args, n):
    old = app_pid(args.app)
    if not old:
        sys.exit(f"graceful-relaunch: {args.app} is not running")
    owner = os.path.splitext(os.path.basename(args.app))[0]
    owner_exe = os.listdir(os.path.join(args.app, "Contents", "MacOS"))[0]
    listed = (rpc(args.socket, "debug.window_list") or {}).get("result", {}).get("windows")
    mains = [(w["frame"]["x"], w["frame"]["width"], w["frame"]["height"]) for w in listed or [] if w.get("kind") == "main" and w.get("visible")] if listed else None
    path = os.path.join(args.out, f"round-{n}.jsonl")
    sampler = subprocess.Popen(["/usr/bin/osascript", "-l", "JavaScript", os.path.join(HERE, "graceful-relaunch-windows.js"),
                                str(args.seconds), path, owner_exe, owner],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.8)
    trigger = time.time()
    rpc(args.socket, "debug.updater", {"action": "relaunch"})
    # The relaunch helpers' and the installer's reopen: once the old process is gone.
    while time.time() - trigger < 20 and subprocess.run(["kill", "-0", str(old)], capture_output=True).returncode == 0:
        time.sleep(0.02)
    exited = time.time()
    subprocess.run(["open", args.app])
    sampler.wait(timeout=args.seconds + 10)
    with open(path) as f:
        lines = [json.loads(x) for x in f if x.strip()]
    epoch = lines[0]["epoch"]
    samples = [(l["t"], l["w"]) for l in lines[1:]]
    names = {r[1] for _, rows in samples for r in rows}
    real_owner = owner if owner in names else owner_exe
    result = analyze(samples, epoch, (trigger * 1000) - epoch, old, real_owner, mains)
    result.update({"round": n, "samples": len(samples), "quit_ms": round((exited - trigger) * 1000),
                   "sample_hz": round(len(samples) / max(1e-6, (samples[-1][0] - samples[0][0]) / 1000), 1) if samples else 0})
    print("GRACEFUL-RELAUNCH " + json.dumps(result), flush=True)
    with open(os.path.join(args.out, f"round-{n}.json"), "w") as f:
        json.dump(result, f)
    wait_socket(args.socket, 30)
    time.sleep(args.settle)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True)
    p.add_argument("--socket", required=True)
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--seconds", type=float, default=14)
    p.add_argument("--settle", type=float, default=4)
    p.add_argument("--out", default="/tmp/graceful-relaunch")
    args = p.parse_args()
    os.makedirs(args.out, exist_ok=True)
    rounds = [one_round(args, n) for n in range(1, args.rounds + 1)]
    keys = ["blank_ms", "blank_frames", "quit_ms", "old_gone_ms", "new_first_ms", "restored_ms"]
    median = {k: statistics.median([r[k] for r in rounds if isinstance(r.get(k), (int, float))] or [0]) for k in keys}
    median["frames_restored"] = all(r.get("frames_restored") for r in rounds)
    print("GRACEFUL-RELAUNCH-MEDIAN " + json.dumps(median), flush=True)


if __name__ == "__main__":
    main()
