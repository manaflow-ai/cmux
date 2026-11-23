#!/usr/bin/env python3
"""Keydown to paint in the New Tab composer of a real tagged app, as the draft grows long and the session loads.

  scripts/cmux-next/new-tab-typing-live.py --app "<path>/cmux DEV <tag>.app" --out <dir>
      [--overlay DIR] [--drafts 0,60,180] [--keys 60] [--key-gap 0.09] [--label NAME]
      [--workspaces N] [--placeholder-workspaces N] [--title-churn N] [--new-tabs N] [--chats N] [--unthrottled]
      [--config JSON] [--cdp-port PORT [--probe]]

Lawrence 2026-11-19 (a video): "typing here is very laggy", a 180-character draft in the New Tab field, with 974
workspaces and 13 agents running. Runs on a Mac with a GUI session (a fleet mini or cmux-lawrence-2), never the
person's Mac.

- `--overlay DIR`: the web bundles of another tree (an `web-overlay.sh install` folder) served into this app
  through web-dev.json next to the bench's config, so one app build measures a before and an after.
- The load, made before the measured page opens: `--workspaces` new workspaces, each with a terminal (macOS
  allows 511 PTYs, so at most 510), `--placeholder-workspaces` more with no terminal (the person had 974 in all),
  `--title-churn` of their terminals renaming themselves every 100 ms (an agent's spinner title), `--new-tabs`
  more New Tab pages and `--chats` agent chats, each in a workspace of its own; `--unthrottled` keeps hidden
  pages' timers at full rate; `--config` is merged into the bench's cmux.json (the person's appearance).
- Opens a New Tab page in a workspace of its own (never Home: its Chief chat takes the keyboard), shown and
  focused by id, and waits until its field has the caret.
- For each draft length: types the draft (not measured), resets the page's typing counter, types `--keys`
  more keys at a typist's pace with `debug.key` stamped with the send time (CLOCK_UPTIME_RAW), so the wait
  for the app's main thread counts too, and reads `typing_stats` (perf.ts: keydown to frame, to paint, to
  the edit's work, and the native posts the keys made). Then deletes what it typed.
- `--cdp-port`: a CPU profile of the page over the longest draft's keys (cdp-page-profile.mjs); with `--probe`,
  the host's places pushes and the page's long tasks over every draft's keys instead (cdp-page-probe.mjs).

Writes <out>/new-tab-typing-<label>.json and prints one line per draft length.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--overlay", help="a web-overlay folder (manifest.json and the bundles) to serve")
parser.add_argument("--drafts", default="0,60,180", help="draft lengths typed before each measurement (a length may repeat)")
parser.add_argument("--keys", type=int, default=60)
parser.add_argument("--key-gap", type=float, default=0.09, help="seconds between keys (a fast typist)")
parser.add_argument("--label", default="run")
parser.add_argument("--chats", type=int, default=0, help="agent chat tabs opened first, each in a workspace of its own "
                    "(every chat page shares the New Tab page's renderer: cmux-process-per-site-schemes)")
parser.add_argument("--workspaces", type=int, default=0, help="extra workspaces (each with its terminal) opened first; "
                    "the person had 974")
parser.add_argument("--placeholder-workspaces", type=int, default=0,
                    help="extra empty workspaces (`workspace create --empty`: no tab, no terminal), opened after "
                         "--workspaces: macOS allows 511 PTYs (kern.tty.ptmx_max), so --workspaces stops at 510 and a "
                         "974-workspace session needs these for the rest")
parser.add_argument("--unthrottled", action="store_true", help="hidden chat pages' timers at full rate, so each page's "
                    "mock daemon changes chats as often as the real daemon's notices reach every page (Chromium slows "
                    "hidden pages' timers to 1 Hz, never socket messages)")
parser.add_argument("--title-churn", type=int, default=0, help="terminals (in the extra workspaces) whose title "
                    "changes every 100 ms, as Claude Code's spinner title does while it works (the person had 13 running)")
parser.add_argument("--new-tabs", type=int, default=0, help="extra New Tab pages opened first, each in a workspace of "
                    "its own (every one gets each places push)")
parser.add_argument("--config", help="JSON merged into the bench's cmux.json, e.g. the person's appearance")
parser.add_argument("--cdp-port", type=int, help="open the DevTools port and CPU-profile the page while the longest draft's keys are typed")
parser.add_argument("--no-marks", action="store_true",
                    help="with --trace: the page's key marks stay off (they append a timing element per key, which costs a "
                         "style pass of its own); the trace alone times the keys")
parser.add_argument("--trace", action="store_true",
                    help="with --cdp-port: a browser-wide Chromium trace (cdp-trace.mjs) over each draft's measured keys")
parser.add_argument("--probe", action="store_true", help="with --cdp-port: the places-push probe (cdp-page-probe.mjs) "
                    "while each draft's keys are typed, in place of the CPU profile")
opts = parser.parse_args()
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
# The video's draft: "is there " then a long run of home-row letters.
LETTERS = "asdfjklaslkdfjlkasdjflksajdflkasjflkajsdfkljaslkfjsalkfjsadasdjfklasdjflkjsafljsalkfsdjlkadjsflkafjsdasdfkl"
DRAFT = ("is there " + LETTERS * 4)


def wait(predicate, seconds, step=0.25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # polling the app's socket (harness, not app code)
    return None


switches = ([f"remote-debugging-port={opts.cdp_port}"] if opts.cdp_port else []) + (
    ["disable-background-timer-throttling", "disable-renderer-backgrounding", "disable-backgrounding-occluded-windows"]
    if opts.unthrottled else [])
env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": ":".join(switches)} if switches else None
config = {"appearance": {"backgroundOpacity": 1}}
for section, values in json.loads(opts.config or "{}").items():
    config[section] = values  # a section given replaces the bench's own (the person's appearance has no opacity)
app = BenchApp(opts.app, out=OUT, env=env, config=config)
if opts.overlay:
    with open(os.path.join(app.scratch, "web-dev.json"), "w") as f:
        json.dump({"overlay": os.path.abspath(opts.overlay)}, f)
app.launch()
rpc = app.rpc
TARGET = {}
typed = {"n": 0}


def key(name):
    params = {"key": name, "modifiers": [], "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW), **TARGET}
    return rpc("debug.key", params)


PAGE_PANE = {}


def page(action, **params):
    reply = rpc("debug.agent_pane", {"action": action, **PAGE_PANE, **params})
    if PAGE_PANE and isinstance(reply, dict) and "shows no agent tab" in str(reply.get("error", "")):
        print(f"page: {reply.get('error')}; using the focused pane", flush=True)
        PAGE_PANE.clear()
        reply = rpc("debug.agent_pane", {"action": action, **params})
    return reply


def workspaces():
    reply = rpc("snapshot.get")
    topology = (reply.get("topology") or {}) if isinstance(reply, dict) else {}
    return [w for w in topology.get("workspaces") or [] if w.get("id")]


def panes(workspace):
    return [p for s in (workspace or {}).get("screens") or [] for p in s.get("panes") or [] if not p.get("dock")]


def open_chats(count):
    """`count` agent chats, each in a new workspace's pane (palette.newAgentChat aimed at the pane, no focus), as a
    person with many chats open has; returns how many showed up as conversation tabs."""
    opened = 0
    for _ in range(count):
        before = {w["id"] for w in workspaces()}
        rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": True, "origin": "script"})
        made = wait(lambda: next((w for w in workspaces() if w["id"] not in before and panes(w)), None), 30)
        if not made:
            continue
        pane = panes(made)[0]["id"]
        rpc("action.run", {"action": "palette.newAgentChat", "args": {}, "focus": False, "origin": "script",
                           "target": f"pane:{pane}"})
        chat = wait(lambda: any(t.get("kind") == "conversation" for w in workspaces() if w["id"] == made["id"]
                                for p in panes(w) for t in p.get("tabs") or []), 20, step=0.1)
        opened += 1 if chat else 0
    return opened


def field_length():
    """The New Tab field's whole text length: the query's `length` past 120 characters, else its text's."""
    field = page("query", selector=".nt-field [contenteditable='true']")
    elements = field.get("elements") or [] if isinstance(field, dict) else []
    return sum(int(e["length"]) if isinstance(e.get("length"), (int, float)) else len(str(e.get("text", "")))
               for e in elements if isinstance(e, dict))


