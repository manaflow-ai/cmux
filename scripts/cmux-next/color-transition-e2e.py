#!/usr/bin/env python3
"""Behavior check of appearance.colorTransition (cx-3rf4z, Lawrence 2026-10-15: "ensure when
changing themes and colors, like switching between workspaces with different colors/bgs, there is
always smooth animation (that can be configured, fully ... or even just instant").

Launches the tagged app itself (no activation, a scratch cmux.json, an empty Ghostty config, an
isolated Chief home; it never opens Home or the Chief pane) and gives two workspaces different
themes over the control socket (workspace.setTheme: Rose Pine and Catppuccin Mocha; both dark,
because a room adopts a shown workspace's colors only when light/dark matches). Then
it switches between them by id (goToWorkspace) and samples the window backdrop
color the render server shows (debug.themes windows[].backdrop.sheet, the presentation value)
as fast as the socket answers:

  blend      400 ms linear in OKLab: several distinct colors in between, each sample nearer the target
             in OKLab than the last (within one 8-bit step), the last sample is the target exactly.
  retarget   B to A, then back to B after about 250 ms: the first sample after the reversal is
             near the last one before it (no jump to an end color), and it ends on B exactly.
  instant    enabled false: the first sample after the switch is already the target, no blend.
  record     (--record) one debug.window_record of a blend, frames under OUT/record/.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  color-transition-e2e.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS" [--record]
Stop the app afterwards with "$NX_APP_STOP". Exit 1 on any failed check.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--record", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"colortx-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
failures, report = [], {}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def config(**transition):
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {"backgroundOpacity": 1, "colorTransition": transition}}, f)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def action(name, args=None, target=None):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    reply = rpc("action.run", params)
    if isinstance(reply, dict) and reply.get("error"):
        print("action", name, "->", reply, flush=True)
    return reply


def fire(name, args=None):
    """Runs an action without waiting for its reply, so sampling starts at once."""
    thread = threading.Thread(target=action, args=(name, args), daemon=True)
    thread.start()
    return thread


def shown_workspace():
    return next((w for w in window().get("workspaces") or [] if w.get("shown")), {})


def themed(name):
    """Sets the shown workspace's theme and waits until debug.themes shows it there."""
    shown = shown_workspace().get("workspace")
    action("workspace.setTheme", {"theme": name}, target=f"workspace:{shown}" if shown else None)
    ok = wait(lambda: shown_workspace().get("effective_spec") == name, 10)
    with open(os.path.join(opts.out, f"themes-{name.replace(' ', '-')}.json"), "w") as f:
        json.dump(rpc("debug.themes"), f, indent=1)
    check(bool(ok), f"the shown workspace takes {name} ({shown_workspace().get('effective_spec')})")


def workspace_ids():
    snap = rpc("snapshot.get") or {}
    topology = snap.get("topology") or snap
    return [w.get("id") for w in topology.get("workspaces") or []]


def window():
    windows = (rpc("debug.themes") or {}).get("windows") or []
    return windows[0] if windows else {}


def sheet():
    return (window().get("backdrop") or {}).get("sheet") or ""


def rgb(hexa):
    return tuple(int(hexa[i:i + 2], 16) / 255 for i in (1, 3, 5)) if len(hexa) >= 7 else None


def oklab(color):
    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in color)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)


def distance(a, b):
    """OKLab distance between two #RRGGBB colors."""
    return sum((x - y) ** 2 for x, y in zip(oklab(rgb(a)), oklab(rgb(b)))) ** 0.5


def sample(seconds, trigger, retrigger=None):
    """Runs `trigger`, then samples the sheet color for `seconds`; `retrigger` (delay, fn) runs once mid-way."""
    samples, start = [], time.monotonic()
    trigger()
    fired = retrigger is None
    while time.monotonic() - start < seconds:  # bounded sampling window
        if not fired and time.monotonic() - start >= retrigger[0]:
            samples.append((round(time.monotonic() - start, 4), "RETARGET"))
            retrigger[1]()
            fired = True
        samples.append((round(time.monotonic() - start, 4), sheet()))
    return samples


def colors(samples):
    return [c for _, c in samples if c and c != "RETARGET"]


def settled():
    """The sheet color once no blend runs (bounded)."""
    def at_rest():
        backdrop = window().get("backdrop") or {}
        return backdrop.get("sheet") if backdrop.get("blending") == "false" and backdrop.get("sheet") else None
    time.sleep(0.1)
    return wait(at_rest, 5, 0.05)


def settle(target):
    return wait(lambda: (settled() or "")[:7] == target[:7], 5, 0.05)


