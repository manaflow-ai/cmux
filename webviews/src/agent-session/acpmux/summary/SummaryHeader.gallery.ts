// l10n-allow-file: gallery fixtures, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SUBAGENTS } from "../subagents/subagentFold";

const snapshot = chat([
  user("Keep the server and watcher running while reviewing the changes", 8),
  activity(
    ["bun run dev", "tsc --watch"].map((command) =>
      tool(command, "execute", "completed", {
        inputSummary: JSON.stringify({ command, run_in_background: true }),
        startedAt: minutesAgo(7),
      }),
    ),
    7,
  ),
  row(SUBAGENTS, 6, {
    subagents: [{ id: "reviewer", parent: null, name: "Review changes", task: "Review changes", state: "failed", startedAt: minutesAgo(6), endedAt: minutesAgo(5) }],
  }),
  assistant("The two commands remain active. The review failed and can be restarted.", 4),
]);

export default agentPaneEntry({
  id: "agent-pane.summary-header",
  title: "Summary header over the transcript",
  area: "Agent pane",
  covers: ["agent-session/acpmux/summary/SummaryCard.tsx"],
  height: 640,
  widths: { narrow: 1400, normal: 1600 },
  variants: {
    "commands-and-failure": {
      snapshot,
      native: { "pane.tabState": { inspector: false } },
    },
  },
});
