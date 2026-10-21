// l10n-allow-file: gallery fixtures (sample prompts and tool titles), not shipped UI.
// WORKING-LOOK (Leo 2026-10-20: a spinner on every running row "reads as noise"): the transcript's
// running rows in each look agent work can take (`data-working-look`, Debug Settings
// `status.working`). The spinner is the default; Shimmer stays as a Debug option. The breathing dot
// is deleted (Leo 2026-10-21: "we need to GUARANTEE the breathing dot doesn't come back").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";

const busy = () =>
  chat([
    user("Fix the flaky retry test, then run the suite", 4),
    row("compaction", 3, { compaction: { state: "running" } }),
    activity(
      [
        tool("Read src/fetch/retry.ts", "read", "running"),
        tool("Search for withRetry callers", "search", "running"),
        tool("bun test src/fetch", "execute", "running"),
      ],
      1,
    ),
  ]);

export default agentPaneEntry({
  id: "agent-pane.working-look",
  title: "Working look: running rows",
  area: "Agent pane",
  height: 360,
  covers: [
    "agent-session/acpmux/conversation/CompactionNote.tsx",
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
  ],
  keywords: ["spinner", "working", "shimmer", "running"],
  variants: {
    spinner: {
      note: "The default: the turning ring on every running row, all rows in step.",
      snapshot: busy(),
      theme: { workingLook: "spinner" },
    },
    shimmer: {
      note: "Debug only: a still accent dot, and a light band crosses each running row's words.",
      snapshot: busy(),
      theme: { workingLook: "shimmer" },
    },
    static: {
      note: "Reduce Motion or Static status indicators: the ring holds still.",
      snapshot: busy(),
      theme: { workingLook: "spinner", statusIndicators: "static" },
    },
  },
});
