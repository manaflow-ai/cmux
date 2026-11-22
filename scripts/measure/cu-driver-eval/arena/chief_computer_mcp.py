#!/usr/bin/env python3
"""The `chief-desktop` arm (README.md, "Arms"): the agent-facing surface of cmux#36515's
`cloud_computer` tool, on this Mac, so the pixels-only desktop approach runs the same suite as the
accessibility-first engines.

cmux#36515 drives a Linux desktop (Xvfb, 1280x800) through cua-driver or xdotool: one `computer`
tool whose `screenshot` op returns the whole screen as an image and whose input ops act at screen
pixels and answer a short JSON note ("take a screenshot to see what changed"). This server keeps
that tool's name-independent shape (the same ops, arguments and answers, from
cmux-tui/crates/cmux-tui/src/cli/mcp/cloud_tools.rs at that PR's head) and does the input with
arena-desktop through the session tap, which is what xdotool does on X11. What it does not carry
over: the Linux desktop itself, cua-driver's window targeting for type/key/scroll, and the control
lease. So it measures the approach (pixels only, a screenshot op, desktop-wide input), not that PR's
Linux stack.

  chief_computer_mcp.py --desktop PATH/arena-desktop [--width 1280]

Python 3.9 standard library only (the VM's Command Line Tools Python).
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile

OPS = ["screenshot", "list_windows", "click", "move", "drag", "scroll", "type", "key", "open_url"]
TOOL = {
    "name": "computer",
    "description": ("Use this Mac's desktop ({w}x{h}): screenshot (an image), list_windows, click, move, drag, scroll, "
                    "type, key (cmd+l, Return), open_url."),
    "inputSchema": {
        "type": "object",
        "additionalProperties": False,
        "required": ["op"],
        "properties": {
            "op": {"type": "string", "enum": OPS},
            "x": {"type": "integer", "minimum": 0},
            "y": {"type": "integer", "minimum": 0},
            "to_x": {"type": "integer", "minimum": 0},
            "to_y": {"type": "integer", "minimum": 0},
            "button": {"type": "string", "enum": ["left", "right", "middle"]},
            "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
            "amount": {"type": "integer", "minimum": 1, "maximum": 50},
            "text": {"type": "string", "minLength": 1},
            "keys": {"type": "string", "minLength": 1},
            "url": {"type": "string", "minLength": 1},
        },
    },
}
# Which arguments each op takes (cloud_tools.rs only()): any other is refused.
ALLOWED = {"screenshot": set(), "list_windows": set(), "click": {"x", "y", "button"}, "move": {"x", "y"},
           "drag": {"x", "y", "to_x", "to_y"}, "scroll": {"x", "y", "direction", "amount"}, "type": {"text"},
           "key": {"keys"}, "open_url": {"url"}}


class Desktop:
    def __init__(self, binary, width):
        self.binary, self.width = binary, width
        self.scale = None  # screenshot pixels per point, from the first screenshot
        self.shot = os.path.join(tempfile.mkdtemp(prefix="chief-desktop-"), "screen.jpg")

    def run(self, *argv):
        done = subprocess.run([self.binary, *[str(a) for a in argv]], capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            raise RuntimeError((done.stderr or done.stdout).strip()[:300] or f"arena-desktop exited {done.returncode}")
        return done.stdout

    def screenshot(self):
        info = json.loads(self.run("screenshot", self.shot, self.width))
        self.scale = info["scale"]
        with open(self.shot, "rb") as f:
            return base64.b64encode(f.read()).decode(), info

    def point(self, x, y):
        if self.scale is None:
            self.screenshot()
        return round(x / self.scale, 1), round(y / self.scale, 1)


def call(desktop, args):
    op = args.get("op")
    if op not in OPS:
        raise ValueError(f"op is one of {', '.join(OPS)}")
    extra = set(args) - {"op"} - ALLOWED[op]
    if extra:
        raise ValueError(f"{op} takes no {', '.join(sorted(extra))}")
    if op == "screenshot":
        data, info = desktop.screenshot()
        return [{"type": "image", "data": data, "mimeType": "image/jpeg"},
                {"type": "text", "text": json.dumps({"op": op, "width": info["width"], "height": info["height"]})}]
    if op == "list_windows":
        script = ('tell application "System Events" to get the name of every process whose visible is true')
        out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=20)
        result = {"apps": [a.strip() for a in out.stdout.split(",") if a.strip()]} if out.returncode == 0 else {"error": out.stderr.strip()[:200]}
    elif op in ("click", "move"):
        x, y = desktop.point(args["x"], args["y"])
        desktop.run("click", x, y, 1, args.get("button", "left")) if op == "click" else desktop.run("move", x, y)
        result = {"x": args["x"], "y": args["y"]}
    elif op == "drag":
        x, y = desktop.point(args["x"], args["y"])
        tx, ty = desktop.point(args["to_x"], args["to_y"])
        desktop.run("drag", x, y, tx, ty)
        result = {"dragged": True}
    elif op == "scroll":
        x, y = desktop.point(args.get("x", 640), args.get("y", 360))
        desktop.run("scroll", x, y, args.get("direction", "down"), args.get("amount", 3))
        result = {"scrolled": args.get("direction", "down")}
    elif op == "type":
        desktop.run("type", args["text"])
        result = {"typed": len(args["text"])}
    elif op == "key":
        desktop.run("key", args["keys"])
        result = {"keys": args["keys"]}
    else:
        subprocess.run(["open", args["url"]], capture_output=True, timeout=20)
        result = {"opened": True}
    return [{"type": "text", "text": json.dumps({"op": op, "result": result, "note": "take a screenshot to see what changed"})}]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--desktop", required=True)
    p.add_argument("--width", type=int, default=1280)
    a = p.parse_args()
    desktop = Desktop(a.desktop, a.width)
    tool = dict(TOOL)
    try:
        _, info = desktop.screenshot()
        tool["description"] = TOOL["description"].format(w=info["width"], h=info["height"])
    except Exception:
        tool["description"] = TOOL["description"].format(w=a.width, h="?")
    for raw in sys.stdin:
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        mid, method = msg.get("id"), msg.get("method")
        if mid is None:
            continue  # a notification
        if method == "initialize":
            result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                      "capabilities": {"tools": {}}, "serverInfo": {"name": "chief-desktop", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [tool]}
        elif method == "tools/call":
            params = msg.get("params", {})
            try:
                if params.get("name") != "computer":
                    raise ValueError("unknown tool")
                result = {"content": call(desktop, params.get("arguments") or {})}
            except Exception as error:
                result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
        elif method == "ping":
            result = {}
        else:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}}) + "\n")
            sys.stdout.flush()
            continue
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
