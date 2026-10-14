// l10n-allow-file: gallery fixtures (sample agent names, actions, commands and output), not shipped UI.
// PROTOTYPE: three layouts of the right-pane Background tasks panel (BackgroundTasksPanel.tsx) on the
// same tasks: a workflow at 3/7 agents, an Explore agent, two background shells (one printing, one
// silent), and three finished tasks under a collapsed "Finished 3".
import { minutesAgo } from "../../../gallery/clock";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { BackgroundShell, BackgroundTasksLayout, BackgroundTasksPanelProps } from "./BackgroundTasksPanel";
import type { Subagent } from "./subagentFold";

const AGENTS: Subagent[] = [
  {
    id: "wf-audit",
    parent: null,
    name: "Audit packages for unused exports",
    task: "Audit every package for unused exports",
    kind: "Workflow",
    state: "running",
    startedAt: minutesAgo(6.2),
    action: "Package router: reading src/router/index.ts",
    tokens: 184_300,
    toolUses: 61,
    agents: { done: 3, started: 7 },
  },
  {
    id: "agent-explore",
    parent: null,
    name: "Find retry config",
    task: "Find where retries are configured",
    kind: "Explore",
    state: "running",
    startedAt: minutesAgo(1.4),
    action: "Search for retryCount in src/",
    tokens: 12_400,
    toolUses: 9,
  },
  {
    id: "agent-docs",
    parent: null,
    name: "Check the docs agree",
    kind: "general-purpose",
    state: "completed",
    startedAt: minutesAgo(9),
    endedAt: minutesAgo(7.6),
    tokens: 22_800,
    toolUses: 14,
  },
];

const SHELLS: BackgroundShell[] = [
  {
    id: "sh-dev",
    command: "bun run dev --port 5173",
    state: "running",
    startedAt: minutesAgo(12),
    output: ["VITE v6.2.0  ready in 412 ms", "  Local:   http://localhost:5173/", "  page reload src/net/fetch.ts"],
  },
  {
    id: "sh-watch",
    command: "cargo watch -x 'test -p cmux-tui-core'",
    state: "running",
    startedAt: minutesAgo(0.3),
    output: [],
  },
  {
    id: "sh-test",
    command: "bun test src/net",
    state: "completed",
    startedAt: minutesAgo(8),
    endedAt: minutesAgo(7.8),
    output: ["42 pass", "0 fail"],
  },
  {
    id: "sh-lint",
    command: "bun run lint --fix",
    state: "failed",
    startedAt: minutesAgo(10),
    endedAt: minutesAgo(9.9),
    output: ["error: 2 problems"],
  },
];

const noop = () => undefined;

const props = (layout: BackgroundTasksLayout, finishedOpen = false): BackgroundTasksPanelProps => ({
  layout,
  agents: AGENTS,
  shells: SHELLS,
  harness: "claude",
  finishedOpen,
  onOpen: noop,
  onClose: noop,
});

/** Opens the Finished section with a click. */
const openFinished: Play = async (ctx) => {
  await ctx.click({ selector: ".bgtasks__finished" });
  await ctx.waitFor(() => ctx.document.querySelector(".bgtasks__finished[aria-expanded='true']"));
};

export default componentEntry<BackgroundTasksPanelProps>({
  id: "agent-pane.background-tasks-variants",
  title: "Background tasks (prototypes)",
  area: "Agent pane",
  experimental: true,
  height: 560,
  widths: { narrow: 320, normal: 380, wide: 480 },
  anchors: [{ selector: ".bgtasks__header" }],
  covers: ["agent-session/acpmux/subagents/BackgroundTasksPanel.tsx#BackgroundTasksPanel"],
  pane: true,
  styles: () => import("./backgroundTasks.css"),
  load: () => import("./BackgroundTasksPanel").then((module) => module.BackgroundTasksPanel),
  variants: {
    "a-list": {
      note: "A: dense list, the transcript's shared subagent row (SubagentListRow) for agents, shells in the same shape.",
      props: props("list"),
    },
    "b-cards": {
      note: "B: Claude desktop cards: action, spend, View transcript, live output; finished as 28px lines.",
      props: props("cards"),
    },
    "c-grouped": {
      note: "C: 28px rows grouped by kind, workflow progress under its row, shell output inline.",
      props: props("grouped"),
    },
    "a-list-finished": { note: "A with Finished opened.", props: props("list"), play: openFinished },
    "b-cards-finished": { note: "B with Finished opened.", props: props("cards"), play: openFinished },
    "c-grouped-finished": { note: "C with Finished opened.", props: props("grouped"), play: openFinished },
  },
});
