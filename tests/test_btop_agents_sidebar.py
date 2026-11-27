#!/usr/bin/env python3
"""Stateful regressions for the btop-style custom sidebar example."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Examples" / "CustomSidebars" / "btop-agents.js"


class BtopAgentsSidebarTests(unittest.TestCase):
    def test_clocked_snapshot_does_not_rescan_the_full_workspace_list(self):
        source = SOURCE.read_text(encoding="utf-8")
        selection = source.split("const workspaceSelection = computed", 1)[1].split(
            "const snapshot = computed", 1
        )[0]
        snapshot = source.split("const snapshot = computed", 1)[1].split(
            "const shown = computed", 1
        )[0]

        self.assertIn("data.workspaces()", selection)
        self.assertIn("cappedWorkspaces", selection)
        self.assertNotIn("data.workspaces()", snapshot)
        self.assertNotIn("allWorkspaces.map", snapshot)
        self.assertIn("workspaceSelection()", snapshot)

    def test_history_stays_bounded_when_wall_clock_moves_backward(self):
        source = SOURCE.read_text(encoding="utf-8")
        history = "const history = new Map();" + source.split("const history = new Map();", 1)[1].split(
            "// ---------------------------------------------------------------------------\n// Row model.",
            1,
        )[0]
        script = f"""
const BUCKET = 15;
const KEEP = 48;
const MAX_ROWS = 40;
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
  unread: 0,
  agents: [{{ status: index >= 40 && index < 90 ? "working" : "idle" }}],
}}));
for (const onlyBusy of [false, true]) {{
  const capped = cappedWorkspaces(workspaces, onlyBusy);
  if (capped.length > MAX_ROWS) throw new Error(`mode ${{onlyBusy}} returned ${{capped.length}} rows`);
  if (!capped.some((w) => w.selected)) throw new Error(`mode ${{onlyBusy}} lost selection`);
  if (onlyBusy && !capped.some((w) => w.id === "workspace-40")) {{
    throw new Error("BUSY mode hid active workspaces beyond the initial cap");
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

    def test_busy_filter_does_not_evict_quiet_workspace_history(self):
        source = SOURCE.read_text(encoding="utf-8")
        history = "const history = new Map();" + source.split(
            "const history = new Map();", 1
        )[1].split(
            "// ---------------------------------------------------------------------------\n// Row model.",
            1,
        )[0]
        cap_function = "function workspaceIsBusy" + source.split(
            "function workspaceIsBusy", 1
        )[1].split("const [busyOnly", 1)[0]
        script = f"""
const BUCKET = 15;
const KEEP = 48;
const MAX_ROWS = 40;
{history}
{cap_function}
const recent = {{ id: "recent", agents: [{{ status: "working", sinceEpoch: 1 }}] }};
const selected = {{ id: "selected", selected: true, agents: [{{ status: "idle" }}] }};
const workspaces = [recent, selected];
const liveIds = new Set(workspaces.map((w) => w.id));
sample(cappedWorkspaces(workspaces, false), 1_000, liveIds);
recent.agents[0].status = "idle";
sample(cappedWorkspaces(workspaces, true), 1_015, liveIds);
if (!history.has("recent")) throw new Error("BUSY mode erased recent history");
"""

        result = subprocess.run(
            ["node", "-e", script],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_history_evicts_oldest_offscreen_workspace_at_capacity(self):
        source = SOURCE.read_text(encoding="utf-8")
        history = "const history = new Map();" + source.split(
            "const history = new Map();", 1
        )[1].split(
            "// ---------------------------------------------------------------------------\n// Row model.",
            1,
        )[0]
        cap_functions = "function workspaceIsBusy" + source.split(
            "function workspaceIsBusy", 1
        )[1].split("const [busyOnly", 1)[0]
        script = f"""
const BUCKET = 15;
const KEEP = 48;
const MAX_ROWS = 40;
{history}
{cap_functions}
const workspaces = Array.from({{ length: 41 }}, (_, index) => ({{
  id: `workspace-${{index}}`,
  selected: index === 40,
  unread: 0,
  agents: [{{ status: "idle" }}],
}}));
const liveIds = new Set(workspaces.map((w) => w.id));
sample(cappedWorkspaces(workspaces, false), 1_000, liveIds);
workspaces[39].agents[0].status = "working";
sample(cappedWorkspaces(workspaces, true), 1_015, liveIds);
if (history.size !== MAX_ROWS) throw new Error(`history size is ${{history.size}}`);
if (history.has("workspace-0")) throw new Error("oldest offscreen history was not evicted");
if (!history.has("workspace-1")) throw new Error("eviction skipped the oldest history");
if (!history.has("workspace-39")) throw new Error("newly visible history was not admitted");
if (!history.has("workspace-40")) throw new Error("selected history was evicted");
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
