#!/usr/bin/env python3
"""Live check: every icon in the workspace hover card is legible, labeled and on the card's grid
(Leo 2026-10-13, cosmic-gray: a chat bubble floating at the top right and a smudged working mark
under the title).

  scripts/cmux-next/hover-card-grid-live.py --tag <tag>

Attaches to a running tagged app (it never launches, activates or quits one). It opens a terminal
tab in the selected workspace, reports an agent working in it, hovers that workspace's sidebar
row through the real hover path (`debug.hover_sweep`) and reads the shown card's glyphs and
labels (`DebugCardGrid`). Checks, idle and then working:

  1. every glyph is at least 12 pt on each side;
  2. every glyph sits on one icon column, and no text starts left of it;
  3. every glyph has a label beside it, centered on the same line (0.5 pt);
  4. working: the shared indicator shows, labeled.

Exits 1 when a check fails.
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cmux-debug-cli.sh")
MIN_GLYPH = 12.0
TOLERANCE = 0.5
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


def selected_row():
    """The main window's height and its selected workspace row (top-left window frame)."""
    windows = (rpc("debug.window_list") or {}).get("windows") or []
    main = next((w for w in windows if w.get("kind") == "main" and w.get("visible")), None)
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    row = next((r for r in rows if r.get("selected")), rows[0] if rows else None)
    return (main or {}).get("frame", {}).get("height"), row


def card(label):
    """Hovers the selected row and returns the shown card's report."""
    rpc("debug.pointer_hover", {"point": [5, 5]})  # off the row first, so the card shows anew
    time.sleep(0.5)
    height, row = selected_row()
    if not height or not row:
        check(False, f"{label}: a main window with a workspace row")
        return None
    frame = row["window_frame"]
    point = [frame["x"] + frame["width"] / 2, height - (frame["y"] + frame["height"] / 2)]
    report = rpc("debug.hover_sweep", {"point": point}) or {}
    shown = report.get("card")
    check(bool(report.get("shown")) and isinstance(shown, dict), f"{label}: the workspace card shows ({report.get('error') or 'shown'})")
    return shown if isinstance(shown, dict) else None


def check_grid(shown, label):
    glyphs, labels = shown.get("glyphs") or [], shown.get("labels") or []
    print(f"{label}: card {shown.get('size')}, glyphs {json.dumps(glyphs)}, labels {json.dumps(labels)}", flush=True)
    check(bool(glyphs), f"{label}: the card has glyphs")
    if not glyphs:
        return glyphs, labels
    for glyph in glyphs:
        x, y, w, h = glyph["frame"]
        name = f"{label}: {glyph['kind']} glyph at ({x:.1f}, {y:.1f})"
        check(w >= MIN_GLYPH and h >= MIN_GLYPH, f"{name} is at least {MIN_GLYPH:g} pt ({w:.1f} x {h:.1f})")
        mid = y + h / 2
        # The nearest text to its right on its line (a later label, the age, does not count).
        right = sorted((l for l in labels if l["frame"][0] >= x + w and l["frame"][1] <= mid <= l["frame"][1] + l["frame"][3]),
                       key=lambda l: l["frame"][0])
        beside = right[:1] and abs(right[0]["frame"][1] + right[0]["frame"][3] / 2 - mid) <= TOLERANCE
        check(bool(beside), f"{name} has a label beside it, centered on its line ({right[0]['text'] if right else 'none'})")
    columns = sorted({round(g["frame"][0], 1) for g in glyphs})
    check(len(columns) == 1, f"{label}: glyphs share one icon column (x = {columns})")
    # A text field's frame sits its 2 pt text inset outside the text.
    column = min(g["frame"][0] for g in glyphs)
    stray = [l["text"] for l in labels if l["frame"][0] < column - 2 - TOLERANCE]
    check(not stray, f"{label}: nothing starts left of the icon column (x = {column:.1f}; left of it: {stray})")
    return glyphs, labels


def main():
    if "error" in (rpc("debug.window_list") or {"error": 1}):
        sys.exit(f"no tagged app answering on {SOCKET}")
    shown = card("idle")
    if shown:
        check_grid(shown, "idle")

    made = cli("action", "run", "newSurface")
    check(made.returncode == 0, "open a terminal tab in the selected workspace")
    time.sleep(2)
    listed = cli("terminal", "list").stdout.split()
    terminal = next((word for word in listed if word.startswith("term_")), None)
    reported = cli("agent", "report", "--terminal", terminal or "", "--state", "working", "--source", "socket")
    check(terminal is not None and reported.returncode == 0, f"report an agent working ({reported.stderr.strip()[-120:]})")
    time.sleep(1)
    shown = card("working")
    if shown:
        glyphs, labels = check_grid(shown, "working")
        indicators = [g for g in glyphs if g["kind"] == "indicator"]
        check(any(g["state"].startswith("working") for g in indicators), "working: the shared indicator shows the working state")

    cli("agent", "report", "--terminal", terminal or "", "--state", "idle", "--source", "socket")
    rpc("debug.pointer_hover", {"point": [5, 5]})
    print(f"{len(failures)} failure(s)", flush=True)
    sys.exit(1 if failures else 0)


main()
