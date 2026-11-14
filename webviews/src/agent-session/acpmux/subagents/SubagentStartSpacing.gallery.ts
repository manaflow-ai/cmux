// l10n-allow-file: gallery fixtures (task names, prompts and replies), not shipped UI.
// The room under a subagent's start line ("✧ Promote prod + auto delivery started working").
// Leo, 2026-11-14 ~21:15Z, on a Claude chat where the reply under that line stood a turn gap away:
// "the spacing after the subagent starting is inconsistent? it grows too big". The start line is a
// one-line status row: the next row stands from it as from any other one-line row, flush on the 22
// pitch under another line, the run gap over prose (transcriptGrid.ts transcriptGap, design/
// transcript-spacing.md rules 3 and 4). `recorded` replays his turn's events, every word replaced
// (fixtures/recordings/subagent-start-then-reply.ndjson); the others put each kind of row under the
// line. test/subagent-start-spacing.test.ts measures them in Chromium.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const recorded = {
  events: async () =>
    (await import("../../../gallery/fixtures/recordings/subagent-start-then-reply.ndjson?raw")).default,
  harness: "claude" as const,
};

const agent = (id: string, name: string, minutes: number): Subagent => ({
  id,
  parent: null,
  name,
  task: name,
  prompt: `${name}.`,
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
});
const group = (id: string, subagent: Subagent, minutes: number) =>
  row(SUBAGENTS, minutes, { id, subagents: [subagent] });
const REPLY =
  "Production is moving to the new build. A helper is doing both: the promote now, and the automatic delivery after it.";
const claude = { harness: "claude", model: "claude-opus-5-5", title: "Subagent start spacing" };

/** A finished turn's rows: its work folds under "Worked for", the start line stays out under it, then `after`. */
const finishedRows = (after: ReturnType<typeof row>[]) => [
  user("Release production and set up automatic delivery.", 3, { id: "start-prompt" }),
  activity([tool("Checked the release head", "execute", "completed")], 2.9, { id: "start-work" }),
  group("start-group", agent("start-agent", "Promote prod + auto delivery", 2.8), 2.8),
  ...after,
  summary(2.5, { id: "start-summary", status: "completed", durationMs: 45_000 }),
];
const finished = (after: ReturnType<typeof row>[]) => chat(finishedRows(after), claude);
const replyRow = () => assistant(REPLY, 2.6, { id: "start-reply", assistantPhase: "final_answer" });
/** The finished turn with its reply, built again: a reload makes new row objects for the same rows. */
const reloaded = () => finished([replyRow()]);

export default agentPaneEntry({
  id: "agent-pane.subagent-start-spacing",
  title: "The room under a subagent's start line",
  area: "Agent pane",
  height: 560,
  covers: [
    "agent-session/acpmux/subagents/SubagentStartedLine.tsx",
    "agent-session/acpmux/transcriptGrid.ts#transcriptGap",
  ],
  variants: {
    recorded: {
      note: "Leo's capture, replayed: Worked for, the start line, then the reply 16 under it (the run gap), not a turn gap.",
      snapshot: chat([], claude),
      recording: recorded,
    },
    "then-text": {
      note: "A reply under the start line: the run gap, as under any one-line row.",
      snapshot: finished([assistant(REPLY, 2.6, { id: "start-reply", assistantPhase: "final_answer" })]),
    },
    "reload-batches": {
      note: "After a restart the rows come back in batches: the turn's head first (the start line last on screen), then the reply and the rest. The reply stands the run gap under the line, as in one batch.",
      snapshot: chat(finishedRows([]).slice(0, 3), { ...claude, isWorking: true }),
      afterCall: { "pane.painted": reloaded() },
    },
    "reload-older-batch": {
      note: "After a restart the newest rows come first (the start line, the reply), then the older page lands above them.",
      snapshot: chat(finishedRows([replyRow()]).slice(2), claude),
      afterCall: { "pane.painted": reloaded() },
    },
    "then-subagent": {
      note: "Another subagent's start line under it: flush on the 22 pitch, then the reply.",
      snapshot: finished([
        group("start-group-2", agent("start-agent-2", "Review the delivery workflow", 2.7), 2.7),
        assistant(REPLY, 2.6, { id: "start-reply", assistantPhase: "final_answer" }),
      ]),
    },
    "then-tool": {
      note: "A running turn: a tool row under the start line, flush on the 22 pitch.",
      snapshot: chat(
        [
          user("Release production and set up automatic delivery.", 3, { id: "start-prompt" }),
          group("start-group", agent("start-agent", "Promote prod + auto delivery", 2.8), 2.8),
          activity([tool("Read the promote workflow", "read", "completed")], 2.7, { id: "start-tool" }),
          assistant(REPLY, 2.6, { id: "start-reply" }),
        ],
        { ...claude, isWorking: true },
      ),
    },
  },
});
