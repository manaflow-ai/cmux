#!/usr/bin/env python3
"""PTY size vs rendered grid for a tagged cmux-next build.

Runs random layout changes (splits, closes, sidebar, zoom, density, font
size, equalize, a workspace round trip) and foreign geometry claims (a second
daemon client attaches to the focused terminal, claims canonical geometry at
another size and leaves; a Mac resize or key press must take it back, tmux
"window-size latest"), then checks every visible terminal: `stty size`
and `$COLUMNS` inside the shell must equal the grid the Ghostty mirror
renders (`debug.surfaces`). A mismatch is what leaves zsh's PROMPT_SP `%`
mark on its own line after Ctrl-C.

  scripts/cmux-next/pty-size-e2e.py --tag <tag> [--ops 30] [--seed 1] [--claim-rate 0.25] [--settle 1.0]

The tagged app must be running (launched with CMUX_NEXT_SOCKET_MODE=automation).
Exit 1 on any mismatch after an op has settled.
"""
import argparse, glob, json, os, queue, random, re, socket, subprocess, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--ops", type=int, default=30)
parser.add_argument("--seed", type=int, default=1)
parser.add_argument("--claim-rate", type=float, default=0.25, help="share of ops that are foreign geometry claims")
parser.add_argument("--settle", type=float, default=1.0, help="seconds to wait after an op before checking")
parser.add_argument("--cli", help="cmux CLI inside the tagged app (default: found in DerivedData)")
opts = parser.parse_args()
random.seed(opts.seed)
MARKERS = random.SystemRandom()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = opts.cli or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app/Contents/Resources/bin/cmux")))), None)
if not CLI:
    sys.exit(f"no tagged CLI for {opts.tag}; pass --cli")
TMP = os.environ.get("TMPDIR", "/tmp")
DAEMON = next(iter(glob.glob(os.path.join(TMP, "cmux-tui-*", f"cmux-app-{opts.tag}.sock"))), None)
ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin",
       "TMPDIR": TMP, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}


def cli(*args):
    return subprocess.run([CLI, "--socket", SOCKET, *args], capture_output=True, text=True, timeout=30, env=ENV)


