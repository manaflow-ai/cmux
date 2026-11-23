// l10n-allow-file: gallery fixtures (sample prompts, commands, summaries and replies), not shipped UI.
// Background tasks worth a response and not (Leo, 2026-11-03: "there's like... background tasks worth
// responding to and not worth responding to", after "i mean can these possibly be more graceful?").
// acpmux weighs each task's end from its own event (hub/background_cause.rs): a step a subagent ran
// or an interim stop is silent, a command that exited or a subagent's final report is a result, a
// failure is a failure. Compare arms shows the `background-reaction-look` experiment's four looks of
// the same chat: on the call (default), on the call without the new mark, a named line, and the
// folded run that shipped before.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxBackgroundCause, AcpmuxBackgroundReaction, AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { drawsBackgroundTurnLines } from "./backgroundTurnLook.experiment";
import { backgroundReactionLook } from "./backgroundReaction.experiment";

/// A background turn's line as acpmux's records leave it: weighed by `cause`, its mark on the call
/// when `attached`; one that said something there is the agent's own turn (`ownTurn`, direct.ts
/// `settleReaction`), its reply a message of its own.
const turn = (
  id: string,
  minutes: number,
  cause: AcpmuxBackgroundCause,
  quiet = true,
  attached = true,
  said = false,
): AcpmuxRow =>
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: {
      id,
      trigger: "task_notification",
      running: false,
      quiet,
      reason: "result",
      hasRows: true,
      cause,
      ...(attached && { attached: true as const }),
      ...(said && { ownTurn: true as const }),
    },
  });
const reply = (id: string, text: string, minutes: number) =>
  assistant(text, minutes, { id: `${id}-reply`, inBackground: id });

const reaction = (turnId: string, weight: AcpmuxBackgroundReaction["weight"], fresh = false) => ({
  turn: turnId,
  weight,
  ...(fresh && { fresh: true as const }),
});

const suite = tool("cargo test --workspace", "execute", "completed", {
  id: "gallery-react-suite",
  command: "cargo test --workspace",
  description: "Run the workspace tests in the background",
  output: "test result: ok. 412 passed; 0 failed",
  background: { state: "completed" },
  reaction: reaction("gallery-react-done", "result", true),
});
const bench = tool("cargo bench -p orders", "execute", "failed", {
  id: "gallery-react-bench",
  command: "cargo bench -p orders",
  description: "Run the orders bench in the background",
  output: "error: bench `backfill` panicked",
  background: { state: "failed" },
});

const opening = [
  user("Run the tests and the orders bench in the background, and have a subagent review the PR", 14, {
    id: "gallery-react-prompt",
  }),
  // Each call in its own run: a note of two paragraphs keeps the runs apart (turns.ts
  // mergeShortNotes), so the suite's call draws as its own row.
  activity([suite], 13.9),
  assistant("Started the workspace tests.\n\nOn to the bench.", 13.85),
  activity([bench], 13.82),
  assistant("Started both, and a reviewer.", 13.8),
  summary(13.8, { status: "completed", durationMs: 6_000 }),
];

const step = (id: string, minutes: number) => [
  turn(
    id,
    minutes,
    { kind: "subagent_step", status: "completed", weight: "silent", origin: `${id}-call` },
    true,
    false,
  ),
  reply(id, "·", minutes - 0.05),
];

/// Leo's chat, weighed: the reviewer's steps (silent), the suite's interim stop and its final result,
/// and the bench's failure.
const weighedChat: AcpmuxRow[] = [
  ...opening,
  ...step("gallery-react-step-a", 12),
  ...step("gallery-react-step-b", 11),
  turn(
    "gallery-react-wait",
    10,
    { kind: "shell", status: "interim", weight: "silent", origin: "gallery-react-suite" },
    true,
    true,
    true,
  ),
  reply("gallery-react-wait", "Still waiting on the suite.", 9.95),
  turn(
    "gallery-react-done",
    9,
    {
      kind: "shell",
      status: "completed",
      weight: "result",
      origin: "gallery-react-suite",
      summary: 'Background command "Run the workspace tests" completed (exit code 0)',
    },
    true,
    true,
    true,
  ),
  reply("gallery-react-done", "All 412 tests passed.", 8.95),
  turn(
    "gallery-react-bench",
    8,
    {
      kind: "shell",
      status: "failed",
      weight: "failure",
      origin: "gallery-react-bench",
      summary: 'Background command "Run the orders bench" failed (exit code 101)',
    },
    true,
    false,
  ),
  reply("gallery-react-bench", ".", 7.95),
];

/// A result the agent answered with something to say: its reply draws as a message in every arm.
const loudResult: AcpmuxRow[] = [
  ...opening,
  turn(
    "gallery-react-loud",
    9,
    { kind: "shell", status: "completed", weight: "result", origin: "gallery-react-suite" },
    false,
  ),
  reply(
    "gallery-react-loud",
    "The suite passed, but `orders_backfill` took 3x longer than on main. Want me to bisect?",
    8.95,
  ),
];

/// Opens the suite's call (a harness that folds a finished turn's work opens "Worked for" first).
const openSuite = async (ctx: import("../../../gallery/play").PlayContext) => {
  if (ctx.document.querySelector(".cv-worked.is-toggle")) await ctx.click({ selector: ".cv-worked.is-toggle" });
  await ctx.waitFor(() => ctx.document.querySelector('[data-tool-id="gallery-react-suite"]'));
  const call = { selector: '[data-tool-id="gallery-react-suite"]' };
  await ctx.click(call);
  await ctx.waitFor(() => ctx.find(call).getAttribute("aria-expanded") === "true");
};

export default agentPaneEntry({
  id: "agent-pane.background-reactions",
  title: "Background task reactions",
  area: "Agent pane",
  height: 460,
  covers: [
    "agent-session/acpmux/conversation/backgroundTurns.ts",
    "agent-session/acpmux/conversation/ReactionMark.tsx",
    "agent-session/acpmux/conversation/BackgroundTurnLine.tsx",
  ],
  variants: {
    weighed: {
      note: "Two subagent steps and an interim stop (silent), the suite's final result, the bench's failure. On the call: no row for the silent ones, the suite's call marked new, the agent's replies to the suite as its own messages, the failure's line in sight.",
      snapshot: chat(weighedChat),
    },
    "weighed-hover": {
      note: "The background turn's line under the pointer: its words light all the way through, as a tool row's do (Leo, 2026-11-09).",
      snapshot: chat(weighedChat),
      play: async (ctx) => {
        // The line look's line (backgroundTurnLook.experiment.ts); the inline look draws none.
        if (!drawsBackgroundTurnLines()) return;
        await ctx.hover({ selector: "button.cv-background-turn .cv-agent-activity__sentence" });
      },
    },
    "call-opened": {
      note: "The suite's call opened: its output alone; the agent's replies to its end stay its own messages under it (Leo, 2026-11-09).",
      snapshot: chat(weighedChat),
      checks: {
        layoutShiftMax: { value: 0.5, reason: "Opening the call intentionally reveals its output below it." },
      },
      play: openSuite,
    },
    "loud-result": {
      note: "A result the agent answered with something to say draws its reply as a message, in every arm.",
      snapshot: chat(loudResult),
    },
  },
  experiment: { definition: backgroundReactionLook, script: [{ name: "open the suite's call", run: openSuite }] },
});
