#!/usr/bin/env python3
"""The New Tab omnibar in a real tagged app: light and dark shots of its rows, and keydown-to-frame typing.

  scripts/cmux-next/new-tab-omnibar-live.py --app "<path>/cmux DEV <tag>.app" --out <dir> [--themes light,dark]
      [--typing-keys 120] [--native] [--no-shots]

Runs on a Mac with a GUI session (cmux-lawrence-2), never the person's Mac. What it does, and why each step:

- Seeds demo project folders (git repositories under <out>/demo: cmux, cmux-tui, notes, site) and opens a
  terminal in each, in a workspace of its own, so the page's projects, open tabs and folder listing have
  something to find. The Home workspace is never used: a few seconds after launch it opens the Chief chat
  beside its pane and that chat takes the keyboard, so keys typed into a New Tab page there went to the
  Chief's composer, or were dropped by the New Tab key hold ("what had the keyboard at the opening").
- Opens one New Tab page and waits until it is ready (its composer has the caret) before any key: keys sent
  with the opening are held and replayed, so they are never a keydown the page's probe sees.
- Resets the page's typing counter on that same page, then types with `debug.key` into its window, each key
  stamped with the client's send time (CLOCK_UPTIME_RAW, as `debug.key` takes it), so the probe counts the
  wait for the main thread too. Before this script, each scenario opened a new page after the reset: the
  counter read the old page and said 0 keys.
- Shots: `debug.window_snapshot` (Debug builds, no Screen Recording grant), per theme
  (`appearance.appTheme`, GitHub Light / Dark Default) and scenario. With `--native`, the same scenarios on
  the native New Tab page (`tabs.nativeNewTabPage`).

Writes <out>/<theme>-<scenario>.png, <out>/typing.json and prints one summary line per measurement.
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--themes", default="light,dark")
parser.add_argument("--typing-keys", type=int, default=120, help="keys typed for the typing measurement (0: none)")
parser.add_argument("--key-gap", type=float, default=0.09, help="seconds between typed keys (a fast typist)")
parser.add_argument("--native", action="store_true", help="also shoot the native New Tab page")
parser.add_argument("--no-shots", action="store_true")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
THEMES = {"light": "GitHub Light Default", "dark": "GitHub Dark Default"}
DEMO = os.path.realpath(os.path.join(OUT, "demo"))
FOLDERS = ["cmux", "cmux-tui", "notes", "site"]
# The scenarios: what each shot shows.
# (name, text, what it shows, a check of the rows and headers on the build with the omnibar's agent rows)
SHOWN = DEMO.replace(os.path.expanduser("~"), "~", 1)
SCENARIOS = [
    ("sections", "cmux", "open tabs and start rows under their section headers",
     lambda rows, heads: any(" in " in row for row in rows) and bool(heads)),
    # A typed path names the folder: the host's project list need not hold the demo folders.
    ("start-named", f"codex in {SHOWN}/cmux", "Codex in the cmux folders leads above Ask",
     lambda rows, heads: bool(rows) and rows[0] == f"Codex in {SHOWN}/cmux"),
    ("folder-complete", f"codex {SHOWN}/", "the disk's subfolders of a typed path as start rows",
     lambda rows, heads: any(row.startswith(f"Codex in {SHOWN}/") for row in rows)),
    # A word of a chat title the device's chat index holds (the capture host's own chats).
    ("chat-search", "flicker", "a chat the device's chat index finds, under Chats",
     lambda rows, heads: "Chats" in heads),
    ("prompt", "claude why is the build slow", "a prompt after an agent's name stays a prompt",
     lambda rows, heads: bool(rows) and rows[0].startswith("Ask ")),
]
TYPED = "codex ~/fun/cmux omnibar typing latency check claude why is the build slow opencode in ~/code/site notes "


def wait(predicate, seconds, step=0.25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # polling the app's socket (harness, not app code)
    return None


def seed_folders():
    for name in FOLDERS:
        path = os.path.join(DEMO, name)
        os.makedirs(os.path.join(path, "src"), exist_ok=True)
        if not os.path.isdir(os.path.join(path, ".git")):
            subprocess.run(["git", "init", "-q", path], check=True)


seed_folders()
app = BenchApp(opts.app, out=OUT)
app.launch()
rpc = app.rpc
failures = []


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label} {detail}", flush=True)
    if not ok:
        failures.append(label)


def key(name, modifiers=()):
    params = {"key": name, "modifiers": list(modifiers), "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)}
    # A Chromium page takes keys in its own page window: without `target: page` the key goes to the shell
    # window's responder, which is not the page (agent-engine-bench.py does the same).
    params.update(TARGET)
    return rpc("debug.key", params)


def page(action, **params):
    return rpc("debug.agent_pane", {"action": action, **params})


def options():
    found = page("query", selector='.nt-rows [role="option"] .nt-row-title').get("elements") or []
    return [item.get("text", "") for item in found]


def headers():
    return [item.get("text", "") for item in page("query", selector=".nt-section").get("elements") or []]


FIELD = {"length": 0}


def clear_field():
    # Cmd-A is an app chord the key router takes, not the page's: Delete once per typed character.
    for _ in range(FIELD["length"] + 2):
        key("delete")
    FIELD["length"] = 0


def type_text(text, gap=0.0):
    FIELD["length"] += len(text)
    for character in text:
        key("space" if character == " " else character)
        if gap:
            time.sleep(gap)  # a typist's pace between keys (harness, not app code)


try:
    # The Home workspace settles first (its Chief chat opens beside it), then a workspace of our own.
    wait(lambda: len(((rpc("debug.focus").get("windows") or [{}])[0].get("topology") or [])) >= 2, 20)
    made = rpc("action.run", {"action": "workspace.newAtBottom", "focus": True})
    check("workspace.newAtBottom", "error" not in json.dumps(made)[:200], json.dumps(made)[:160])
    for name in FOLDERS:
        split = rpc("action.run", {"action": "splitLeft", "args": {"cwd": os.path.join(DEMO, name)}})
        check(f"terminal in {name}", "error" not in json.dumps(split)[:200], json.dumps(split)[:120])
    # The page opens full width in a workspace of its own; the terminals stay open in the first one.
    rpc("action.run", {"action": "workspace.newAtBottom", "focus": True})
    TARGET = {}

    def open_ready():
        rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
        return wait(lambda: page("composer_focused").get("focused") or page("query", selector=".nt-field").get("elements"), 20)

    ready = open_ready()
    engine = page("engine")
    TARGET = {"target": "page", "pane": engine.get("pane")} if engine.get("engine") == "cef" else {}
    check("New Tab page ready before the first key", bool(ready))
    focus = page("focus_composer")
    check("its field has the caret", "error" not in json.dumps(focus)[:200], json.dumps(focus)[:120])

    if opts.typing_keys:
        reset = page("reset_typing")
        check("typing counter reset on the page that gets the keys", reset.get("keys") == 0, json.dumps(reset)[:120])
        # One text typed on, as a person writes, so every key is a keydown into the field and its rows.
        text = (TYPED * (opts.typing_keys // len(TYPED) + 1))[: opts.typing_keys]
        type_text(text, opts.key_gap)
        time.sleep(1)  # the last key's frame and paint (harness, not app code)
        stats = page("typing_stats")
        stats.pop("native_posts", None)
        json.dump(stats, open(os.path.join(OUT, "typing.json"), "w"), indent=2)
        check("typing counter counted the keys", (stats.get("keys") or 0) >= opts.typing_keys * 0.9, json.dumps(stats)[:600])
        clear_field()

    if not opts.no_shots:
        for theme in [t for t in opts.themes.split(",") if t]:
            done = rpc("settings.set", {"path": "appearance.appTheme", "value": THEMES[theme]})
            check(f"{theme}: app theme", "error" not in json.dumps(done)[:200], json.dumps(done)[:120])
            for name, text, what, expect in SCENARIOS:
                clear_field()
                type_text(text)
                wait(lambda: expect(options(), headers()), 4)
                time.sleep(0.4)  # the frame after the late sources (harness, not app code)
                rows, heads = options(), headers()
                path = os.path.join(OUT, f"{theme}-{name}.png")
                shot = rpc("debug.window_snapshot", {"kind": "main", "path": path})
                check(f"{theme}-{name}: {what}", "path" in shot and expect(rows, heads), f"rows={rows[:6]} headers={heads}")
            clear_field()
        if opts.native:
            rpc("settings.set", {"path": "tabs.nativeNewTabPage", "value": True})
            TARGET = {}  # the native page's field is in the shell window
            for theme in [t for t in opts.themes.split(",") if t]:
                rpc("settings.set", {"path": "appearance.appTheme", "value": THEMES[theme]})
                rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
                time.sleep(1.5)  # the native page shows and its field takes the keyboard (harness)
                for name, text, what, _ in SCENARIOS[:3]:
                    clear_field()
                    type_text(text)
                    time.sleep(0.6)  # the rows' frame (harness)
                    path = os.path.join(OUT, f"native-{theme}-{name}.png")
                    shot = rpc("debug.window_snapshot", {"kind": "main", "path": path})
                    check(f"native-{theme}-{name}: {what}", "path" in shot, json.dumps(shot)[:120])
finally:
    app.stop()
print("FAILED: " + ", ".join(failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
