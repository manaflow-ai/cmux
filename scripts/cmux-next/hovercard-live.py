#!/usr/bin/env python3
"""Live check: the workspace hover card says how long a row has worked, live, and what it works
on (cx-swovq, Lawrence 2026-10-14: "on hover it needs to show how long it has been working on and
other useful information").

  scripts/cmux-next/hovercard-live.py --tag <tag> [--shots DIR] [--capture SCRIPT --pid PID]

Attaches to a running tagged app (it never launches or quits one, and never opens Home or the
Chief pane). It makes a workspace whose program reports `working` over OSC 7501 and one that
runs a plain `sleep`, pins each one's hover card (`workspace.showResources`, the same card the
pointer opens) and reads the card's text (`debug.hover_cards` card_text). Checks:

  working:  the status line carries an elapsed time ("Agent running · 3s") and it grows while
            the card shows (a live tick, read twice 2.5 s apart);
  waiting:  the same program reports `blocked` with a message; the card says why it waits and
            its time starts again;
  idle:     once the card is dismissed, the card's tick no longer wakes the app
            (`debug.wakeups` ledger owner sidebar.hover-card.elapsed stops counting).

With --capture (the host's capture tool, $NX_CAPTURE) and --pid it writes PNGs of the window with
the card to --shots. Exits 1 when a check fails.
"""
import argparse, json, os, re, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--shots", help="write window captures with the card here")
parser.add_argument("--capture", help="the host capture script ($NX_CAPTURE)")
parser.add_argument("--pid", type=int, help="the app's pid, for captures")
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
OWNER = "sidebar.hover-card.elapsed"
ELAPSED = re.compile(r"· (?:(\d+)h ?)?(?:(\d+)m ?)?(?:(\d+)s)?$")
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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


def cli(*args):
    env = dict(os.environ, CMUX_TAG=opts.tag)
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], env=env, capture_output=True, text=True, timeout=60)


def terminals():
    return [word for word in cli("terminal", "list").stdout.split() if word.startswith("term_")]


def focused_terminal():
    snap = rpc("snapshot.get") or {}
    topology = snap.get("topology") or snap
    tab_id = (topology.get("focus") or {}).get("tab")
    for ws in topology.get("workspaces") or []:
        for screen in ws.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    if tab.get("id") == tab_id:
                        return next((v for v in tab.values() if isinstance(v, str) and v.startswith("term_")), None)
    return None


def new_workspace(name):
    """A new workspace named `name`, focused, and its terminal."""
    before = set(terminals())
    rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:  # bounded wait for the workspace's shell
        terminal = focused_terminal()
        if terminal and terminal not in before:
            cli("workspace", "current", "rename", name)
            time.sleep(1.0)  # the shell draws its first prompt
            return terminal
        time.sleep(0.5)
    return None


def write(terminal, text):
    return cli("terminal", terminal, "write", "--text", text + "\n")


def card_text():
    report = rpc("debug.hover_cards") or {}
    return report.get("card_text") or "", report


def pin_card(expect, seconds=10):
    """Pins the current workspace's card and returns its text once `expect(text)` holds."""
    deadline = time.monotonic() + seconds
    text = ""
    while time.monotonic() < deadline:  # bounded wait for the row to show the reported state
        reply = rpc("action.run", {"action": "workspace.showResources", "origin": "script"})
        if isinstance(reply, dict) and reply.get("error"):
            print(f"showResources: {reply}", flush=True)
        time.sleep(0.6)  # the card's dwell; the pin shows it at once, the panel lays out
        text, _ = card_text()
        if expect(text):
            return text
    return text


def elapsed_seconds(line):
    match = ELAPSED.search(line.strip())
    if not match or not any(match.groups()):
        return None
    h, m, s = (int(g) if g else 0 for g in match.groups())
    return h * 3600 + m * 60 + s


def status_line(text):
    lines = text.split("\n")
    return lines[1] if len(lines) > 1 else ""


def shot(name):
    if not (opts.shots and opts.capture and opts.pid):
        return
    os.makedirs(opts.shots, exist_ok=True)
    out = os.path.join(opts.shots, name)
    run = subprocess.run(["bash", opts.capture, "shot", "--pid", str(opts.pid), "--with-popups", "--out", out],
                         capture_output=True, text=True, timeout=60)
    print(f"capture {name}: exit {run.returncode} {run.stderr.strip()[:200]}", flush=True)


def ticks():
    ledger = (rpc("debug.wakeups") or {}).get("ledger") or []
    return sum(entry.get("count", 0) for entry in ledger if entry.get("owner") == OWNER)


def dismiss():
    rpc("debug.hover_cards", {"dismiss": True})


working = new_workspace("hc-working")
check(working is not None, "made the working workspace")
if working:
    # The program reads a line between its reports, so each step is one newline into its stdin.
    # OSC 7501 carries `title` and `msg` as base64: "Refactoring the parser", "Which branch should I use?".
    demo = f"/tmp/hovercard-demo-{opts.tag}.sh"
    with open(demo, "w") as script:
        script.write("printf '\\033]7501;state=working:app=hcdemo:title=UmVmYWN0b3JpbmcgdGhlIHBhcnNlcg==\\033\\\\'\n"
                     "read step\n"
                     "printf '\\033]7501;state=blocked:kind=question:app=hcdemo:msg=V2hpY2ggYnJhbmNoIHNob3VsZCBJIHVzZT8=\\033\\\\'\n"
                     "sleep 600\n")
    write(working, f"sh {demo}")
    first = pin_card(lambda t: elapsed_seconds(status_line(t)) is not None)
    print("card:\n" + first, flush=True)
    check(elapsed_seconds(status_line(first)) is not None, f"the status line carries an elapsed time ({status_line(first)!r})")
    shot("working-1.png")
    time.sleep(2.5)  # the live tick: the same card, read again later
    second, report = card_text()
    print("card later:\n" + second, flush=True)
    a, b = elapsed_seconds(status_line(first)), elapsed_seconds(status_line(second))
    check(a is not None and b is not None and b > a, f"the elapsed time grows while the card shows ({a} -> {b})")
    check(report.get("card_showing") == "true", "the card still shows")
    shot("working-2.png")

    write(working, "")  # the program's `read step`: it reports blocked next
    waiting = pin_card(lambda t: "Which branch" in t)
    print("waiting card:\n" + waiting, flush=True)
    check("Which branch should I use?" in waiting, "the card says why it waits (the program's words)")
    waited = elapsed_seconds(status_line(waiting))
    check(waited is not None and waited < 30, f"the waiting time starts over ({waited})")
    shot("waiting.png")

    before = ticks()
    dismiss()
    time.sleep(0.5)
    _, report = card_text()
    print(f"after dismiss: showing={report.get('card_showing')} phase={report.get('phase')}", flush=True)
    settled = ticks()
    time.sleep(3)  # an idle window: a stopped tick adds nothing
    after = ticks()
    check(report.get("card_showing") != "true", "the card is dismissed")
    check(after == settled, f"no card tick wakes the app once the card is gone ({before} -> {settled} -> {after})")

print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
