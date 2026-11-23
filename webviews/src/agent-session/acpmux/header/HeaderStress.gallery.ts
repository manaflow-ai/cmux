// l10n-allow-file: gallery fixtures (sample chats, a long failure), not shipped UI.
// Layout stress for the pane's top row (header tools in the tab row, status, PR chip) at narrow widths:
// the controls keep their slots, only the text gives way. View each at 280, 360 and 480 px.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";

const finished = [
  user("Add retries to the fetch helper", 10),
  assistant("Done.", 9),
  summary(9, { status: "completed" }),
];
const LONG_TITLE = "Investigate why the unbroken-identifier-that-never-wraps-in-any-sane-layout-1234567890abcdef fails";

const pullRequest = {
  url: "https://github.com/example/project/pull/123456",
  number: 123456,
  title: "A very long pull request title that never fits a header",
  state: "open",
  review: "changes_requested",
  mergeable: "conflicting",
  checks: { state: "failing", passed: 31, total: 48 },
  checkList: [],
};

const tabRow =
  (state: Record<string, unknown> = {}, inset = 56): Play =>
  async (ctx) => {
    const { setTabRow } = await import("./tabRow");
    const { setHeaderState } = await import("./headerState");
    setTabRow({ height: 28, trailingInset: inset });
    setHeaderState({ pullRequest, ...state });
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header[data-tab-row] .acpmux-handoff-header-tools"));
  };

export default agentPaneEntry({
  id: "agent-pane.header-stress",
  title: "Header stress (narrow, long text, PR chip)",
  area: "Agent pane",
  height: 200,
  widths: { narrow: 280, normal: 360, wide: 480 },
  covers: ["agent-session/acpmux/header/ChatHeaderTools.tsx#ChatHeaderTools"],
  variants: {
    "tab-row-pr": {
      note: "Tab row with a six-digit PR chip, failing checks and a trailing pane inset: tools stay square, the row never wraps.",
      snapshot: chat(finished),
      play: tabRow(),
    },
    "tab-row-long-error": {
      note: "A long failure leads the tools in the tab row: the text truncates, the tools keep their slots.",
      snapshot: chat(finished, {
        connection:
          "error: the agent process exited with status 1 before it answered the initialize request; see the agent log",
      }),
      play: tabRow(),
    },
    "standalone-long-title": {
      note: "No tab row, one unbroken 100-character title: the title ellipsizes, the tools do not move.",
      snapshot: chat(finished, { title: LONG_TITLE }),
    },
    "standalone-long-title-pr": {
      note: "No tab row, long title and the PR chip.",
      snapshot: chat(finished, { title: LONG_TITLE }),
      play: async (ctx) => {
        const { setHeaderState } = await import("./headerState");
        setHeaderState({ pullRequest });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-header-pr"));
      },
    },
  },
});
