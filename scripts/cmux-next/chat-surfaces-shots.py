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
  DIR/LABEL-SCENARIO-hover-KEY.png   with --hovers: the window with the pointer on one control (HOVERS below), moved
                               there by `debug.page hover` (a real tracking-area hover); the reply's x, y are in results.json

  opaque        background-opacity 1: the page paints the theme's page colour
  see-through   background-opacity 0.6: the page is clear over the window's glass and the desktop
  wallpaper     appearance.background dore-leviathan: the page is clear over a painting in the window

design/chat-surfaces.md says what to look for: the edit card and the error card on one fill and one line.
DIR/results.json lists each shot and what failed.
"""
import argparse, hashlib, json, os, shlex, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (the launch, the control socket and the test-agent harness)
from state_wait import wait_stable, wait_until  # noqa: E402

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
parser.add_argument("--hovers", action="store_true", help="also shoot each control in HOVERS under the pointer")
opts = parser.parse_args()
# The chat's controls whose hover fill moved to the host's hover (design/chat-surfaces.md): KEY -> selector.
HOVERS = {
    "edited-file": "button.acpmux-edited-file",
    "edited-head": ".acpmux-edited-head[data-interactive]",
    "edited-undo": ".acpmux-edited-undo",
    "review-changes": ".acpmux-review-changes",
    "card-copy": ".cv-card-copy__button",
    "expand-row": ".cv-expand-row",
    "turn-retry": ".cv-turn-retry .cv-iconbtn",
}
os.makedirs(opts.out, exist_ok=True)


def say(*parts):
    print(*parts, flush=True)


def transcript_drawn(app) -> bool:
    """A shown chat page (cmux.agent, not parked) has drawn this chat's turns: its edit card or the failed turn."""
    for listed in app.call("debug.page", {"page": "cmux.agent", "action": "list"}).get("pages", []):
        if listed.get("parked"):
            continue
        found = app.call("debug.page", {"page": "cmux.agent", "instance": listed.get("instance"), "action": "query",
                                        "selector": ".acpmux-edited, .cv-turn-retry"})
        if found.get("elements"):
            return True
    return False


def main_hash(app, scratch_files: str) -> str:
    """A hash of the main window's picture (debug.window_snapshot to a scratch file)."""
    path = os.path.join(scratch_files, "settle.png")
    snap = app.call("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
    if snap.get("error"):
        raise RuntimeError(snap["error"])
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


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
        # A fresh HOME starts on Home, and the open leaves it in front: show the newest workspace, the chat's
        # (the sidebar lists Home, App Store, then the workspaces in the order they were made).
        for _ in range(20):  # the first launch's window may not list the new workspace yet: "no workspace to act on"
            row["selected"] = app.action("workspace.selectLast", focus=True).get("error") or "ok"
            if row["selected"] == "ok":
                break
            time.sleep(0.5)  # test harness: the workspace the open made reaches the window
        # The chat page loads its transcript and paints it: its turns are in the page, then the window holds still.
        if not wait_until(lambda: transcript_drawn(app), "the chat page's transcript", timeout=30, interval=0.25,
                          raise_on_timeout=False):
            row["transcript_wait"] = "no edit card or failed turn in a shown chat page within 30 s"
        wait_stable(lambda: main_hash(app, scratch_files), "the main window with the chat", timeout=15,
                    interval=0.2, reads=2, raise_on_timeout=False)
        path = os.path.join(opts.out, name + ".png")
        snap = app.call("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
        row["snapshot"] = snap
        row["ok"] = os.path.exists(path) and not snap.get("error")
        if opts.hovers:
            row["hovers"] = {}
            # Home's Chief is a cmux.agent page too: hover in the one that draws this chat's edit card.
            chat_page = None
            for _ in range(20):
                for listed in app.call("debug.page", {"page": "cmux.agent", "action": "list"}).get("pages", []):
                    if listed.get("parked"):
                        continue
                    found = app.call("debug.page", {"page": "cmux.agent", "instance": listed.get("instance"),
                                                    "action": "query", "selector": ".acpmux-edited"})
                    if found.get("elements"):
                        chat_page = listed.get("instance")
                        break
                if chat_page is not None:
                    break
                time.sleep(0.5)  # test harness: the chat's page draws its transcript
            row["chat_page"] = chat_page
            for key, selector in HOVERS.items():
                page = {"page": "cmux.agent", "instance": chat_page, "selector": selector}
                scrolled = app.call("debug.page", {**page, "action": "scroll", "block": "center"}, timeout=20)
                time.sleep(0.5)  # proof capture: the scroll settles before the pointer moves
                hovered = app.call("debug.page", {**page, "action": "hover"}, timeout=20)
                time.sleep(0.6)  # proof capture: the hover fill's transition ends
                shot = os.path.join(opts.out, f"{name}-hover-{key}.png")
                taken = app.call("debug.window_snapshot", {"kind": "main", "path": shot}, timeout=60)
                row["hovers"][key] = {"scroll": scrolled, "hover": hovered, "shot": os.path.exists(shot) and not taken.get("error")}
    except Exception as error:  # one scenario's failure is reported; the matrix goes on
        row["ok"] = False
        row["error"] = f"{type(error).__name__}: {error}"[:400]
    finally:
        bm.end_bundle(bundle)
        # The app's daemons end before the next launch: no process of the bundle is left.
        if not wait_until(lambda: not bm.bundle_pids(bundle), "the bundle's processes to end", timeout=15,
                          interval=0.1, raise_on_timeout=False):
            say(f"{name}: processes of {bundle} still run 15 s after the end: {sorted(bm.bundle_pids(bundle))}")
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
