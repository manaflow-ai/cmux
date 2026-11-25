// l10n-allow-file: gallery fixtures (prompts, titles, paths, commands), not shipped UI.
// The stress matrix for the design principles (design/principles.md, P1 to P12): the real agent
// pane under every content extreme the principles name, at a compressed, a normal and a wide pane.
// The gallery crosses each variant with its widths and schemes; read a cell against `baseline` at
// the same width and the Fail lines of the principles its note names.
import { agentPaneEntry, type AgentPaneVariant } from "../format";
import { activity, assistant, chat, row, summary, tool, user } from "../fixtures/acpmux";
import { minutesAgo } from "../clock";
import { SUBAGENTS, type Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import type { AcpmuxRow } from "../../agent-session/acpmux/model";

const LONG_TITLE =
  "Find out why the sidebar drag test flakes on the narrow layout only when two splits are open and the second one holds a diff with a very long file name";
const LONG_BRANCH = "lane/sidebar-drag-flake-narrow-layout-two-splits-long-diff-name";
const LONG_PATH =
  "webviews/src/agent-session/acpmux/subagents/presentation/internal/trayPanelLayoutMeasurementsForCompressedPaneWidths.ts";
const LONG_COMMAND =
  "SHA=$(git rev-parse HEAD); cmux-ci run --class light --key sidebar-drag-${SHA:0:12} --ref $SHA --script scripts/check-sidebar-drag.sh --repeat 40";
const TALL_DRAFT = Array.from(
  { length: 40 },
  (_, line) => `Line ${line + 1}: and check the drag handle keeps its place when the pane is narrow`,
).join("\n");

const base: AcpmuxRow[] = [
  user("Why does the sidebar drag test flake?", 12),
  assistant("It races the split's resize. I'll pin the order and run it forty times on the fleet.", 11),
  summary(11, { durationMs: 64_000, toolCount: 3 }),
];

function agent(name: string, minutes: number, state: Subagent["state"] = "running"): Subagent {
  return {
    id: `stress-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(minutes),
    ...(state === "running" ? {} : { endedAt: minutesAgo(minutes - 1) }),
  };
}

const background = (command: string, minutes: number) =>
  activity(
    [
      tool(command, "execute", "completed", {
        inputSummary: JSON.stringify({ command, run_in_background: true }),
        startedAt: minutesAgo(minutes),
      }),
    ],
    minutes,
  );

const running = [
  row(SUBAGENTS, 4, {
    subagents: [
      agent("Read the drag handler", 4),
      agent("Search for resize races", 3),
      agent("Check the test history", 2),
    ],
  }),
  background("bun run dev", 3),
  background(LONG_COMMAND, 2),
];

const fileRow = activity([tool(`Edit ${LONG_PATH}`, "edit", "completed", { locations: [{ path: LONG_PATH }] })], 1);

const failed = [
  activity([tool("bun test sidebar-drag", "execute", "failed")], 2),
  row(SUBAGENTS, 2, { subagents: [agent("Bisect the flake", 3, "failed")] }),
];

const variant = (
  note: string,
  rows: AcpmuxRow[],
  fields: Partial<AgentPaneVariant> & { title?: string; branch?: string; working?: boolean; pending?: number } = {},
): AgentPaneVariant => {
  const { title, branch, working = false, pending = 0, ...rest } = fields;
  const snapshot = chat(rows, { title, branch, isWorking: working });
  if (pending) snapshot.sessions = snapshot.sessions.map((entry) => ({ ...entry, pendingPermissions: pending }));
  return { note, snapshot, ...rest };
};

export default agentPaneEntry({
  id: "design.principles-stress",
  title: "Design principles stress matrix",
  area: "Agent pane",
  height: 900,
  // P2: the compressed pane first (Leo, 2026-11-23: "unusable at low widths. which is common").
  widths: { narrow: 300, normal: 420, wide: 1200 },
  keywords: ["principles", "stress", "matrix", "P1", "P12", "edge cases", "narrow", "compressed"],
  covers: ["agent-session/acpmux/App.tsx", "agent-session/acpmux/subagents/subagentFold.ts"],
  variants: {
    baseline: variant("The reference cell: a short chat, empty composer. All principles.", base),
    "draft-one-line": variant("A one-line draft: the composer at its smallest. P1, P7.", base, {
      ready: { draft: "Also run it on the narrow layout" },
    }),
    "draft-tall": variant("A 40-line draft: buttons stay on the bottom edge, no standing scroll thumb. P1, P6.", base, {
      ready: { draft: TALL_DRAFT },
    }),
    "title-long": variant("A long title and branch: header controls at every width. P1, P2, P4.", base, {
      title: LONG_TITLE,
      branch: LONG_BRANCH,
    }),
    "running-many": variant(
      "Three subagents and two background commands at once: counts and marks, not words. P2, P3, P4, P12.",
      [...base, ...running],
      { working: true },
    ),
    "needs-you": variant("A permission waiting: the one state that should speak. P3.", base, { pending: 1 }),
    failed: variant("A failed tool call and a failed subagent. P3.", [...base, ...failed]),
    "file-long": variant("A tool row on a deep, long path. P4, P11.", [...base, fileRow]),
    "command-long": variant("A long background shell command. P3, P4, P12.", [...base, background(LONG_COMMAND, 1)], {
      working: true,
    }),
    everything: variant("Every extreme at once. All principles.", [...base, ...failed, fileRow, ...running], {
      title: LONG_TITLE,
      branch: LONG_BRANCH,
      working: true,
      pending: 1,
      ready: { draft: TALL_DRAFT },
    }),
  },
});
