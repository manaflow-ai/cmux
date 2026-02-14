#!/usr/bin/env python3
"""
Manual visual report: terminal caret blink + single-character typing visibility.

This generates a self-contained HTML report (base64-embedded PNGs) so you can
open it locally and visually confirm:
  1) The caret is blinking (or not).
  2) A single typed character appears immediately (before Enter / focus toggle).

Usage:
  python3 tests/test_terminal_input_render_report.py
  # Then open: tests/terminal_input_report.html

Environment:
  CMUX_SOCKET or CMUX_SOCKET_PATH can override the socket path.
"""

import base64
import json
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET") or os.environ.get("CMUX_SOCKET_PATH") or "/tmp/cmux-debug.sock"
HTML_REPORT = Path(__file__).parent / "terminal_input_report.html"


@dataclass
class Shot:
    path: Path
    label: str
    changed_pixels: int

    def to_base64(self) -> str:
        return base64.b64encode(self.path.read_bytes()).decode("utf-8")


def _wait_for(pred, timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _focused_panel_id(c: cmux) -> str:
    surfaces = c.list_surfaces()
    if not surfaces:
        raise cmuxError("Expected at least 1 surface")
    return next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])


def _snap_panel(c: cmux, panel_id: str, label: str) -> Shot:
    info = c.panel_snapshot(panel_id, label)
    return Shot(
        path=Path(info["path"]),
        label=label,
        changed_pixels=int(info["changed_pixels"]),
    )


def _panel_sequence_blink_and_type(c: cmux, panel_id: str, prefix: str, typed_char: str = "x") -> tuple[list[Shot], dict]:
    shots: list[Shot] = []

    # Keep the app key/active while we probe focus + rendering; on a host machine the
    # terminal running this script can steal focus mid-sequence.
    c.activate_app()
    time.sleep(0.15)

    _wait_for(lambda: c.is_terminal_focused(panel_id), timeout_s=3.0)
    stats0 = c.render_stats(panel_id)

    # Blink probe: capture a few frames over ~1.3s
    c.panel_snapshot_reset(panel_id)
    shots.append(_snap_panel(c, panel_id, f"{prefix}_blink_0"))
    time.sleep(0.65)
    shots.append(_snap_panel(c, panel_id, f"{prefix}_blink_1"))
    time.sleep(0.65)
    shots.append(_snap_panel(c, panel_id, f"{prefix}_blink_2"))

    # Type probe: before, after typing a single char, after Enter.
    c.panel_snapshot_reset(panel_id)
    shots.append(_snap_panel(c, panel_id, f"{prefix}_type_before"))
    # Use keyDown path (not insertText) to match real typing.
    c.simulate_shortcut(typed_char)
    time.sleep(0.2)
    shots.append(_snap_panel(c, panel_id, f"{prefix}_type_after_char_{ord(typed_char)}"))
    c.simulate_shortcut("enter")
    time.sleep(0.35)
    shots.append(_snap_panel(c, panel_id, f"{prefix}_type_after_enter"))

    # Grab stats after, for debugging.
    stats1 = c.render_stats(panel_id)
    meta = {
        "panel_id": panel_id,
        "render_stats_before": stats0,
        "render_stats_after": stats1,
    }
    return shots, meta


def _write_report(cases: list[dict]) -> None:
    generated = datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

    def esc(s: str) -> str:
        return (
            s.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )

    html = f"""<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>cmux terminal input render report</title>
  <style>
    :root {{
      --bg: #0b0f14;
      --panel: #111826;
      --border: rgba(255,255,255,0.08);
      --text: rgba(255,255,255,0.92);
      --muted: rgba(255,255,255,0.68);
      --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
    }}
    body {{
      margin: 0;
      padding: 24px;
      background: var(--bg);
      color: var(--text);
      font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
    }}
    h1 {{
      margin: 0 0 6px 0;
      font-size: 18px;
      letter-spacing: 0.2px;
    }}
    .meta {{
      color: var(--muted);
      font-family: var(--mono);
      font-size: 12px;
      margin-bottom: 18px;
    }}
    .case {{
      border: 1px solid var(--border);
      background: rgba(255,255,255,0.03);
      border-radius: 12px;
      padding: 14px 14px 10px 14px;
      margin: 14px 0;
    }}
    .case h2 {{
      font-size: 15px;
      margin: 0 0 6px 0;
    }}
    .desc {{
      color: var(--muted);
      margin: 0 0 10px 0;
    }}
    .shots {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 12px;
      align-items: start;
    }}
    figure {{
      margin: 0;
      padding: 10px;
      border: 1px solid var(--border);
      background: rgba(0,0,0,0.18);
      border-radius: 10px;
    }}
    figcaption {{
      margin: 0 0 8px 0;
      font-family: var(--mono);
      font-size: 12px;
      color: var(--muted);
    }}
    img {{
      width: 100%;
      height: auto;
      border-radius: 8px;
      border: 1px solid rgba(255,255,255,0.06);
      background: #000;
    }}
    pre {{
      margin: 10px 0 0 0;
      padding: 10px;
      border: 1px solid var(--border);
      background: rgba(0,0,0,0.25);
      border-radius: 10px;
      overflow: auto;
      font-size: 12px;
      line-height: 1.35;
      font-family: var(--mono);
      color: rgba(255,255,255,0.85);
    }}
  </style>
</head>
<body>
  <h1>cmux terminal input render report</h1>
  <div class="meta">generated: {esc(generated)} | socket: {esc(SOCKET_PATH)}</div>
"""

    for case in cases:
        html += f"""
  <div class="case">
    <h2>{esc(case["name"])}</h2>
    <div class="desc">{esc(case["description"])}</div>
    <div class="shots">
"""
        for shot in case["shots"]:
            label = f'{shot.label} | changed_pixels={shot.changed_pixels}'
            html += f"""
      <figure>
        <figcaption>{esc(label)}</figcaption>
        <img src="data:image/png;base64,{shot.to_base64()}" alt="{esc(shot.label)}" />
      </figure>
"""
        html += f"""
    </div>
    <pre>{esc(json.dumps(case.get("meta", {}), indent=2))}</pre>
  </div>
"""

    html += """
</body>
</html>
"""
    HTML_REPORT.write_text(html)


def main() -> int:
    cases: list[dict] = []

    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.25)

        # Case 1: fresh workspace, initial terminal
        ws_id = c.new_workspace()
        c.select_workspace(ws_id)
        time.sleep(0.35)

        panel0 = _focused_panel_id(c)
        shots0, meta0 = _panel_sequence_blink_and_type(c, panel0, "initial", typed_char="a")
        cases.append(
            {
                "name": "Initial Terminal (Fresh Workspace)",
                "description": "Caret blink probe + type a single character, then Enter.",
                "shots": shots0,
                "meta": meta0,
            }
        )

        # Case 2: after split churn + new surface in a split
        for _ in range(4):
            c.new_split("right")
            time.sleep(0.7)

        new_id = c.new_surface(panel_type="terminal")
        time.sleep(0.5)
        # new_surface doesn't always steal focus (depends on split state); ensure we test the right panel.
        c.focus_surface(new_id)
        time.sleep(0.25)
        shots1, meta1 = _panel_sequence_blink_and_type(c, new_id, "after_splits", typed_char="b")
        cases.append(
            {
                "name": "After 4 Right Splits + New Surface",
                "description": "Repro-oriented: split churn then create a new terminal surface; verify caret + typing.",
                "shots": shots1,
                "meta": meta1,
            }
        )

    _write_report(cases)
    print(f"Wrote report: {HTML_REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
