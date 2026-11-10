// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A run of background-task notifications folds into one line (backgroundRuns.ts), and a lone "."
// reply draws no row (visibleMessage.ts). Leo, 2026-11-02, on a chat that drew "Background task
// finished" four times, each with a lone "·" reply under it: "why do you still do these".
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { backgroundRunRowId } from "./backgroundRuns";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";

const quiet = (id: string, minutes: number): AcpmuxRow =>
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: { id, trigger: "task_notification", running: false, quiet: true, hasRows: true },
  });
/// What the agent did in a quiet background turn: read the task's log, then the lone "." an agent
/// sends to end a turn it had nothing to say in, which draws nothing.
const dot = (id: string, minutes: number) => [
  activity(
    [tool("tail -n 3 suite.log", "execute", "completed", { command: "tail -n 3 suite.log", output: "14 passed" })],
    minutes - 0.03,
    { id: `${id}-work`, inBackground: id },
  ),
  assistant(".", minutes - 0.05, { id: `${id}-dot`, inBackground: id }),
];
const opening = [
  user("Run the four suites in the background and tell me if anything breaks", 12),
  assistant("Started all four suites in the background.", 11.9),
  summary(11.9, { status: "completed", durationMs: 4_000 }),
];

/// Leo's chat: four quiet task turns in a row, each answered with ".".
const fourFinished = [
  ...opening,
  quiet("gallery-run-a", 10),
  ...dot("gallery-run-a", 10),
  quiet("gallery-run-b", 9),
  ...dot("gallery-run-b", 9),
  quiet("gallery-run-c", 8),
  ...dot("gallery-run-c", 8),
  quiet("gallery-run-d", 7),
  ...dot("gallery-run-d", 7),
];
const RUN = backgroundRunRowId(backgroundTurnRowId("gallery-run-a"));

/// A stopped shell among the quiet lines, as in Leo's screenshot.
const mixed = [
  ...opening,
  quiet("gallery-mix-a", 10),
  ...dot("gallery-mix-a", 10),
  row("backgroundTask", 9, {
    id: "gallery-mix-stopped",
    backgroundTask: { toolCallId: "gallery-mix-stopped", command: "Wait for rust tests", state: "stopped" },
  }),
  quiet("gallery-mix-b", 8),
  ...dot("gallery-mix-b", 8),
  quiet("gallery-mix-c", 7),
  ...dot("gallery-mix-c", 7),
];

/// Two quiet lines, a task the agent answered with something to say, then two more.
const withReply = [
  ...opening,
  quiet("gallery-reply-a", 10),
  ...dot("gallery-reply-a", 10),
  quiet("gallery-reply-b", 9),
  ...dot("gallery-reply-b", 9),
  row(BACKGROUND_TURN, 8, {
    id: backgroundTurnRowId("gallery-reply-loud"),
    background: { id: "gallery-reply-loud", trigger: "task_notification", running: false, quiet: false },
  }),
  activity(
    [tool("tail -n 3 orders.log", "execute", "completed", { command: "tail -n 3 orders.log", output: "2 failed" })],
    7.9,
    { inBackground: "gallery-reply-loud" },
  ),
  assistant("The orders suite failed: 2 of 14 tests in `orders_backfill`. Want me to look?", 7.8, {
    inBackground: "gallery-reply-loud",
  }),
  quiet("gallery-reply-c", 6),
  ...dot("gallery-reply-c", 6),
  quiet("gallery-reply-d", 5),
  ...dot("gallery-reply-d", 5),
];

export default agentPaneEntry({
  id: "agent-pane.background-runs",
  title: "Background task runs",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/backgroundRuns.ts",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
  ],
  variants: {
    closed: {
      note: "Four background tasks finished in a row; the agent read each one's log and answered with a lone dot. One muted line, 4 background tasks finished, closed; no dot draws. (A turn whose only reply is the dot has nothing to open and draws no line at all.)",
      snapshot: chat(fourFinished),
    },
    open: {
      note: "The same run opened: each Background task finished line again, in order, and still no dot. Play: open the run.",
      snapshot: chat(fourFinished),
      checks: {
        layoutShiftMax: {
          value: 0.5,
          reason: "Opening the run intentionally reveals its lines below the clicked line.",
        },
      },
      play: async (ctx) => {
        const line = { selector: `[data-row-id="${RUN}"] .cv-background-turn` };
        await ctx.click(line);
        await ctx.waitFor(() => ctx.find(line).getAttribute("aria-expanded") === "true");
      },
    },
    mixed: {
      note: "A stopped shell among the quiet lines, as in Leo's screenshot: one line, 4 background updates. A failed shell would stay on its own row.",
      snapshot: chat(mixed),
    },
    "reply-kept": {
      note: "A task the agent answered with something to say splits the run: 2 background tasks finished, its rows and reply as they came, then 2 more.",
      snapshot: chat(withReply),
    },
    "single-line": {
      note: "One quiet line alone stays as it was (no run of one); opened, its lone dot draws no row of its own.",
      snapshot: chat([...opening, quiet("gallery-one", 10), ...dot("gallery-one", 10)]),
    },
  },
});
