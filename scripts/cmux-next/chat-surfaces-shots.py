#!/usr/bin/env python3
"""Chat surfaces, before and after: one chat with every content surface, shot in each window style.

  scripts/cmux-next/chat-surfaces-shots.py --app LABEL=APP [--app LABEL=APP ...] --out DIR [--only SUBSTRING]

GUI host only (scripts/measure/chat-surfaces.sh runs it in a fleet Mac's console session); never a laptop.
For each app and each scenario it launches the app on a scratch HOME (no activation, automation socket,
direct launch as a fleet step needs), adds acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py) as
a harness, and makes one chat on it: a "surfaces-tour" turn (a plan, a shell call with its output, a new
55-line PROPOSAL.md: the edited-files card, and a reply with inline code, a code block and a table), then an
"overloaded:" turn the agent fails (the turn error card, "... is rate limited or out of capacity"). It opens the
chat as a workspace and writes the window as the window server composites it (`debug.window_snapshot`):

  DIR/LABEL-SCENARIO.png       SCENARIO is THEME-STYLE: dark|light x opaque|see-through|wallpaper

  opaque        background-opacity 1: the page paints the theme's page colour
  see-through   background-opacity 0.6: the page is clear over the window's glass and the desktop
  wallpaper     appearance.background dore-leviathan: the page is clear over a painting in the window

design/chat-surfaces.md says what to look for: the edit card and the error card on one fill and one line.
DIR/results.json lists each shot and what failed.
"""
import argparse, json, os, shlex, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (the launch, the control socket and the test-agent harness)

AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
THEMES = {
    "dark": "background = #1d1f21\nforeground = #e6e6e6\n",
    "light": "background = #fafafa\nforeground = #1d1d1f\n",
}
STYLES = {
    "opaque": ("background-opacity = 1\n", {}),
    "see-through": ("background-opacity = 0.6\n", {}),
    "wallpaper": ("", {"appearance": {"background": "dore-leviathan"}}),
}

parser = argparse.ArgumentParser()
parser.add_argument("--app", action="append", required=True, help="LABEL=PATH of a built app, e.g. before=/x/cmux.app")
parser.add_argument("--out", required=True)
parser.add_argument("--only", default="")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)


def say(*parts):
    print(*parts, flush=True)


def shoot(label: str, bundle: str, theme: str, style: str) -> dict:
    name = f"{label}-{theme}-{style}"
    ghostty_text, config = STYLES[style]
    row = {"shot": name, "app": bundle}
    scratch_files = os.path.join(opts.out, ".scratch", name)
    os.makedirs(scratch_files, exist_ok=True)
    ghostty = os.path.join(scratch_files, "ghostty")
    with open(ghostty, "w") as handle:
        handle.write(THEMES[theme] + ghostty_text)
    project = os.path.join(scratch_files, "project")
    os.makedirs(project, exist_ok=True)
    env = {"CMUX_NEXT_GHOSTTY_CONFIG": ghostty, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1180,900",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last"}
    pid, sock, scratch = bm.launch(bundle, config, extra_env=env, direct=True)
    try:
        app = bm.App(bundle, sock)
        for _ in range(60):
            if app.ping():
                break
            time.sleep(1)  # test script: the app answers its socket
        chats = bm.FakeChats(app, bundle, AGENT)
        made = subprocess.run([app.cli_path, "acp", "new", "--json", "-d", "-m", bm.FAKE_AGENT_ID, "--cwd", project,
                               "surfaces-tour"], capture_output=True, text=True, timeout=120, env=chats.env)
        session = json.loads(made.stdout)["sessionId"]
        failed = subprocess.run([app.cli_path, "acp", "send", "--json", session, "overloaded: now"],
                                capture_output=True, text=True, timeout=120, env=chats.env)
        row["second_turn_exit"] = failed.returncode  # the agent fails it: the error card
        opened = app.action("agent.openSessionWorkspace", focus=True, session=session)
        row["opened"] = {k: opened.get(k) for k in ("created", "error") if k in opened}
        time.sleep(8)  # proof capture: the chat page loads its transcript and paints it
        path = os.path.join(opts.out, name + ".png")
        snap = app.call("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
        row["snapshot"] = snap
        row["ok"] = os.path.exists(path) and not snap.get("error")
    except Exception as error:  # one scenario's failure is reported; the matrix goes on
        row["ok"] = False
        row["error"] = f"{type(error).__name__}: {error}"[:400]
    finally:
        bm.end_bundle(bundle)
        time.sleep(3)  # test harness: the app's daemons end before the next launch
    say(json.dumps(row)[:400])
    return row


rows = []
for entry in opts.app:
    label, _, bundle = entry.partition("=")
    for theme in THEMES:
        for style in STYLES:
            if opts.only and opts.only not in f"{label}-{theme}-{style}":
                continue
            rows.append(shoot(label, bundle, theme, style))
with open(os.path.join(opts.out, "results.json"), "w") as handle:
    json.dump(rows, handle, indent=2)
bad = [row["shot"] for row in rows if not row.get("ok")]
say(f"chat-surfaces-shots: {len(rows) - len(bad)} of {len(rows)} shots" + (f"; failed: {', '.join(bad)}" if bad else ""))
sys.exit(1 if bad or not rows else 0)
