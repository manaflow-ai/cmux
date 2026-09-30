#!/usr/bin/env python3
"""PTY size vs rendered grid for a tagged cmux-next build.

Runs random layout changes (splits, closes, sidebar, zoom, density, font
size, equalize, a workspace round trip) and foreign geometry claims (a second
daemon client attaches to a visible terminal, claims canonical geometry at
another size, and leaves), then checks every visible terminal: `stty size`
and `$COLUMNS` inside the shell must equal the grid the Ghostty mirror
renders (`debug.surfaces`). A mismatch is what leaves zsh's PROMPT_SP `%`
mark on its own line after Ctrl-C.

  scripts/cmux-next/pty-size-e2e.py --tag <tag> [--ops 30] [--seed 1] [--claim-rate 0.25] [--settle 1.0]

The tagged app must be running (launched with CMUX_NEXT_SOCKET_MODE=automation).
Exit 1 on any mismatch after an op has settled.
"""
import argparse, glob, json, os, random, re, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--ops", type=int, default=30)
parser.add_argument("--seed", type=int, default=1)
parser.add_argument("--claim-rate", type=float, default=0.25, help="share of ops that are foreign geometry claims")
parser.add_argument("--settle", type=float, default=1.0, help="seconds to wait after an op before checking")
parser.add_argument("--cli", help="cmux CLI inside the tagged app (default: found in DerivedData)")
opts = parser.parse_args()
random.seed(opts.seed)
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
    """A second cmux-tui client on the tag's daemon socket (line JSON)."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(DAEMON)
        self.sock.settimeout(10)
        self.file = self.sock.makefile("rwb")
        self.next_id = 0

    def request(self, cmd, **fields):
        self.next_id += 1
        self.file.write((json.dumps({"id": self.next_id, "cmd": cmd, **fields}) + "\n").encode())
        self.file.flush()
        while True:
            line = self.file.readline()
            if not line:
                raise RuntimeError("daemon closed the connection")
            reply = json.loads(line)
            if reply.get("id") == self.next_id or reply.get("ok") is False:
                return reply

    def close(self):
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
    marker = random.randrange(1 << 16)
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


def displace():
    """Another client claims one visible terminal at a foreign size, the Mac
    layout changes meanwhile, then the client leaves."""
    targets = visible_terminals()
    if not DAEMON or not targets:
        return 0
    pane, surface, _, _ = random.choice(targets)
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
    d.close()
    bad += check("other client left")
    action("toggleSidebar")
    return bad + check("Mac resized after the other client left")


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
