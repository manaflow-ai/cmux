// l10n-allow-file: synthetic chat and context readings for the parity workbench.
import { agentPaneEntry } from "../format";
import { assistant, chat, summary, user } from "../fixtures/acpmux";
import type { SessionUsageStats } from "../../agent-session/acpmux/usageStats";

const saved: SessionUsageStats = {
  autocompact: "capped",
  autocompactCap: 400_000,
  contextTokens: 160_000,
  contextWindow: 1_000_000,
  updatedAt: 1,
};
const base = chat(
  [
    user("Review the workspace routing change.", 5),
    assistant("The review is complete. The routing change and its checks are ready.", 4),
    summary(4, { status: "completed", durationMs: 44_000 }),
  ],
  { title: "Reopened chat / context usage" },
);

function snapshot(stats?: SessionUsageStats) {
  return {
    ...base,
    summary: {
      ...base.summary,
      sessionId: base.sessionId ?? "gallery-session",
      usage: undefined,
      usageStats: stats,
    },
  };
}

export default agentPaneEntry({
  id: "agent-pane.parity-context-usage",
  title: "Reopened chat / context usage",
  area: "Agent pane",
  height: 600,
  covers: ["agent-session/acpmux/usageStats.ts", "agent-session/acpmux/ComposerPickers.tsx#ContextRing"],
  variants: {
    restored: {
      note: "A populated chat has no live usage event. Its saved 160K context and 400K compact window show 40%.",
      snapshot: snapshot(saved),
      play: async ({ document, waitFor, hover }) => {
        await waitFor(() => document.querySelector(".acpmux-context-ring .acpmux-context-used"));
        await hover({ selector: ".acpmux-context-ring" });
        await waitFor(() => document.querySelector(".acpmux-context-card"));
      },
    },
    unknown: {
      note: "History is present but the harness has reported no token counts. Hover explains Not reported; no 0% is invented.",
      snapshot: snapshot(),
      play: async ({ document, waitFor }) => {
        await waitFor(() => document.querySelector('.acpmux-context-ring[aria-disabled="true"][title]'));
        if (document.querySelector(".acpmux-context-ring .acpmux-context-used"))
          throw new Error("Unknown context must not show a measured usage arc");
      },
    },
  },
});
