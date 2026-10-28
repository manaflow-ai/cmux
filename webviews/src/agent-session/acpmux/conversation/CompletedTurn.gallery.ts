// l10n-allow-file: public-safe gallery fixture dialogue, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../../gallery/play";
import type { AcpmuxRow } from "../model";

const reports = Array.from({ length: 24 }, (_, index) => {
  const name = `worker-${index + 1}`;
  const text = `Report ${index + 1}: the focused checks passed.\n\n- The retry path is covered.\n- No follow-up is needed.`;
  return user(text, 7 - index / 10, {
    id: `completed-report-${index}`,
    promptId: `completed-report-prompt-${index}`,
    // The recorded steer relation puts this message inside the active turn. A standalone
    // received prompt without that relation would open its own turn.
    steer: "landed",
    incoming: { kind: "message", message: { name, text, raw: text } },
    untyped: true,
  });
});

const work: AcpmuxRow[] = [
  user("Collect the review and test reports, then summarize what shipped.", 9, { id: "completed-user" }),
  assistant("I will collect the review reports and keep the checks in view while the work runs.", 8.9, {
    id: "completed-progress",
  }),
  activity(
    [
      tool("Read src/retry.ts", "read", "completed"),
      tool("bun test src/retry", "execute", "completed", {
        command: "bun test src/retry",
        output: "24 pass\n0 fail",
        exitCode: 0,
      }),
    ],
    8.8,
    { id: "completed-tools" },
  ),
  assistant(
    "The first checks are complete. The retry helper now keeps the original request context.\n\nI am waiting for the remaining reports before publishing the final result.",
    7.5,
    { id: "completed-intermediate" },
  ),
  ...reports,
  assistant(
    "All 24 reports are in. The retry fix shipped.\n\nThe focused checks passed, and every earlier report remains available under the work disclosure.",
    4.3,
    { id: "completed-answer" },
  ),
];
const ended = [
  ...work,
  summary(4.3, { id: "completed-summary", status: "completed", durationMs: 282_000, toolCount: 2 }),
];

const openWorked = async (ctx: PlayContext) => {
  await ctx.click({ selector: ".cv-worked.is-toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(".cv-worked.is-toggle")?.getAttribute("aria-expanded") === "true");
};

export default agentPaneEntry({
  id: "agent-pane.completed-turn",
  title: "Completed turn disclosure",
  area: "Agent pane",
  height: 640,
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  variants: {
    "completed-collapsed": {
      note: "The completed turn's intermediate prose, tools, and 24 received reports share one quiet Worked-for line.",
      snapshot: chat(ended),
    },
    "completed-expanded": {
      note: "One click reveals the original intermediate prose, tool summaries, and all received reports.",
      snapshot: chat(ended),
      play: openWorked,
      checks: {
        layoutShiftMax: {
          value: 0.25,
          reason: "Opening the work disclosure intentionally reveals its transcript rows.",
        },
      },
    },
    "running-reports": {
      note: "While work runs, intermediate dialogue and received reports keep today's live visibility.",
      snapshot: chat(work.slice(0, -1), { isWorking: true }),
    },
    "stopped-collapsed": {
      note: "A stopped turn keeps its reason on the single disclosure and its final answer below it.",
      snapshot: chat([...work, summary(4.3, { id: "stopped-summary", status: "cancelled", durationMs: 282_000 })]),
    },
  },
});
