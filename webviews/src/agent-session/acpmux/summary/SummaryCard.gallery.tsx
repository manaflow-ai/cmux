// l10n-allow-file: gallery fixtures (sample commands, chat titles and files), not shipped UI.
// The chat's summary card (SummaryCard.tsx) as the inline column draws it, with background work
// live: commands from acpmux's process registry (running ones with their time and Stop, finished
// ones as compact status cards), chats the agent started under Subagents with their state,
// and the header's counts. An empty chat's card draws one quiet line and Attach files or folders,
// not a "None" under every title.
import { useState, type ComponentProps, type CSSProperties } from "react";
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, CWD, row, tool, user } from "../../../gallery/fixtures/acpmux";
import type { StartedSession } from "../started/startedSessions";
import type { SummaryCardControl } from "./cardState";
import type { SessionInfoProcess } from "../session-info/processes";
import { SummaryCard } from "./SummaryCard";
import { ArtifactPanel } from "../conversation/ArtifactPanel";
import { SummaryButton } from "./SummaryButton";
import type { WorkflowActions } from "./WorkflowSummary";
import type { WorkflowSummary } from "./workflow";
import { createWorkflowAdapter } from "./foldWorkflows";
import { realWorkflowFixture } from "../realWorkflowFixture";

type Props = Pick<
  ComponentProps<typeof SummaryCard>,
  "rows" | "background" | "sessions" | "onAttach" | "workflow" | "workflowActions" | "onOpenSessionInfo" | "tools"
> & { tabRowHeight?: number; preview?: boolean; popover?: boolean; sessionInfoPush?: boolean };

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

function GallerySummaryCard({ tabRowHeight, preview, popover, sessionInfoPush, ...props }: Props) {
  const [shown, setShown] = useState(true);
  const control = popover ? { ...card, column: false, shown, close: () => setShown(false) } : card;
  return (
    <div
      className="acpmux-shell"
      data-tab-row={tabRowHeight ? "" : undefined}
      data-session-info-chat-placement={sessionInfoPush ? "push" : undefined}
      style={
        {
          height: "100%",
          "--acpmux-tab-row-height": `${tabRowHeight ?? 0}px`,
          ...(sessionInfoPush
            ? {
                "--acpmux-session-info-top": tabRowHeight ? `${tabRowHeight}px` : "28px",
                // SessionInfo.tsx writes this as a measured shell px value. The fixture is 1000px
                // wide, with Preview's 46vw artifact resolving to 460px at that width.
                "--acpmux-header-room": preview ? "540px" : "1000px",
              }
            : {}),
        } as CSSProperties
      }
    >
      <div className="acpmux-main" data-summary="inline">
        {tabRowHeight !== undefined && (
          <div className="acpmux-stage">
            <header className="acpmux-header" data-tab-row={tabRowHeight ? "" : undefined}>
              <div />
              <div className="acpmux-header-tools">
                <SummaryButton card={control} />
              </div>
            </header>
          </div>
        )}
      </div>
      {sessionInfoPush && (
        <aside
          className="ui-glass ui-glass-floats acpmux-session-info"
          data-placement="push"
          data-presence="shown"
          aria-label="Session Info"
          style={
            {
              width: "220px",
              "--acpmux-session-info-top": tabRowHeight ? `${tabRowHeight}px` : "28px",
            } as CSSProperties
          }
        >
          <div className="acpmux-session-info__head">Session Info</div>
          <div className="acpmux-session-info__body">
            <div className="acpmux-session-info-section">Pushed Session Info</div>
          </div>
        </aside>
      )}
      {preview ? (
        <ArtifactPanel
          artifact={{ kind: "markdown", lang: "markdown", code: "# Preview\nA document beside the chat." }}
          onClose={none}
        />
      ) : sessionInfoPush ? null : (
        <SummaryCard
          card={control}
          environment={{
            summary: { sessionId: "gallery-session", cwd: CWD, branch: "feature/session-details" },
            machineName: "Development Mac",
            repository: "example/atlas-web",
            onOpenFolder: none,
          }}
          subagents={{ views: undefined, current: undefined, asks: new Set(), onOpen: none }}
          onOpenOutput={none}
          {...props}
        />
      )}
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
  }) satisfies SessionInfoProcess;
const processes: SessionInfoProcess[] = [
  record("dev", "bun run dev --port 5173", 26),
  record("watch", "tsc --noEmit --watch", 25),
  record("logs", "tail -f logs/server.log", 3),
  record("build", "cargo build --release", 24, "exited", 20),
  record("lint", "npm run lint", 22, "failed", 21),
  record("e2e", "bun test e2e --watch", 18, "killed", 9),
];

/// A busy chat: eight commands running and three finished, more than the card used to show before
/// "View all".
const manyProcesses: SessionInfoProcess[] = [
  ...processes.slice(0, 3),
  record("api", "bun run api --watch", 23),
  record("queue", "bun run worker:queue", 22),
  record("tunnel", "cloudflared tunnel run dev", 21),
  record("storybook", "bun run storybook", 19),
  record("db", "docker compose up postgres", 17),
  ...processes.slice(3),
];

const sessions: StartedSession[] = [
  { sessionId: "child-1", title: "Migrate the settings store to SQLite", state: "running", createdAt: minutesAgo(20) },
  { sessionId: "child-2", title: "Port the history page to React Aria", state: "running", createdAt: minutesAgo(19) },
  { sessionId: "child-3", title: "Rename the settings keys", state: "waiting", createdAt: minutesAgo(18) },
  { sessionId: "child-4", title: "Fix the flaky sidebar drag test", state: "failed", createdAt: minutesAgo(17) },
  { sessionId: "child-5", title: "Draft the release notes for 0.42", state: "idle", createdAt: minutesAgo(16) },
];

