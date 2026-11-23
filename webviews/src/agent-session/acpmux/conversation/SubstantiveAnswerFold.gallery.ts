// l10n-allow-file: gallery fixtures (sample prompts, tool calls and replies), not shipped UI.
// A substantive answer stays visible when a later tool is followed by a short receipt. The fold
// keeps the work and real narration, and opening it still reveals the tool in its source order.
// Regression: Leo, 2026-11-13, the answer and markdown table disappeared into "Worked for".
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

const answer =
  "Small is slower because startup dominates.\n\n" +
  "| lane | time |\n" +
  "| --- | ---: |\n" +
  "| small | 14s |\n" +
  "| huge | 3s |\n\n" +
  "The larger lane amortizes the setup cost.";

const ask = () =>
  activity(
    [
      tool("Ask the socket-ready lane why small is slower than huge", "other", "completed", {
        inputSummary: "why small is slower than huge",
        output: "The startup cost dominates the small lane.\n",
      }),
    ],
    19,
  );

const finished = (): AcpmuxRow[] => [
  user("Compare the small and huge lanes", 30),
  assistant(answer, 27),
  ask(),
  assistant("I sent the question.", 17),
  summary(16, { durationMs: 14_000, toolCount: 1, status: "completed" }),
];

const live = (): AcpmuxRow[] => [
  user("Compare the small and huge lanes", 30),
  assistant(answer, 27),
  ask(),
  assistant("I sent the question.", 17),
];

const narration = (): AcpmuxRow[] => [
  user("Check the lane startup cost", 30),
  assistant("Let me check the lane first.", 27),
  activity([tool("Read the lane timings", "read", "completed", { output: "small 14s\nhuge 3s\n" })], 24),
  assistant("Checking the log next.", 21),
  activity([tool("Run the timing comparison", "execute", "completed", { output: "ok\n" })], 18),
  summary(16, { durationMs: 14_000, toolCount: 2, status: "completed" }),
];

const answerOnly = (): AcpmuxRow[] => [
  user("What changed?", 20),
  assistant("The small lane now reuses its startup state, so its next run is as fast as the huge lane.", 17),
  summary(16, { durationMs: 4_000, toolCount: 0, status: "completed" }),
];

const snapshot = (rows: AcpmuxRow[], isWorking = false) => {
  const base = chat(rows, {
    title: "Substantive answer before a tool",
    harness: "claude",
    isWorking,
  });
  return { ...base, summary: { ...base.summary!, family: "claude" } };
};

const openWorked: Play = async (ctx) => {
  const worked = () => ctx.document.querySelector<HTMLElement>(".cv-worked");
  if (worked()?.getAttribute("aria-expanded") === "false") {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => worked()?.getAttribute("aria-expanded") === "true", { capMs: 10_000 });
  }
};

const variant = (rows: AcpmuxRow[], note: string, play?: Play): AgentPaneVariant => ({
  note,
  snapshot: snapshot(rows),
  ...(play && { play }),
});

export default agentPaneEntry({
  id: "agent-pane.substantive-answer-fold",
  title: "Substantive answer before a tool",
  area: "Agent pane",
  height: 680,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  variants: {
    "table-before-tool": variant(
      finished(),
      "Finished: the full answer and markdown table stay above the short receipt; Worked for holds only the tool.",
    ),
    "table-before-tool-open": variant(
      finished(),
      "Opened: the answer remains in place and the socket-ready lane tool is revealed under the fold.",
      openWorked,
    ),
    "table-before-tool-live": {
      note: "Streaming: the answer and short receipt stay visible while the turn is still working.",
      snapshot: snapshot(live(), true),
    },
    "narration-only": variant(
      narration(),
      "Narration-only: Let me check… and Checking the log next. remain folded with the two tools.",
    ),
    "answer-only": variant(answerOnly(), "Answer-only: a substantive answer with no work has no empty Worked for row."),
  },
});
