#!/usr/bin/env python3
"""Create the tmux + proxied browser demo workspace with the cmux CLI.

  demo.py create [--session NAME] [--name TITLE] [--site DIR]
  demo.py sizes  [--session NAME] --workspace ws_… [--browser tab_…]

`create` makes a workspace whose LEFT pane is a terminal running tmux (dev
server on top, size monitor below) and whose RIGHT pane is a Chromium tab in
an extension-free profile, opened on the port that port discovery found in the
tmux session (never a hard-coded port). It prints one JSON object with every
id. Design: plans/cmux-next/workspace-proxy-DESIGN.md.

`sizes` prints the sizing bench readout: cmux's terminal size, the tmux client
size and the browser viewport.
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import ports  # noqa: E402

# Ports that are listening but are not the page: debuggers, adb, Discord RPC.
NOT_HTTP = {9229, 9230, 5037, 6463}
# Common dev-server ports, best first.
DEV_PORTS = [5173, 3000, 8000, 8080, 4321, 4200, 5000, 8888]
PROFILE = "Proxy demo"


def pick_port(listeners: list[ports.Listener]) -> ports.Listener | None:
    """The listener a browser pane should open: a known dev port first, else
    the lowest port that is not a known non-HTTP service."""
    candidates = [l for l in listeners if l.port not in NOT_HTTP]
    if not candidates:
        return None
    rank = {port: i for i, port in enumerate(DEV_PORTS)}
    return min(candidates, key=lambda l: (rank.get(l.port, len(DEV_PORTS)), l.port))


class Cmux:
    def __init__(self, session: str | None, app_socket: str | None) -> None:
        self.prefix = ["cmux"]
        if session:
            self.prefix += ["--session", session]
        if app_socket:
            self.prefix += ["--app-socket", app_socket]

    def json(self, *args: str) -> object:
        proc = subprocess.run([*self.prefix, "--json", *args], capture_output=True, text=True, timeout=60)
        out = proc.stdout.strip() or proc.stderr.strip()
        try:
            data = json.loads(out)
        except json.JSONDecodeError:
            raise SystemExit(f"cmux {' '.join(args)}: {out}") from None
        if isinstance(data, dict) and "code" in data and "message" in data:
            raise SystemExit(f"cmux {' '.join(args)}: {data['message']}")
        return data.get("value", data) if isinstance(data, dict) else data


def default_app_socket() -> str | None:
    """The app socket that renders the session's browser tabs (the nightly
    app, else the release app)."""
    for name in ("cmux-nightly.sock", "cmux.sock"):
        path = Path.home() / ".local/state/cmux" / name
        if path.exists():
            return str(path)
    return None


def wait_for_port(tmux_session: str, timeout: float) -> ports.Listener:
    deadline = time.time() + timeout
    while time.time() < deadline:
        found = ports.find(ports.parse_args(["--tmux-session", tmux_session]))
        best = pick_port([ports.Listener(**l) for l in found["listeners"]])  # type: ignore[arg-type]
        if best:
            return best
        time.sleep(0.3)
    raise SystemExit(f"no listening port appeared in tmux session {tmux_session} within {timeout:.0f}s")


def ensure_profile(cmux: Cmux) -> str:
    listing = subprocess.run([*cmux.prefix, "browser", "profile", "list"], capture_output=True, text=True).stdout
    for line in listing.splitlines()[1:]:
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(PROFILE + " "):
            return parts[0]
    value = cmux.json("browser", "profile", "create", "--name", PROFILE, "--icon", "🧪")
    return value["browser_profile"]["id"]  # type: ignore[index]


def create(args: argparse.Namespace) -> dict[str, object]:
    tmux_session = args.tmux_session or f"cmux-proxy-demo-{uuid.uuid4().hex[:6]}"
    base = Path(args.state or f"/tmp/cmux-proxy-demo/{tmux_session}")
    site = Path(args.site or base / "site")
    state = base / "state"
    site.mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    cmux = Cmux(args.session, args.app_socket or default_app_socket())

    ws = cmux.json("workspace", "create", "--name", args.name, "--cwd", str(site))
    left_pane, left_terminal = ws["pane_id"], ws["terminal_id"]  # type: ignore[index]
    up = " ".join(shlex.quote(x) for x in ["sh", str(HERE / "tmux-up.sh"), tmux_session, str(state), str(site)])
    cmux.json("terminal", left_terminal, "write", "--text", up + "\n")
    listener = wait_for_port(tmux_session, args.timeout)
    url = f"http://localhost:{listener.port}/"

    # The right pane: split, open the Chromium tab there, drop the split's shell.
    split = cmux.json("pane", left_pane, "split", "--right", "--ratio", "0.5")
    right_pane, spare_tab = split["pane_id"], split["tab_id"]  # type: ignore[index]
    profile = ensure_profile(cmux)
    browser = cmux.json("browser", "profile", "open", url, "--profile", profile, "--engine", "cef", "--pane", right_pane)
    cmux.json("tab", spare_tab, "close")
    return {
        "workspace_id": ws["workspace_id"],  # type: ignore[index]
        "screen_id": ws["screen_id"],  # type: ignore[index]
        "left_pane": left_pane,
        "left_terminal": left_terminal,
        "right_pane": right_pane,
        "browser_tab": browser["tab_id"],  # type: ignore[index]
        "browser_profile": profile,
        "tmux_session": tmux_session,
        "url": url,
        "server": {"port": listener.port, "pid": listener.pid, "command": listener.command},
        "site": str(site),
    }


def sizes(args: argparse.Namespace) -> dict[str, object]:
    cmux = Cmux(args.session, args.app_socket or default_app_socket())
    out: dict[str, object] = {"terminals": []}
    for term in cmux.json("terminal", "list", "--workspace", args.workspace):  # type: ignore[union-attr]
        screen = cmux.json("terminal", term["id"], "screen", "read")
        out["terminals"].append({"id": term["id"], "cols": screen.get("cols"), "rows": screen.get("rows")})  # type: ignore[union-attr]
    clients = subprocess.run(
        ["tmux", "list-clients", "-F", "#{client_tty} #{session_name} #{client_width}x#{client_height}"],
        capture_output=True, text=True,
    ).stdout
    out["tmux_clients"] = [l for l in clients.splitlines() if l]
    if args.browser:
        js = "JSON.stringify({w:innerWidth,h:innerHeight,dpr:devicePixelRatio,vis:document.visibilityState})"
        value = cmux.json("browser", args.browser, "eval", js)
        out["browser"] = json.loads(value["value"]) if isinstance(value, dict) and "value" in value else value
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--session")
    c.add_argument("--app-socket")
    c.add_argument("--name", default="tmux + proxied browser")
    c.add_argument("--site")
    c.add_argument("--state")
    c.add_argument("--tmux-session")
    c.add_argument("--timeout", type=float, default=20)
    s = sub.add_parser("sizes")
    s.add_argument("--session")
    s.add_argument("--app-socket")
    s.add_argument("--workspace", required=True)
    s.add_argument("--browser")
    args = parser.parse_args(argv)
    print(json.dumps(create(args) if args.cmd == "create" else sizes(args), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
