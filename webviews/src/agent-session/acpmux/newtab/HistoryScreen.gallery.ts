// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// Agent history (HistoryScreen.tsx, cx-zlnl): the page the sidebar's History dot opens, when the
// `ready` answer's `newTab` carries `history`. Its list is the New Tab page's All chats list.
import { agentPaneEntry } from "../../../gallery/format";
import { noChat } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";

const TITLES = [
  "Fix the flaky upload test",
  "Port the sidebar to the new layout",
  "Review the docs for the 1.0 launch",
  "Profile cold startup",
  "Trim the agent pane bundle",
];
const PROJECTS = ["/Users/you/src/cmux", "/Users/you/src/cmux-web"];
const page = {
  ready: true,
  design: "age",
  chats: Array.from({ length: 30 }, (_, index) => ({
    key: `claude:history-${index}`,
    harness: index % 3 === 1 ? "codex" : "claude",
    ...(index < TITLES.length ? { title: TITLES[index] } : {}),
    cwd: PROJECTS[index % PROJECTS.length],
    updatedAt: minutesAgo(index * 37),
  })),
};
const history = { newTab: { history: true }, newSession: true };

/// A Cmd-click on the row at `index`, as WebKit delivers it (no focus moves).
const cmdClick = (doc: Document, index: number) =>
  doc
    .querySelectorAll(".nt-all-row")
    [index]?.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true }));

export default agentPaneEntry({
  id: "agent-pane.history",
  title: "Agent history",
  area: "New Tab",
  height: 560,
  covers: ["agent-session/acpmux/newtab/HistoryScreen.tsx#HistoryScreen"],
  variants: {
    chats: {
      note: "Every chat on this Mac, newest first, as the History dot opens it.",
      ready: history,
      snapshot: noChat(),
      native: { "chats.page": page },
    },
    selected: {
      note: "Three rows Cmd-clicked into a selection: Enter or right-click > Bring into active sessions opens them.",
      ready: history,
      snapshot: noChat(),
      native: { "chats.page": page },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-all-row").length > 4);
        for (const index of [1, 2, 4]) cmdClick(ctx.document, index);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-all-row[data-selected]").length === 3);
      },
    },
  },
});
