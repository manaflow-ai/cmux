// l10n-allow-file: gallery fixtures (agents, commands, their output), not shipped UI.
// The Background tasks panel as a tab of its own, redesigned (Leo, 2026-11-24: "this bugged? or had an
// ultra slow load. and looked like ass ... there is no delineation between subagents and tool calls").
// No title (the tab says it), agents and commands told apart by a leading glyph, a command's output in
// the chat's Shell block with no "No output yet" filler, Open in terminal and Clear finished only on
// hover, and a drill-in with no empty spinner row. The three arms of backgroundTasksRows.experiment.ts
// differ in how the blocks sit; compare them in `compare`.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, row, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "../conversation/backgroundTaskOutput";
import type { AcpmuxRow } from "../model";
import type { BackgroundCommand } from "../session-info/processes";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { backgroundGroups } from "./backgroundTasks";
import { BackgroundTasksPanel } from "./BackgroundTasksPanel";
import { backgroundTasksRows } from "./backgroundTasksRows.experiment";

type Shape = "list" | "drill" | "idle";
type Props = { shape: Shape };

const SESSION = "gallery-bg-rows";

const agent = (id: string, task: string, minutes: number, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: task,
  task,
  kind: "general-purpose",
  state: "running",
  startedAt: minutesAgo(minutes),
  background: true,
  ...fields,
});

const STATUS = agent("agent-status", "Graceful thinking/tool-call status animation", 12);
const AUDIT = agent("agent-audit", "Audit the composer menus for fade-in", 31, {
  state: "completed",
  endedAt: minutesAgo(12),
});

const call = (title: string, minutes: number, seconds?: number) =>
  tool(title, "execute", seconds === undefined ? "in_progress" : "completed", {
    description: title,
    startedAt: minutesAgo(minutes),
    ...(seconds !== undefined && { endedAt: minutesAgo(minutes) + seconds * 1000, output: "ok" }),
  });

const VIEWS: Record<string, AcpmuxRow[]> = {
  [STATUS.id]: [
    user("Make the thinking and tool-call status animate gracefully", 12, { id: "status-ask" }),
    activity([call("Read the shimmer styles", 11, 3), call("Check status and owner of PR 50470", 1)], 11, {
      id: "status-steps",
    }),
  ],
  [AUDIT.id]: [user("Audit the composer menus for fade-in", 31, { id: "audit-ask" })],
};

const running = (id: string, command: string, description: string, minutes: number): BackgroundCommand => ({
  id,
  command,
  description,
  state: "running",
  toolCallId: `call-${id}`,
  processId: `proc-${id}`,
  startedAt: minutesAgo(minutes),
});
const finished = (id: string, command: string, description: string, minutes: number, ran: number) => ({
  ...running(id, command, description, minutes),
  state: "completed" as const,
  processId: undefined,
  endedAt: minutesAgo(minutes) + ran * 1000,
});

const OUTPUT = [
  "bun test v1.3.4",
  "",
  "test/background-tasks-open.test.tsx:",
  "(pass) splits its agents under Running and Finished [12.40ms]",
  "(pass) an agent's row opens its transcript [8.02ms]",
  "",
  " 41 pass",
  " 0 fail",
].join("\n");

const COMMANDS: BackgroundCommand[] = [
  running("a", "cd webviews && bun test test/background-tasks-open.test.tsx", "Run the panel tests", 0.4),
  running("b", "gh pr checks 50470 --watch", "Wait for the PR's checks", 0.2),
  finished("c", "git fetch origin feat-cmux-next", "Fetch the base", 6, 4),
  finished("d", "scripts/web-lint.sh", "Lint the web changes", 2, 38),
];

const encode = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const reader: BackgroundTaskOutputReader = {
  sessionId: SESSION,
  source: {
    listProcesses: async () => ({
      processes: COMMANDS.map((command) => ({
        id: command.processId ?? command.id,
        toolCallId: command.toolCallId,
        state: command.state === "running" ? "running" : "exited",
        harness: "claude",
      })),
    }),
    tailProcess: async (processId: string) => ({
      data: processId === "proc-a" ? encode(OUTPUT + "\n") : "",
      fromByte: 0,
    }),
  },
};

function RowsPanel({ shape }: Props) {
  const rows = [row(SUBAGENTS, 12, { id: "bg-group", subagents: [STATUS, AUDIT] })];
  const groups = backgroundGroups({
    rows,
    views: VIEWS,
    commands: shape === "idle" ? [] : COMMANDS,
    sessions: [],
    chatName: "This chat",
    sessionId: SESSION,
  });
  return (
    <BackgroundTaskOutputContext.Provider value={reader}>
      <div className="acpmux-shell" style={{ height: "100%" }}>
        <BackgroundTasksPanel
          groups={groups}
          views={VIEWS}
          initialDrill={shape === "drill" ? { agentId: STATUS.id } : undefined}
          onStop={async () => undefined}
          onClearFinished={() => undefined}
          onOpenCommand={() => undefined}
        />
      </div>
    </BackgroundTaskOutputContext.Provider>
  );
}

const openFinished = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector('[data-section="finished"] .acpmux-bg__section-head'));
  await ctx.click({ selector: '[data-section="finished"] .acpmux-bg__section-head' });
};

export default componentEntry<Props>({
  id: "agent-pane.background-tasks-rows",
  title: "Background tasks: rows and chrome",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 360, normal: 520 },
  covers: [
    "agent-session/acpmux/backgroundTasks/BackgroundTasksPanel.tsx",
    "agent-session/acpmux/backgroundTasks/SubagentTranscript.tsx",
    "agent-session/acpmux/backgroundTasks/BackgroundTaskCard.tsx",
  ],
  experiment: {
    definition: backgroundTasksRows,
    script: [{ name: "finished", run: openFinished }],
  },
  load: async () => RowsPanel,
  variants: {
    list: {
      note: "The tab's list: no title, agents (bot glyph) and commands (terminal glyph) told apart, a command's output in the chat's Shell block.",
      props: { shape: "list" },
    },
    "hover-actions": {
      note: "The pointer on a command's card shows Open in terminal on its head; Clear finished shows only on the Finished heading's hover.",
      props: { shape: "list" },
      play: async (ctx) => {
        await openFinished(ctx);
        await ctx.hover({ selector: '[data-section="finished"] .acpmux-bg__section-head' });
      },
    },
    "drill-in": {
      note: "An agent opened: back and its name, compact; its running call carries its own spinner and no empty spinner row follows it.",
      props: { shape: "drill" },
    },
    idle: {
      note: "Only agents, no commands.",
      props: { shape: "idle" },
    },
  },
});
