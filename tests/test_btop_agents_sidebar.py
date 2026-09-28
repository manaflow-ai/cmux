#!/usr/bin/env python3
"""Stateful regressions for the btop-style custom sidebar example."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Examples" / "CustomSidebars" / "btop-agents.js"


class BtopAgentsSidebarTests(unittest.TestCase):
    def test_history_stays_bounded_when_wall_clock_moves_backward(self):
        source = SOURCE.read_text(encoding="utf-8")
        history = "const history = new Map();" + source.split("const history = new Map();", 1)[1].split(
            "// ---------------------------------------------------------------------------\n// Row model.",
            1,
        )[0]
        script = f"""
const BUCKET = 15;
const KEEP = 48;
{history}
const workspaces = [{{ id: "workspace", agents: [] }}];
for (const era of [10_000, 1_000, 100]) {{
  for (let index = 0; index < KEEP; index += 1) {{
    sample(workspaces, era + index * BUCKET);
  }}
  if (history.get("workspace").size > KEEP) {{
    throw new Error(`history grew to ${{history.get("workspace").size}} entries`);
  }}
}}
"""

        result = subprocess.run(
            ["node", "-e", script],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_expensive_workspace_model_is_capped_before_rendering(self):
        source = SOURCE.read_text(encoding="utf-8")
        cap_functions = "function workspaceIsBusy" + source.split(
            "function workspaceIsBusy", 1
        )[1].split("const [busyOnly", 1)[0]
        script = f"""
const MAX_ROWS = 40;
const list = (v) => Array.isArray(v) ? v : [];
const num = (v) => typeof v === "number" && Number.isFinite(v) ? v : null;
{cap_functions}
const workspaces = Array.from({{ length: 1_000 }}, (_, index) => ({{
  id: `workspace-${{index}}`,
  selected: index === 999,
  unread: index % 2,
  agents: [{{ status: index % 3 === 0 ? "working" : "idle" }}],
}}));
for (const onlyBusy of [false, true]) {{
  const capped = cappedWorkspaces(workspaces, onlyBusy);
  if (capped.length > MAX_ROWS) throw new Error(`mode ${{onlyBusy}} returned ${{capped.length}} rows`);
  if (!capped.some((w) => w.selected)) throw new Error(`mode ${{onlyBusy}} lost selection`);
}}
"""

        result = subprocess.run(
            ["node", "-e", script],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