def type_text(text, gap):
    for character in text:
        key("space" if character == " " else character)
        typed["n"] += 1
        if gap:
            time.sleep(gap)  # a typist's pace between keys (harness, not app code)


results = {"label": opts.label, "overlay": opts.overlay, "config": config, "keys": opts.keys, "drafts": {}}
try:
    wait(lambda: len(((rpc("debug.focus").get("windows") or [{}])[0].get("topology") or [])) >= 2, 20)
    if opts.workspaces:
        start = time.monotonic()
        have = len(workspaces())
        for index in range(opts.workspaces):
            rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"})
            if index % 50 == 49:
                wait(lambda: len(workspaces()) >= have + index + 1, 60)
        results["workspaces"] = len(wait(lambda: (lambda w: w if len(w) >= have + opts.workspaces else None)(workspaces()), 120) or workspaces())
        print(f"workspaces: {results['workspaces']} in {time.monotonic() - start:.0f} s", flush=True)
        time.sleep(3.0)  # the new workspaces' terminals start (harness, not app code)
    if opts.placeholder_workspaces:
        start = time.monotonic()
        have = len(workspaces())
        cli_env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        cli_env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(app.scratch, "cmux.json")
        failures = 0
        for index in range(opts.placeholder_workspaces):
            # An empty workspace (the daemon's create-workspace with no first tab): no terminal, so no PTY.
            done = subprocess.run([app.cli, "--app-socket", app.socket, "workspace", "create", "--empty", "--name", f"bench {index}"],
                                  env=cli_env, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            if done.returncode != 0:
                failures += 1
                if failures <= 3:
                    print(f"placeholder workspace {index}: {(done.stdout + done.stderr).strip()[-300:]}", flush=True)
        listed = wait(lambda: (lambda w: w if len(w) >= have + opts.placeholder_workspaces else None)(workspaces()), 180) or workspaces()
        results["placeholder_workspaces"] = len(listed) - have
        results["placeholder_failures"] = failures
        results["workspaces_total"] = len(listed)
        print(f"placeholder workspaces: {len(listed) - have} in {time.monotonic() - start:.0f} s, {len(listed)} in all, "
              f"{failures} failed", flush=True)
    if opts.title_churn:
        spinner = "while :; do for c in 1 2 3 4 5 6 7 8 9 10; do printf '\\033]0;%s Working on the task\\007' $c; sleep 0.1; done; done\n"
        started = 0
        for workspace in workspaces():
            if started >= opts.title_churn:
                break
            terminal = next((t for p in panes(workspace) for t in p.get("tabs") or [] if t.get("kind") == "terminal" and t.get("id")
                             and not str(t.get("id")).startswith("pending_")), None)
            if not terminal:
                continue
            rpc("action.run", {"action": "terminal.sendText", "args": {"text": spinner}, "focus": False, "origin": "script",
                               "target": f"tab:{terminal['id']}"})
            started += 1
        results["title_churn"] = started
        print(f"title churn: {started} terminals", flush=True)
    if opts.new_tabs:
        made = 0
        for _ in range(opts.new_tabs):
            before = {w["id"] for w in workspaces()}
            rpc("action.run", {"action": "workspace.newAtBottom", "args": {}, "focus": False, "origin": "script"})
            ws = wait(lambda: next((w for w in workspaces() if w["id"] not in before and panes(w)), None), 30)
            if not ws:
                continue
            rpc("action.run", {"action": "newTab.page", "args": {}, "focus": False, "origin": "script",
                               "target": f"pane:{panes(ws)[0]['id']}"})
            made += 1
        time.sleep(3.0)  # the pages load (harness, not app code)
        if opts.cdp_port:
            import urllib.request
            targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{opts.cdp_port}/json", timeout=10))
            results["agent_pages"] = len([t for t in targets if t.get("type") == "page" and "cmux.agent" in t.get("url", "")])
        results["new_tabs"] = made
        print(f"new tab pages opened: {made}; agent pages in Chromium: {results.get('agent_pages')}", flush=True)
    if opts.chats:
        results["chats"] = open_chats(opts.chats)
        print(f"chats open: {results['chats']} of {opts.chats}", flush=True)
        time.sleep(3.0)  # the chat pages' first renders (harness, not app code)
        if opts.cdp_port:
            import urllib.request
            targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{opts.cdp_port}/json", timeout=10))
            pages = [t for t in targets if t.get("type") == "page" and "cmux.agent" in t.get("url", "")]
            results["agent_pages"] = len(pages)
            renderers = subprocess.run(["pgrep", "-f", "--", "--type=renderer"], capture_output=True, text=True).stdout.split()
            print(f"agent pages in Chromium: {len(pages)}; renderer processes on the host: {len(renderers)}", flush=True)
    before = {w["id"] for w in workspaces()}
    rpc("action.run", {"action": "workspace.newAtBottom", "focus": True})
    measured = wait(lambda: next((w for w in workspaces() if w["id"] not in before and panes(w)), None), 30)
    if measured:
        # Shown and focused by id: with many workspaces made first, focus may not follow the new one.
        rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": measured["id"]}, "focus": True, "origin": "script"})
        rpc("action.run", {"action": "pane.focus", "args": {}, "focus": True, "origin": "script",
                           "target": f"pane:{panes(measured)[0]['id']}"})
        PAGE_PANE["pane"] = panes(measured)[0]["id"]
    rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
    ready = wait(lambda: page("composer_focused").get("focused") or page("query", selector=".nt-field").get("elements"), 30)
    engine = page("engine")
    TARGET = {"target": "page", "pane": engine.get("pane")} if engine.get("engine") == "cef" else {}
    if not ready:
        raise SystemExit("the New Tab page did not get ready")
    page("focus_composer")
    results["engine"] = engine.get("engine")
    for length in [int(n) for n in opts.drafts.split(",") if n]:
        # The field keeps the caret before each draft: a loaded page can drop it (a places push remounts nothing,
        # but a click elsewhere or a late adopt does). A native click on the field, as a person's, when it lost it.
        # `composer_focused` reads the chat composer (`.acpmux-composer`), which a New Tab page does not have: the
        # check is whether a typed probe key lands in the New Tab field (`.nt-field`), then is deleted.
        def caret():
            before = field_length()
            key("z")
            landed = wait(lambda: field_length() != before, 2, step=0.1)
            key("delete")
            wait(lambda: field_length() == before, 2, step=0.1)
            if landed:
                return True
            page("click", selector=".nt-field [contenteditable='true']")
            return False
        if not wait(caret, 20, step=0.5):
            print(f"draft {length}: the field never took the caret", flush=True)
        type_text(DRAFT[:length], 0.02)
        time.sleep(1.0)  # the draft's last frame (harness, not app code)
        field = page("query", selector=".nt-field")
        texts = [str(e.get("text", ""))[:40] for e in (field.get("elements") or []) if isinstance(e, dict)]
        print(f"draft {length}: field {texts}", flush=True)
        if not opts.no_marks:
            page("reset_typing")
        rpc("debug.hangs", {"clear": True})
        before_keys = field_length()
        profiler = None
        if opts.cdp_port and opts.trace:
            node = os.environ.get("NODE") or shutil.which("node") or "node"
            seconds = opts.keys * (opts.key_gap + 0.03) + 2
            profiler = subprocess.Popen([node, os.path.join(os.path.dirname(os.path.abspath(__file__)), "cdp-trace.mjs"),
                                         str(opts.cdp_port), f"{seconds:.1f}",
                                         os.path.join(OUT, f"trace-{opts.label}-{length}.json")]
                                        + ([os.environ["CMUX_TRACE_CATEGORIES"]] if os.environ.get("CMUX_TRACE_CATEGORIES") else []),
                                        stdout=subprocess.PIPE, text=True)
            time.sleep(2.0)  # tracing starts before the first measured key (harness, not app code)
        elif opts.cdp_port and opts.probe:
            node = os.environ.get("NODE") or shutil.which("node") or "node"
            seconds = opts.keys * (opts.key_gap + 0.03) + 2
            profiler = subprocess.Popen([node, os.path.join(os.path.dirname(os.path.abspath(__file__)), "cdp-page-probe.mjs"),
                                         str(opts.cdp_port), f"{seconds:.1f}"], stdout=subprocess.PIPE, text=True)
            time.sleep(1.5)  # the probe attaches before the first measured key (harness, not app code)
        elif opts.cdp_port and length == max(int(n) for n in opts.drafts.split(",") if n):
            node = os.environ.get("NODE") or shutil.which("node") or "node"
            seconds = opts.keys * (opts.key_gap + 0.03) + 2
            profiler = subprocess.Popen([node, os.path.join(os.path.dirname(os.path.abspath(__file__)), "cdp-page-profile.mjs"),
                                         str(opts.cdp_port), f"{seconds:.1f}",
                                         os.path.join(OUT, f"page-{opts.label}-{length}.cpuprofile")],
                                        stdout=subprocess.PIPE, text=True)
            time.sleep(1.5)  # the profiler attaches before the first measured key (harness, not app code)
        type_text(LETTERS[: opts.keys] if opts.keys <= len(LETTERS) else (LETTERS * 3)[: opts.keys], opts.key_gap)
        time.sleep(1.5)  # the last key's frame and paint (harness, not app code)
        if profiler:
            text, _ = profiler.communicate(timeout=120)
            results.setdefault("profile", {})[length] = text
            print(text, flush=True)
        stats = {} if opts.no_marks else page("typing_stats")
        # The measured keys typed into the field (else to_paint is not a key's text paint).
        # The page's query cuts an element's text at 120 characters and answers the whole `length` past that
        # (PageWebView+DebugProbe.swift), so a long draft's growth is read too: a lost key reads short.
        stats["typed_chars"] = field_length() - before_keys
        hangs = rpc("debug.hangs", {"limit": 20}) or {}
        stats["hangs"] = {k: hangs.get(k) for k in ("count", "max_ms", "total_ms", "max_gap_ms")}
        stats["long_hangs"] = [r for r in (hangs.get("records") or []) if isinstance(r, dict) and (r.get("duration_ms") or 0) >= 250]
        posts = stats.pop("native_posts", None)
        stats["native_posts"] = posts if isinstance(posts, (int, float)) else (len(posts) if isinstance(posts, list) else posts)
        results["drafts"][length] = stats
        paint = stats.get("to_paint") or {}
        listener = stats.get("to_listener") or {}
        work = stats.get("to_work") or {}
        sub = stats.get("to_submitted") or {}
        print(
            f"draft {length:4d}: keys {stats.get('keys')} to_paint p50 {paint.get('p50_ms')} p95 {paint.get('p95_ms')} "
            f"max {paint.get('max_ms')} | to_listener p50 {listener.get('p50_ms')} p95 {listener.get('p95_ms')} | "
            f"to_work p50 {work.get('p50_ms')} p95 {work.get('p95_ms')} | to_submitted p50 {sub.get('p50_ms')} p95 {sub.get('p95_ms')} | "
            f"typed {stats['typed_chars']} of {opts.keys} | hangs {stats['hangs']} long {len(stats['long_hangs'])} | native posts {stats['native_posts']}",
            flush=True,
        )
        for _ in range(typed["n"] + 2):
            key("delete")
        typed["n"] = 0
        time.sleep(0.8)  # the cleared field's frame (harness, not app code)
finally:
    app.stop()
path = os.path.join(OUT, f"new-tab-typing-{opts.label}.json")
with open(path, "w") as f:
    json.dump(results, f, indent=2)
print(f"wrote {path}")