app = None
try:
    config(duration=400, curve="linear", colorSpace="oklab")
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,980,720"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log,
                           stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and workspace_ids(), 180, 0.5):
        sys.exit("the tagged app did not come up")
    check(wait(lambda: sheet(), 30) is not None, "debug.themes reports the window backdrop sheet")

    check(bool(wait(lambda: shown_workspace().get("workspace"), 30)), "a workspace shows")
    themed("Rose Pine")
    first_ws = shown_workspace().get("workspace")
    action("workspace.newAtBottom")
    check(bool(wait(lambda: shown_workspace().get("workspace") not in (None, first_ws), 30)), "a second workspace opens and shows")
    themed("Catppuccin Mocha")
    second_ws = shown_workspace().get("workspace")
    report["workspaces"] = [first_ws, second_ws]
    time.sleep(1)
    dark = settled()
    action("goToWorkspace", {"workspace": first_ws})
    time.sleep(1)
    light = settled()
    report["light"], report["dark"] = light, dark
    # Both dark: a room adopts a shown workspace's colors only when light/dark matches (ThemeScope.tokens).
    span = distance(light, dark) if light and dark else 0
    check(span > 0.02, f"the two workspaces have different backgrounds ({light} vs {dark}, OKLab distance {span:.3f})")

    # blend: first -> second workspace, 400 ms linear, OKLab.
    blend = sample(0.8, lambda: fire("goToWorkspace", {"workspace": second_ws}))
    report["blend"] = blend
    seen = colors(blend)
    while len(seen) > 1 and seen[0][:7] == light[:7] and seen[1][:7] == light[:7]:
        seen = seen[1:]  # the switch had not landed yet
    distinct = list(dict.fromkeys(c[:7] for c in seen))
    remaining = [distance(c, dark) for c in distinct]
    check(len(distinct) >= 4, f"the blend shows {len(distinct)} distinct colors between the two (want >= 4)")
    steps = [b - a for a, b in zip(remaining, remaining[1:])]
    check(all(s <= 0.004 for s in steps), f"every sample is nearer the target than the last (OKLab steps {[round(s, 4) for s in steps]})")
    check(bool(seen) and seen[-1][:7] == (dark or "")[:7], f"the blend ends on the dark background exactly ({seen[-1] if seen else None})")

    # retarget: dark -> light, back to dark after 250 ms (the switch itself lands after ~130 ms).
    settle(dark)
    retarget = sample(1.1, lambda: fire("goToWorkspace", {"workspace": first_ws}), (0.25, lambda: fire("goToWorkspace", {"workspace": second_ws})))
    report["retarget"] = retarget
    marker = next((i for i, (_, c) in enumerate(retarget) if c == "RETARGET"), None)
    before_turn = colors(retarget[:marker]) if marker is not None else []
    after_turn = colors(retarget[marker + 1:]) if marker is not None else []
    if before_turn and after_turn:
        jump = distance(after_turn[0], before_turn[-1])
        span = distance(light, dark)
        check(jump < 0.35 * span, f"the reversal continues from the color on screen (jump {jump:.3f} of span {span:.3f})")
        check(before_turn[-1][:7] not in (light[:7], dark[:7]), f"the reversal came mid-blend ({before_turn[-1]})")
    else:
        check(False, "samples on both sides of the reversal")
    check(bool(after_turn) and after_turn[-1][:7] == dark[:7], f"the retarget ends on the dark background ({after_turn[-1] if after_turn else None})")

    if opts.record:
        settle(dark)
        rec = os.path.join(opts.out, "record")
        os.makedirs(rec, exist_ok=True)
        rpc("debug.window_record", {"dir": rec, "seconds": 1.2})
        time.sleep(0.1)
        action("goToWorkspace", {"workspace": first_ws})
        time.sleep(1.4)  # the recording stops by itself after 1.2 s
        check(os.path.exists(os.path.join(rec, "frames.json")), "a frame recording of one blend is written")

    # instant: enabled false.
    config(enabled=False, duration=400, curve="linear")
    check(bool(wait(lambda: (window().get("backdrop") or {}).get("seconds") == "0.0", 10)), "instant: the app took enabled false")
    action("goToWorkspace", {"workspace": first_ws})
    check(bool(settle(light)), "instant: the light workspace shows before the switch")
    instant = sample(0.4, lambda: fire("goToWorkspace", {"workspace": second_ws}))
    report["instant"] = instant
    seen = [c[:7] for c in colors(instant)]
    between = [c for c in dict.fromkeys(seen) if c not in (light[:7], dark[:7])]
    check(bool(seen) and seen[-1] == dark[:7] and not between,
          f"instant: one step from the light to the dark background, nothing in between ({list(dict.fromkeys(seen))})")
finally:
    with open(os.path.join(opts.out, "color-transition.json"), "w") as f:
        json.dump({"failures": failures, **report}, f, indent=1)
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
