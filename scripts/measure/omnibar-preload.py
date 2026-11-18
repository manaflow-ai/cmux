#!/usr/bin/env python3
"""Omnibar Enter to first paint in a tagged cmux NEXT Debug app, cold and prerendered (bench `omnibar`).

  scripts/measure/omnibar-preload.py --app "PATH/cmux DEV TAG.app" --tag TAG [--out DIR]
      [--urls "https://example.com/ https://en.wikipedia.org/wiki/Web_browser"] [--rounds 8] [--settle 2.5] [--learns 8]

Runs on a Mac with a GUI session (cmux-lawrence-2 for captures). Launches the app with an automation socket,
no activation and an empty config, opens one browser tab, and for every URL:

  learn       types the URL's host (the text a person types), waits for the popup rows (the app learns
              from an Enter only while its popup is open) and presses Return, --learns times: Chrome's
              AutocompleteActionPredictor needs 3 hits once its database has loaded, and hits before that
              are lost (run of 2026-11-17: example.com prerendered only from its 7th hit).
  prerendered types the same text, waits for the popup rows and --settle s for the predictor's prerender,
              then presses Return in the field (debug.key).
  cold        a new launch with an empty profile for each sample, the full URL typed: nothing cached,
              connected or prerendered (a first visit; CDNs still have the page).

Both arms load the same URL (no cache-busting query: a new query misses the CDN's cache, which only the cold
arm would pay). Each launch starts with the tag's data cleared (a tagged Debug app only): its own
Application Support folder (browser profile, predictor database) and its daemon's state (`cmux-next/tags/TAG`, which holds the omnibox history: a URL
typed in an earlier run would otherwise autocomplete the typed text to that URL), moved aside by
bench_launch.start_fresh_state once no process of the bundle runs.

Between samples the tab goes to about:blank. Enter is the wall clock just before the Return call (this script
runs on the same Mac as the app); paint is the page's own `performance.timeOrigin + FCP`, and for a page that
was prerendered, `timeOrigin + max(FCP, activationStart)` (the page was painted while hidden; the person sees
it at activation, as Chrome's own prerendered FCP counts it). A prerendered sample counts only when the page
reports activationStart > 0, a cold one only when it does not. The page is read through `debug.omnibar` (page_timing), never `browser.page.eval`:
an agent's call marks the tab agent-driven, and an agent-driven tab never preloads.

Prints one `OMNIBAR {json}` line and writes DIR/omnibar-preload.json:
  {"build": {...}, "samples": [{"url", "arm", "round", "enter_to_fcp_ms", "enter_to_nav_ms", "activated"}],
   "summary": {...}}
enter_to_nav_ms is Return to the navigation the person waits for (a prerender's activation, else the page's start).
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-next"))
import bench_launch  # noqa: E402  the tag's daemon state (its omnibox history) moved aside per arm

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=None)
parser.add_argument("--urls", default="https://example.com/ https://en.wikipedia.org/wiki/Web_browser")
parser.add_argument("--rounds", type=int, default=8)
parser.add_argument("--settle", type=float, default=2.5)
parser.add_argument("--learns", type=int, default=8)
opts = parser.parse_args()
OUT = opts.out or tempfile.mkdtemp(prefix=f"omnibar-preload-{opts.tag}-")
os.makedirs(OUT, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
URLS = opts.urls.split()


def call(method, params=None, timeout=60):
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


def wait(predicate, seconds, step=0.1):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def timing():
    """The tab's navigation timing (`debug.omnibar` page_timing: read with no gesture and no agent mark; an agent's
    `browser.page.eval` would mark the tab agent-driven, and an agent-driven tab never preloads). Each call starts a
    read and answers the one before, so a poll sees a page one step late."""
    reply = call("debug.omnibar", {"page_timing": True})
    raw = ((reply or {}).get("preload") or {}).get("page_timing") if isinstance(reply, dict) else None
    try:
        return json.loads(raw) if raw else None
    except ValueError:
        return None


def painted(want, enter):
    """The timing of a page whose URL has `want`, painted after Return (`enter`), with its wall-clock paint (as the
    person sees it); an earlier page of the same host is not it."""
    t = timing()
    if not t or want not in (t.get("url") or "") or t.get("fcp") is None:
        return None
    t["paint_wall"] = t["origin"] + max(t["fcp"], t["activation"] or 0)
    return t if t["paint_wall"] >= enter else None


def omnibar():
    reply = call("debug.omnibar")
    return reply if isinstance(reply, dict) and "error" not in reply else {}


LAST_FIELD = None
LAST_PRELOAD = None  # debug.omnibar's preload report before Return (what the tab answered)


def type_then_enter(text, settle=0.0):
    """Types `text` (no Return), waits for the popup's rows, then presses Return in the field: the app learns
    from an Enter only while the popup is open, and preloads its default row. The wall clock before Return."""
    call("debug.omnibar_type", {"text": text, "commit": False})
    wait(lambda: omnibar().get("phase") == "editing" and omnibar().get("rows"), 10, 0.05)
    if settle:
        time.sleep(settle)  # the predictor's prerender loads while the tab still shows about:blank
    global LAST_FIELD, LAST_PRELOAD
    report = omnibar()
    LAST_FIELD, LAST_PRELOAD = report.get("field_text"), report.get("preload")
    enter = time.time() * 1000
    call("debug.key", {"key": "return"})
    return enter


def blank():
    call("debug.omnibar_type", {"text": "about:blank", "commit": True})
    wait(lambda: (timing() or {}).get("url") == "about:blank", 10, 0.1)


def sample(text, want, arm, round_):
    """Type `text` (+ Return); the time from Return to the page's paint, read from the page."""
    blank()
    enter = type_then_enter(text, opts.settle if arm == "prerendered" else 0.0)
    seen = wait(lambda: painted(want, enter), 30, 0.1)
    if not seen:
        return {"url": want, "arm": arm, "round": round_, "enter_to_fcp_ms": None, "activated": False}
    # Where the time goes: Return to the navigation the person waits for (a prerender's activation, else the
    # page's own start), then that to the paint.
    nav = seen["origin"] + (seen["activation"] or 0)
    return {"url": want, "arm": arm, "round": round_, "activated": seen["activation"] > 0,
            "enter_to_fcp_ms": round(seen["paint_wall"] - enter, 1), "enter_to_nav_ms": round(nav - enter, 1),
            "field": LAST_FIELD, "loaded": seen["url"], "preload": LAST_PRELOAD}


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(opts.app, "Contents/MacOS", info["CFBundleExecutable"])
scratch = tempfile.mkdtemp(prefix=f"omnibar-preload-{opts.tag}-")
config = os.path.join(scratch, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
# The tag's own data (its browser profile, history and predictor database): each arm starts from none, so no
# earlier run's history autocompletes the typed text to another URL and nothing is in the HTTP cache.
PROFILE = os.path.expanduser(f"~/Library/Application Support/{info['CFBundleIdentifier']}")
if ".debug." not in info["CFBundleIdentifier"]:
    sys.exit(f"{info['CFBundleIdentifier']} is not a tagged Debug app; refusing to clear its data")


def fresh_state():
    """The tag's browser profile removed and its daemon state moved aside, once the bundle's processes (the app and
    its daemon, which can outlive the app by a few seconds) are gone; it waits, it never signals them."""
    if not wait(lambda: not bench_launch.bundle_pids(opts.app), 60, 0.5):
        sys.exit(f"{opts.app} still runs (pids {bench_launch.bundle_pids(opts.app)}); quit it before the bench")
    shutil.rmtree(PROFILE, ignore_errors=True)
    bench_launch.start_fresh_state(opts.tag)


def launch(name):
    fresh_state()
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
        "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
        stdout=open(os.path.join(OUT, f"app-{name}.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (call("debug.focus") or {"error": 1}), 180, 0.5):
        quit_app(app)
        sys.exit("the app socket never answered")
    call("action.run", {"action": "newBrowserWorkspace", "focus": True})
    if not wait(lambda: "error" not in (call("debug.omnibar") or {"error": 1}), 60, 0.5):
        quit_app(app)
        sys.exit("no omnibar")
    return app


def quit_app(app):
    call("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()


samples = []
# prerendered: one launch; per URL, learn the typed text --learns times (3 hits once the predictor's database has
# loaded; hits before that are lost, so a few more), then type it again: Return activates the predictor's prerender.
app = launch("prerendered")
try:
    for url in URLS:
        host = urlsplit(url).netloc
        text = host + urlsplit(url).path.rstrip("/")
        for _ in range(opts.learns):
            blank()
            type_then_enter(text)
            wait(lambda: host in ((timing() or {}).get("url") or ""), 30, 0.2)
        for r in range(opts.rounds):
            samples.append(sample(text, host, "prerendered", r))
            print(json.dumps(samples[-1]), flush=True)
finally:
    quit_app(app)
# cold: a new launch with an empty profile per sample, the full URL typed: nothing cached, connected or prerendered.
for url in URLS:
    host = urlsplit(url).netloc
    for r in range(opts.rounds):
        app = launch("cold")
        try:
            samples.append(sample(url, host, "cold", r))
            print(json.dumps(samples[-1]), flush=True)
        finally:
            quit_app(app)
fresh_state()

summary = {}
for arm in ("cold", "prerendered"):
    vals = [s["enter_to_fcp_ms"] for s in samples if s["arm"] == arm and s["enter_to_fcp_ms"] is not None
            and s["activated"] == (arm == "prerendered")]
    summary[arm] = {"n": len(vals), "median_ms": statistics.median(vals) if vals else None}
    navs = [s["enter_to_nav_ms"] for s in samples if s["arm"] == arm and s.get("enter_to_nav_ms") is not None
            and s["activated"] == (arm == "prerendered")]
    summary[arm]["nav_median_ms"] = statistics.median(navs) if navs else None
summary["prerender_activated"] = sum(s["activated"] for s in samples if s["arm"] == "prerendered")
summary["prerender_tried"] = sum(s["arm"] == "prerendered" for s in samples)
doc = {"build": {"tag": opts.tag, "version": info.get("CFBundleShortVersionString"),
                 "commit": info.get("CMUXCommit") or info.get("CMUXGitCommit")},
       "urls": URLS, "learns": opts.learns, "rounds": opts.rounds, "settle_s": opts.settle, "samples": samples, "summary": summary}
with open(os.path.join(OUT, "omnibar-preload.json"), "w") as f:
    json.dump(doc, f, indent=1)
print("OMNIBAR " + json.dumps(summary), flush=True)