def rpc(method, params=None):
    r = cli("rpc", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def action(name):
    return rpc("action.run", {"id": name})


class Daemon:
    """A second cmux-tui client on the tag's daemon socket (line JSON). A
    reader thread drains the socket, so attached-surface output never backs
    up and gets the client disconnected while the checks run."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(DAEMON)
        self.file = self.sock.makefile("rwb")
        self.next_id = 0
        self.replies = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            for line in self.file:
                reply = json.loads(line)
                if "id" in reply or reply.get("ok") is False:
                    self.replies.put(reply)
        except (OSError, ValueError):
            pass
        self.replies.put(None)

    def request(self, cmd, **fields):
        self.next_id += 1
        self.file.write((json.dumps({"id": self.next_id, "cmd": cmd, **fields}) + "\n").encode())
        self.file.flush()
        while True:
            reply = self.replies.get(timeout=10)
            if reply is None:
                raise RuntimeError("daemon closed the connection")
            if reply.get("id") == self.next_id or reply.get("ok") is False:
                return reply

    def close(self):
        self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()


def visible_terminals():
    """(pane key, surface ref, rendered cols, rendered rows) per visible terminal pane."""
    refs = {}
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if m:
            refs["pane_" + m.group(2).replace("-", "").lower()] = m.group(1)
    result = []
    for window in rpc("debug.surfaces").get("windows", []):
        for pane in window["panes"]:
            surface = pane.get("surface") or {}
            grid = surface.get("grid")
            if pane["kind"] != "terminal" or pane["presence"] != "visible" or not grid or pane["pane"] not in refs:
                continue
            tabs = cli("list-pane-surfaces", "--pane", refs[pane["pane"]]).stdout
            m = re.search(r"\*\s+(surface:\d+)", tabs)
            if m:
                cols, rows = (int(v) for v in grid.split("x"))
                result.append((pane["pane"], m.group(1), cols, rows))
    return result


def shell_size(surface):
    """(rows, cols, $COLUMNS) as the shell sees them."""
    # Not from the seeded generator: a rerun with the same seed must not
    # match an answer an earlier run left on the screen.
    marker = MARKERS.randrange(1 << 32)
    cli("send", "--surface", surface, f'echo "@@{marker} $(stty size) $COLUMNS@@"\n')
    pattern = re.compile(rf"@@{marker} (\d+) (\d+) (\d+)@@")
    deadline = time.time() + 5
    while time.time() < deadline:
        # A narrow pane wraps the answer; soft wraps are line breaks here.
        m = pattern.search(cli("read-screen", "--surface", surface).stdout.replace("\n", ""))
        if m:
            return tuple(int(v) for v in m.groups())
        time.sleep(0.2)
    return None


def rendered_grid(pane_key):
    for pane, _, cols, rows in visible_terminals():
        if pane == pane_key:
            return cols, rows
    return None


def check(label):
    """Every visible terminal: the shell's size equals the rendered grid. The
    grid is sampled before and after the shell answers and must not change
    in between, so a resize still in flight is sampled again, not counted."""
    time.sleep(opts.settle)
    bad = 0
    for pane, surface, _, _ in visible_terminals():
        for _ in range(4):
            before = rendered_grid(pane)
            seen = shell_size(surface)
            after = rendered_grid(pane)
            if before == after:
                break
        cols, rows = after or (0, 0)
        ok = before == after and seen is not None and seen == (rows, cols, cols)
        bad += not ok
        print(f"  {'ok ' if ok else 'BAD'} {label}: {surface} rendered {cols}x{rows} shell {seen}")
    return bad


def daemon_surface(pane_key):
    """Numeric daemon surface of the pane's active tab."""
    d = Daemon()
    try:
        d.request("identify")
        workspaces = d.request("list-workspaces").get("data", {}).get("workspaces", [])
    finally:
        d.close()
    for workspace in workspaces:
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                if pane.get("resource_id") == pane_key and pane.get("tabs"):
                    return pane["tabs"][pane.get("active_tab", 0)]["surface"]
    return None


def focused_terminal():
    """(pane key, surface ref) of the focused visible terminal pane."""
    focused = [pane["pane"] for window in rpc("debug.surfaces").get("windows", [])
               for pane in window["panes"] if pane.get("focused")]
    return next(((pane, surface) for pane, surface, _, _ in visible_terminals() if pane in focused), None)


def mac_activity():
    """A Mac key press in the focused pane (Ctrl-C, the reported repro) or a
    Mac layout resize."""
    if random.random() < 0.5:
        rpc("debug.key", {"key": "c", "modifiers": ["ctrl"]})
        return "Mac key press"
    action("toggleSidebar")
    return "Mac resize"


def expect_mac_grid(pane, foreign, label):
    """The Mac took geometry back: the pane no longer renders the foreign size."""
    grid = rendered_grid(pane)
    ok = grid is not None and grid != foreign
    print(f"  {'ok ' if ok else 'BAD'} {label}: Mac holds geometry again, rendered {grid}, foreign {foreign}")
    return not ok


def displace():
    """"window-size latest": another client (the phone) claims the focused
    terminal at a foreign size, the Mac takes it back by resizing, the other
    client reclaims on its own input and leaves, and a Mac key press or
    resize takes it back again. The grid must equal `stty size` throughout."""
    target = focused_terminal()
    if not DAEMON or not target:
        return 0
    pane, _ = target
    number = daemon_surface(pane)
    if number is None:
        return 0
    cols, rows = random.choice([(200, 60), (30, 12), (57, 19)])
    d = Daemon()
    d.request("identify")
    d.request("set-client-info", name="pty-size-e2e", kind="frontend", capabilities=[])
    d.request("attach-surface", surface=number, mode="bytes", cols=cols, rows=rows)
    d.request("resize-surface", surface=number, cols=cols, rows=rows)
    d.request("set-client-sizing", surface=number, enabled=True, exclusive=True)
    bad = check(f"claimed {cols}x{rows} by another client")
    action("toggleSidebar")
    bad += check("Mac resized while another client holds geometry")
    bad += expect_mac_grid(pane, (cols, rows), "Mac resize")
    # The other client's own input takes it back (the phone does this).
    d.request("set-client-sizing", surface=number, enabled=True, exclusive=True)
    bad += check("other client reclaimed")
    if random.random() < 0.5:
        # Release freezes the grid at the other client's size and no
        # displaced owner returns (cmux-tui `use_all_client_sizes`): only
        # Mac activity can take geometry back.
        d.request("set-client-sizing", surface=number, enabled=True)
        d.close()
        bad += check("other client released and left, grid frozen at its size")
    else:
        d.close()
        bad += check("other client left")
    label = mac_activity()
    bad += check(f"{label} after the other client left")
    return bad + expect_mac_grid(pane, (cols, rows), label)


def split():
    targets = visible_terminals()
    if targets and len(targets) < 5:
        cli("new-split", random.choice(["right", "down"]), "--surface", random.choice(targets)[1], "--focus", "false")


def close_split():
    targets = visible_terminals()
    if len(targets) > 1:
        cli("close-surface", "--workspace", "workspace:1", "--surface", random.choice(targets)[1])


def workspace_round_trip():
    cli("new-workspace", "--name", "pty-size-e2e")
    listing = cli("list-workspaces").stdout
    other = re.findall(r"(workspace:\d+)\s+pty-size-e2e", listing)
    if other:
        cli("select-workspace", "--workspace", other[-1])
        time.sleep(0.5)
        cli("select-workspace", "--workspace", "workspace:1")
        cli("close-workspace", "--workspace", other[-1])


OPS = {
    "split": split,
    "close split": close_split,
    "sidebar": lambda: action("toggleSidebar"),
    "zoom": lambda: action("toggleSplitZoom"),
    "density compact": lambda: action("appearance.density.compact"),
    "density comfortable": lambda: action("appearance.density.comfortable"),
    "font bigger": lambda: action("increaseWorkspaceTerminalFontSize"),
    "font smaller": lambda: action("decreaseWorkspaceTerminalFontSize"),
    "equalize": lambda: action("equalizeSplits"),
    "workspace round trip": workspace_round_trip,
}

failures = check("start")
for step in range(opts.ops):
    if random.random() < opts.claim_rate:
        print(f"[{step}] foreign geometry claim")
        failures += displace()
        continue
    name = random.choice(list(OPS))
    print(f"[{step}] {name}")
    OPS[name]()
    failures += check(name)
action("resetWorkspaceTerminalFontSize")
print(f"{'FAIL' if failures else 'PASS'}: {failures} mismatched samples")
sys.exit(1 if failures else 0)
