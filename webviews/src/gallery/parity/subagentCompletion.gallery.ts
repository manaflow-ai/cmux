// l10n-allow-file: gallery fixture task and report text, not shipped UI.
import { agentPaneEntry } from "../format";
import { minutesAgo } from "../clock";
import { assistant, chat, row, summary, user } from "../fixtures/acpmux";
import { SUBAGENTS } from "../../agent-session/acpmux/subagents/subagentFold";
import type { Subagent } from "../../agent-session/acpmux/subagents/subagentFold";
import type { PlayContext } from "../play";

const REPORT = "Reviewed the settings corners. The window clips correctly, and the corner tests pass.";
const agent: Subagent = {
  id: "parity-settings-corner-review",
  parent: null,
  name: "Settings corner review",
  task: "Settings corner review",
  prompt: "Review the settings window corners.",
  state: "completed",
  startedAt: minutesAgo(1),
  endedAt: minutesAgo(0.75),
  result: REPORT,
};
const snapshot = chat(
  [
    user("Review the settings window corners.", 1),
    row(SUBAGENTS, 0.95, { id: "parity-completion-group", subagents: [agent] }),
    assistant("The review is complete.", 0.75, { assistantPhase: "final_answer" }),
    summary(0.75, { id: "parity-completion-summary", status: "completed", durationMs: 15_000 }),
  ],
  {
    subagentViews: { [agent.id]: [user(agent.prompt!, 1), assistant(REPORT, 0.75)] },
  },
);

async function ready(ctx: PlayContext) {
  await ctx.waitFor(
    () =>
      ctx.document.querySelector('[data-report-look="compact"] .cv-agent-activity__sentence')?.textContent ===
      "Settings corner review finished",
  );
}

export default agentPaneEntry({
  id: "agent-pane.parity-subagent-completion",
  title: "Compact subagent completion",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/subagents/SubagentDoneLine.tsx"],
  variants: {
    compact: {
      note: "The reference completion line: Settings corner review finished. The name opens the child transcript and report; hover or focus reveals the duration.",
      experiments: { "subagent-done-report": "compact" },
      snapshot,
      play: async (ctx) => {
        await ready(ctx);
        if (ctx.document.querySelector(".cv-subagent-done__report"))
          throw new Error("The completed report must start closed");
        if (ctx.document.querySelector(".cv-subagent-done__chevron"))
          throw new Error("The compact completion must not have a chevron");
        if (ctx.document.querySelector(".cv-subagent-report-row .cv-agentmsg__preview"))
          throw new Error("The compact completion must not preview its report");
      },
    },
    "report-open": {
      note: "The compact line opens the full report in the child transcript through its name.",
      experiments: { "subagent-done-report": "compact" },
      snapshot,
      play: async (ctx) => {
        await ready(ctx);
        await ctx.focus({ role: "button", name: "Open Settings corner review" });
        await ctx.click({ role: "button", name: "Open Settings corner review" });
        await ctx.waitFor(
          () =>
            ctx.document.querySelector(".cv-subagent-of") &&
            [...ctx.document.querySelectorAll(".cv-md")].some((node) =>
              node.textContent?.includes("corner tests pass"),
            ),
        );
      },
    },
  },
});