/// Seven started chats: more than the card used to show before "View all".
const manySessions: StartedSession[] = [
  ...sessions,
  { sessionId: "child-6", title: "Profile the transcript scroll", state: "running", createdAt: minutesAgo(15) },
  { sessionId: "child-7", title: "Audit the composer menus", state: "running", createdAt: minutesAgo(14) },
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
const [realWorkflow] = createWorkflowAdapter()(realWorkflowFixture(GALLERY_NOW), "gallery-session");

/// Two subagents, one still running, for the Subagents title and tab.
const liveSubagentRows = [
  ...rows,
  row("subagents", 1, {
    subagents: [
      {
        id: "explore-docs",
        name: "Explore docs",
        task: "Read the release docs",
        parent: null,
        state: "running",
        startedAt: minutesAgo(3),
      },
      {
        id: "check-links",
        name: "Check links",
        task: "Check every link",
        parent: null,
        state: "completed",
        startedAt: minutesAgo(3),
        endedAt: minutesAgo(1),
      },
    ],
  }),
];

/// A record from before acpmux reported subagents: Claude's Task tool as a titled `think` call.
const legacySubagentRows = [...rows, activity([tool("Audit the retry callers", "think", "in_progress")], 2)];

const background = (list: SessionInfoProcess[]) => ({
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
  covers: ["agent-session/acpmux/summary/SummaryTasks.tsx", "agent-session/acpmux/session-info/ChildSessionRows.tsx"],
  load: async () => GallerySummaryCard,
  variants: {
    "nested-sources-menu": {
      note: "Sources opens inside the floating Summary card. Dismissing or picking in the menu leaves the card open.",
      props: {
        popover: true,
        rows: [],
        onAttach: none,
        tools: {
          rows: [
            { id: "mcp:docs", name: "Documentation", kind: "mcp", source: "claude", enabled: true, canToggle: true },
          ],
          set: async () => "now",
        },
      },
    },
    "popover-environment": {
      note: "The toolbar popover begins with Environment and keeps activity counts in Subagents, without a title row.",
      props: { popover: true, rows, background: background(processes), sessions: { list: sessions, onOpen: none } },
    },
    "popover-legacy-subagents": {
      note: "An older record's Task-tool subagent beside a running command: the popover lists Subagents once.",
      props: { popover: true, rows: legacySubagentRows, background: background(processes.slice(0, 2)) },
    },
    "popover-subagents": {
      note: "A narrow pane's popover with live subagents: Environment first, and the Subagents title still opens the Subagents tab.",
      props: { popover: true, rows: liveSubagentRows, background: background(processes.slice(0, 2)) },
    },
    "inline-subagents": {
      note: "The inline column with the same live subagents: the Subagents title opens the Subagents tab beside Summary.",
      props: { rows: liveSubagentRows, background: background(processes.slice(0, 2)) },
    },
    "preview-tab-row": {
      note: "The Preview sibling obeys the same native tab-row clearance, both beside the chat and covering a narrow pane.",
      props: { tabRowHeight: 32, preview: true, rows: [] },
    },
    "preview-pushed-inspector-tab-row": {
      note: "Preview and a pushed Session Info card share the pane; the native tools span both side-panel terms.",
      props: { tabRowHeight: 32, preview: true, sessionInfoPush: true, rows: [] },
    },
    "inspector-pushed-tab-row": {
      note: "A pushed Session Info card keeps the native tools at the pane edge.",
      props: { tabRowHeight: 32, sessionInfoPush: true, rows: [] },
    },
    "session-info-pushed-no-tab-row": {
      note: "A pushed Session Info card keeps ordinary header tools in place when no native row is active.",
      props: { tabRowHeight: 0, sessionInfoPush: true, rows: [] },
    },
    "shared-tab-row": {
      note: "The inline Summary column beside the chat, under a 32px native tab row. A running subagent, two commands and failed, stopped and done subagents make counts longer than the column, so they end in a right ellipsis, outside the native header holes.",
      props: {
        tabRowHeight: 32,
        rows: [
          ...rows,
          row("subagents", 1, {
            subagents: [
              {
                id: "running-review",
                name: "Running review",
                task: "Running review",
                parent: null,
                state: "running",
                startedAt: minutesAgo(2),
              },
              {
                id: "failed-review",
                name: "Review",
                task: "Review",
                parent: null,
                state: "failed",
                startedAt: minutesAgo(2),
                endedAt: minutesAgo(1),
              },
              {
                id: "stopped-review",
                name: "Stopped check",
                task: "Stopped check",
                parent: null,
                state: "cancelled",
                startedAt: minutesAgo(2),
                endedAt: minutesAgo(1),
              },
              {
                id: "done-review",
                name: "Checks",
                task: "Checks",
                parent: null,
                state: "completed",
                startedAt: minutesAgo(2),
                endedAt: minutesAgo(1),
              },
            ],
          }),
        ],
        background: background(processes.slice(0, 2)),
      },
    },
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
    "workflow-real-run": {
      note: "Labs-only summary card fed by the scrubbed recording of a real Claude Workflow run: 3 completed agents across Count and Report, with elapsed time and token usage from the stream.",
      props: {
        rows,
        background: background(processes),
        sessions: { list: sessions, onOpen: none },
        workflow: realWorkflow,
        workflowActions,
      },
    },
    "long-lists": {
      note: "Every row of a long list is drawn and scrolls in the card, with no View all; Background tasks and Subagents end with Open in right pane, which opens that Session Info section beside the chat.",
      props: {
        rows,
        background: background(manyProcesses),
        sessions: { list: manySessions, onOpen: none },
        onOpenSessionInfo: none,
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
