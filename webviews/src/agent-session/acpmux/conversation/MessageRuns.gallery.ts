// l10n-allow-file: gallery fixtures (sample lanes, messages and commands), not shipped UI.
// A run of one-line rows that carries messages between agents folds into one line (Leo,
// 2026-11-01, on a turn of "Sent to" rows, a read, another agent's line, a compaction and "Ran a
// command, read a file", each on its own row: "this should be collapsible"). Drawn through the real
// transcript (turns.ts, messageRuns.ts, MessageRunLine.tsx), shaped like his screenshot.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow } from "../model";

const send = (to: string, message: string): AcpmuxActivity =>
  tool("SendMessage", "other", "completed", {
    inputSummary: JSON.stringify({ to, message }),
    output: `delivered to ${to}\n`,
  });
const read = (description: string, path: string): AcpmuxActivity =>
  tool(`Read ${path}`, "read", "completed", { description, locations: [{ path }] });
const run = (description: string, command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { description, command, output: "ok\n", exitCode: 0 });
const received = (name: string, text: string, minutes: number, harness?: string) =>
  user("", minutes, {
    continues: true,
    incoming: { kind: "message", message: { name, sessionId: name, text, raw: text, ...(harness ? { harness } : {}) } },
    untyped: true,
  });

/// The work of one coordinator turn as the screenshot shows it.
function work(): AcpmuxRow[] {
  return [
    activity(
      [
        send("lane-2/coord-dispatcher", "From claude-sr2-coord, for nightly-next freshness: the 21:00 cut is late."),
        send("lane-2/cpu-acpmux-index", "From claude-sr2-coord: re-profile on studio-mac with the new index."),
        read("Read probe 22 diagnostics", "/tmp/probe-22/diagnostics.log"),
        send("lane-12/cloud-item-11", "From claude-sr2-coord: probe 22 (HQ run 4131) failed at sign-in."),
      ],
      9,
    ),
    received(
      "opus-ui-verify",
      "Merged (3) cmux#30265, the real-shaped fixtures, as 03b289c3, a squash pinned to its head.",
      8.5,
      "claude",
    ),
    row("compaction", 8.4, { compaction: { state: "completed", preTokens: 369_000, postTokens: 24_000 } }),
    activity(
      [
        run("Listed the open lanes", "acpmux ls --json"),
        read("Read the lane notes", "/tmp/lanes/notes.md"),
        send("lane-2/ask-8a6cb9b118", "From claude-sr2-coord, answering your ask-8a6cb9b118: yes, land it."),
        send("lane-2/acpmux-owner", "From claude-sr2-coord: bug for you (acpmux): 'acpmux ls' hangs on a dead peer."),
        read("Read daemon exe links on build-box", "/tmp/build-box/daemon-links.txt"),
        send("lane-2/acpmux-owner", "From claude-sr2-coord: confirmed on build-box, the old exe is still linked."),
      ],
      8,
    ),
  ];
}

function finished(harness = "claude") {
  return chat(
    [
      user("Coordinate the lanes on tonight's nightly", 10),
      ...work(),
      assistant("Every lane has its orders, and the acpmux hang is with its owner.", 7.5),
      summary(7.4, { status: "completed", durationMs: 150_000, toolCount: 13 }),
    ],
    { title: "Coordinate the lanes", harness },
  );
}

function running() {
  return chat([user("Coordinate the lanes on tonight's nightly", 10), ...work()], {
    title: "Coordinate the lanes",
    isWorking: true,
  });
}

/// Opens the run's line, as a click does.
const openLine: Play = async (ctx) => {
  const line = () => ctx.document.querySelector<HTMLElement>("button[data-message-run]");
  await ctx.waitFor(line, { capMs: 10_000 });
  if (line()?.getAttribute("aria-expanded") === "false") await ctx.click({ selector: "button[data-message-run]" });
  await ctx.waitFor(() => line()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
};

/// A Codex turn: open its "Worked for" first, where the run folds the same way.
const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  await ctx.waitFor(worked, { capMs: 10_000 });
  if (worked()?.getAttribute("aria-expanded") === "false") await ctx.click({ selector: ".cv-worked" });
  await ctx.waitFor(() => ctx.document.querySelector("button[data-message-run]"), { capMs: 10_000 });
};

const variants: Record<string, AgentPaneVariant> = {
  folded: {
    note: "Selected default: a finished Claude turn's run of sends, reads, another agent's line and a compaction is one line, \"Sent 6 messages, read 3 files, ran a command, received a message\", closed.",
    snapshot: finished(),
  },
  open: {
    note: "The same line opened: every row as it drew before, each message on its own row.",
    snapshot: finished(),
    play: openLine,
  },
  running: {
    note: "A running turn: its finished run folds the same way, above the live line.",
    snapshot: running(),
  },
  codex: {
    note: "A Codex turn: inside its opened Worked for, the run folds the same way.",
    snapshot: finished("codex"),
    play: openWorked,
  },
};

export default agentPaneEntry({
  id: "agent-pane.message-runs",
  title: "Message runs",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/MessageRunLine.tsx", "agent-session/acpmux/conversation/messageRuns.ts"],
  variants,
});
