// l10n-allow-file: gallery fixtures (sample commands, chat titles and files), not shipped UI.
// The chat's summary card (SummaryCard.tsx) as the inline column draws it, with background work
// live: commands from acpmux's process registry (running ones with their time and Stop, finished
// ones as compact status cards), chats the agent started under Subagents with their state,
// and the header's counts. An empty chat's card draws one quiet line and Attach files or folders,
// not a "None" under every title.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, CWD, tool, user } from "../../../gallery/fixtures/acpmux";
import type { StartedSession } from "../started/startedSessions";
import type { SummaryCardControl } from "./cardState";
import type { InspectorProcess } from "../inspector/processes";
import { SummaryCard } from "./SummaryCard";
import type { WorkflowActions } from "./WorkflowSummary";
import type { WorkflowSummary } from "./workflow";

type Props = Pick<
  ComponentProps<typeof SummaryCard>,
  "rows" | "background" | "sessions" | "onAttach" | "workflow" | "workflowActions"
>;

const none = () => undefined;
/// The inline column, shown and open.
const card: SummaryCardControl = {
  shown: true,
  column: true,
  reserve: false,
  collapsed: false,
  toggle: none,
  show: none,
  close: none,
  fold: none,
};

function GallerySummaryCard(props: Props) {
  return (
    <div className="acpmux-shell" style={{ justifyContent: "flex-end", height: "100%" }}>
      <div className="acpmux-main" data-summary="inline" style={{ display: "flex", justifyContent: "flex-end" }}>
        <SummaryCard
          card={card}
          subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen: none }}
          onOpenOutput={none}
          {...props}
        />
      </div>
    </div>
  );
}

const edit = (path: string, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, oldText: undefined, newText }] });

const rows = [
  user("Run the dev server and the watchers, then split the migration into three chats", 30),
  activity([edit("src/net/retry.ts", "export async function retry() {}\n")], 28),
];

/// The registry's records: three running, three finished.
const record = (id: string, command: string, startedMin: number, state = "running", endedMin?: number) =>
  ({
    id: `gallery-session/${id}`,
    toolCallId: `call-${id}`,
    command,
    startedAt: minutesAgo(startedMin),
    state,
    ...(endedMin !== undefined ? { endedAt: minutesAgo(endedMin) } : {}),
  }) satisfies InspectorProcess;
const processes: InspectorProcess[] = [
  record("dev", "bun run dev --port 5173", 26),
  record("watch", "tsc --noEmit --watch", 25),
  record("logs", "tail -f logs/server.log", 3),
  record("build", "cargo build --release", 24, "exited", 20),
  record("lint", "npm run lint", 22, "failed", 21),
  record("e2e", "bun test e2e --watch", 18, "killed", 9),
];

const sessions: StartedSession[] = [
  { sessionId: "child-1", title: "Migrate the settings store to SQLite", state: "running", createdAt: minutesAgo(20) },
  { sessionId: "child-2", title: "Port the history page to React Aria", state: "running", createdAt: minutesAgo(19) },
  { sessionId: "child-3", title: "Rename the settings keys", state: "waiting", createdAt: minutesAgo(18) },
  { sessionId: "child-4", title: "Fix the flaky sidebar drag test", state: "failed", createdAt: minutesAgo(17) },
  { sessionId: "child-5", title: "Draft the release notes for 0.42", state: "idle", createdAt: minutesAgo(16) },
];

const workflow: WorkflowSummary = {
  id: "workflow-migration",
  title: "Migration workflow",
  state: "running",
  phase: "implement",
  elapsedMs: 92_000,
  tokens: 18_420,
  phases: [
    { id: "plan", name: "Plan", state: "completed", agentIds: ["planner"] },
    { id: "implement", name: "Implement", state: "running", agentIds: ["api", "ui"] },
    { id: "verify", name: "Verify", state: "pending", agentIds: ["tests"] },
  ],
  agents: [
    { id: "planner", name: "Planner", state: "completed", tokens: 3_200, transcriptRowId: "row-plan" },
    {
      id: "api",
      name: "API",
      state: "running",
      doing: "Updating the transport seam",
      tokens: 8_400,
      transcriptRowId: "row-api",
    },
    {
      id: "ui",
      name: "UI",
      state: "waiting",
      doing: "Waiting for API types",
      tokens: 5_100,
      transcriptRowId: "row-ui",
    },
    { id: "tests", name: "Tests", state: "pending" },
  ],
  selectedAgentId: "api",
};
const workflowActions: WorkflowActions = { onPause: none, onStop: none, onSave: none, onOpenTranscript: none };

const background = (list: InspectorProcess[]) => ({
  processes: list,
  listed: true,
  running: [],
  onStop: async () => undefined,
});

export default componentEntry<Props>({
  id: "agent-pane.summary-card",
  title: "Summary card",
  area: "Agent pane",
  pane: true,
  height: 560,
  widths: { narrow: 300, normal: 360 },
  covers: ["agent-session/acpmux/summary/SummaryTasks.tsx", "agent-session/acpmux/inspector/ChildSessionRows.tsx"],
  load: async () => GallerySummaryCard,
  variants: {
    "background-work": {
      note: "Three commands running, newest first with their time and Stop; three finished as compact status cards. Five started chats under Subagents: waiting, running, failed, done.",
      props: { rows, background: background(processes), sessions: { list: sessions, onOpen: none } },
    },
    "workflow-labs": {
      note: "Labs-only workflow summary: progress, elapsed time and tokens; opening it shows phases, selected agents, transcript links and action affordances.",
      props: {
        rows,
        background: background(processes),
        sessions: { list: sessions, onOpen: none },
        workflow,
        workflowActions,
      },
    },
    "finished-open": {
      note: "Finished commands remain visible as individual cards with their state and detail.",
      props: { rows, background: background(processes), sessions: { list: [], onOpen: none } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-summary-task").length === 6);
      },
    },
    empty: {
      note: "A chat with nothing yet: one quiet line and Attach files or folders, no empty sections.",
      props: { rows: [user("What does this repository do?", 2)], onAttach: none },
    },
  },
});
