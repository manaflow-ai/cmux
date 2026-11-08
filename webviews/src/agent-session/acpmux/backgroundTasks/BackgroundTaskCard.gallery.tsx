// l10n-allow-file: gallery fixtures (commands, their output, task titles), not shipped UI.
// A background command in the Background tasks panel, rendered as Claude Desktop's panel renders it
// (Leo, 2026-11-07: "only showing the terminal thing, I don't think is very useful ... They have it
// as a properly rendered thing"): "Running N" with each running command as a card, open, its full
// command in mono, wrapped, then its output streaming or "No output yet"; then "Finished N", folded.
// The output comes through the reader the composer hat's tail polls (BackgroundTaskOutputContext),
// answered here by a fixture. Light and dark come from the gallery's appearance axis.
import { componentEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { BackgroundTaskOutputContext, type BackgroundTaskOutputReader } from "../conversation/backgroundTaskOutput";
import type { BackgroundCommand } from "../session-info/processes";
import { backgroundGroups } from "./backgroundTasks";
import { BackgroundTasksPanel } from "./BackgroundTasksPanel";

type Shape = "empty" | "output" | "long" | "finished";
type Props = { shape: Shape };

const SESSION = "gallery-bg-card";

const LONG = `T=~/.local/share/ws-sync/deploy/tools; timeout 280 $T/wt reclaim --dry-run --json > /tmp/scratch/reclaim.json 2>/tmp/scratch/reclaim.err; echo exit $?; python3 -I -c '
import json,sys,collections
d=json.load(open(sys.argv[1]))
rows=d if isinstance(d,list) else d.get("worktrees") or d.get("rows") or []
print(type(d).__name__, (list(d.keys())[:10] if isinstance(d,dict) else len(rows)))
' /tmp/scratch/reclaim.json`;

const OUTPUT = [
  "bun test v1.3.4",
  "",
  "test/background-tasks-open.test.tsx:",
  "(pass) splits its agents under Running and Finished [12.40ms]",
  "(pass) an agent's row opens its transcript [8.02ms]",
  "test/running-strip.test.ts:",
  "(pass) an open command's time and Open in terminal share one line [301.11ms]",
  "",
  " 41 pass",
  " 0 fail",
].join("\n");

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

function commandsFor(shape: Shape): BackgroundCommand[] {
  if (shape === "empty") return [running("a", "gh pr checks 37840 --watch", "Wait for the PR's checks", 0.2)];
  if (shape === "output")
    return [running("a", "cd webviews && bun test test/background-tasks-open.test.tsx", "Run the panel tests", 0.4)];
  if (shape === "long") return [running("a", LONG, "Dry-run wt reclaim to see reclaimable worktrees", 0.2)];
  return [
    running("a", LONG, "Dry-run wt reclaim to see reclaimable worktrees", 0.2),
    finished("b", "git fetch origin feat-cmux-next", "Fetch the base", 6, 4),
    finished("c", "bun run fmt -- src/agent-session/acpmux", "Format the changed files", 4, 2),
    finished("d", "scripts/web-lint.sh", "Lint the web changes", 2, 38),
  ];
}

const encode = (text: string) => btoa(String.fromCharCode(...new TextEncoder().encode(text)));

/// The registry as acpmux answers it: each running command's process, and its output file's end.
function reader(shape: Shape, commands: BackgroundCommand[]): BackgroundTaskOutputReader {
  return {
    sessionId: SESSION,
    source: {
      listProcesses: async () => ({
        processes: commands.map((command) => ({
          id: command.processId ?? command.id,
          toolCallId: command.toolCallId,
          state: command.state === "running" ? "running" : "exited",
          harness: "claude",
        })),
      }),
      tailProcess: async () => ({ data: shape === "output" ? encode(OUTPUT + "\n") : "", fromByte: 0 }),
    },
  };
}

function GalleryCardPanel({ shape }: Props) {
  const commands = commandsFor(shape);
  const groups = backgroundGroups({ rows: [], commands, sessions: [], chatName: "This chat", sessionId: SESSION });
  return (
    <BackgroundTaskOutputContext.Provider value={reader(shape, commands)}>
      <div className="acpmux-shell" style={{ height: "100%" }}>
        <BackgroundTasksPanel
          groups={groups}
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
  id: "agent-pane.background-task-card",
  title: "Background tasks: a command as a card",
  area: "Agent pane",
  pane: true,
  height: 520,
  widths: { narrow: 360, normal: 640 },
  covers: [
    "agent-session/acpmux/backgroundTasks/BackgroundTaskCard.tsx",
    "agent-session/acpmux/backgroundTasks/backgroundTaskCard.css",
  ],
  load: async () => GalleryCardPanel,
  variants: {
    "running-no-output": {
      note: "A command that has printed nothing yet: Running 1, its card open with the full command and No output yet.",
      props: { shape: "empty" },
    },
    "running-output": {
      note: "A command streaming output: its card shows the command, then the last lines it printed, the newest in view.",
      props: { shape: "output" },
    },
    "long-command": {
      note: "A long, multi-line command: every line shows in mono, wrapped, never cut to one line.",
      props: { shape: "long" },
    },
    "finished-collapsed": {
      note: "One running and three finished: Finished 3 is folded under Running 1, with Clear finished in the header.",
      props: { shape: "finished" },
    },
    "finished-expanded": {
      note: "Finished 3 opened: each finished command is a card, folded, with how long it took.",
      props: { shape: "finished" },
      play: openFinished,
    },
  },
});
