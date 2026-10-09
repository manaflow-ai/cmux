// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// The New Tab page (NewTabScreen.tsx, ChatCards.tsx, variant B): the tab opens as the page when
// the `ready` answer carries `newTab`, as the app's new tab does.
import { agentPaneEntry } from "../../../gallery/format";
import { CWD, manySessions, noChat, session } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";

const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    tools: [
      { id: "openDiffViewer", title: "Changes", symbol: "plusminus", shortcut: "⌃⇧⌘G", menu: [] },
      { id: "newSurface", title: "Terminal", symbol: "terminal", shortcut: "⌘T", menu: ["splitRight", "splitDown"] },
      { id: "file.open", title: "Files", symbol: "folder", shortcut: "⇧⌘O", menu: [] },
      {
        id: "agentPane.searchChats",
        title: "Side chat",
        symbol: "bubble.left.and.text.bubble.right",
        shortcut: "⌘K",
        menu: [],
      },
    ],
    ...fields,
  },
  newSession: true,
});

export default agentPaneEntry({
  id: "agent-pane.new-tab",
  title: "New Tab page",
  area: "New Tab",
  height: 560,
  checks: {
    layoutShiftMax: {
      value: 0.4,
      reason:
        "Typing an address or an open tab's name shows the rows between the field and the chat cards, which move down.",
    },
  },
  covers: [
    "agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen",
    "agent-session/acpmux/newtab/ChatCards.tsx",
    "agent-session/acpmux/NewTabPage.tsx#AgentMark",
    "agent-session/acpmux/NewTabPage.tsx#FolderIcon",
  ],
  variants: {
    empty: {
      note: "No chats yet.",
      ready: newTab(),
      snapshot: noChat(),
    },
    "many-chats": {
      note: "Recent chats as cards, the newest first.",
      ready: newTab(),
      snapshot: noChat(manySessions(14)),
    },
    "long-title": {
      note: "A chat title far longer than its card.",
      ready: newTab(),
      snapshot: noChat([
        session({
          sessionId: "long",
          title:
            "Investigate why the transcript virtualizer drops rows when a streaming reply grows past the viewport while the user scrolls up through older history on a slow machine",
          updatedAt: minutesAgo(2),
        }),
        ...manySessions(2),
      ]),
    },
    "from-location": {
      note: "Opened from a web tab: the field holds its address.",
      ready: newTab({ location: "https://github.com/manaflow-ai/cmux/pull/17516" }),
      snapshot: noChat(manySessions(4)),
    },
    "without-tools": {
      note: "The reserved Tools region is omitted when no host action can run.",
      ready: newTab({ tools: [] }),
      snapshot: noChat(manySessions(3)),
    },
    "with-tools": {
      note: "Tools use the host action catalog and shortcut labels.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
    },
    "typed-prompt": {
      note: "A typed prompt: no rows (Enter asks the agent picked on top, cx-e2aa); the cards stay.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("fix the flaky upload test", { selector: ".nt-field" });
      },
    },
    "typed-tab-match": {
      note: "Text that matches open tabs and a visited page: those rows and a web search; Ctrl-N to the last row scrolls to it (dogfood 2026-10-08).",
      ready: newTab({
        omnibar: {
          tabs: [
            { id: "tab-1", kind: "browser", title: "Release notes", detail: "cmux.dev" },
            { id: "tab-2", kind: "terminal", title: "release build", detail: "~/src/release" },
          ],
          workspaces: [{ id: "workspace-1", name: "Release", detail: "~/src/release" }],
          folders: [CWD],
          commands: [],
          history: [{ url: "https://cmux.dev/release", title: "cmux release notes" }],
        },
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("release", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-rows"));
        // Two tabs, the page and the search: four presses end on the last row.
        for (let step = 0; step < 4; step++) await ctx.press("ArrowDown");
      },
    },
    "typed-address": {
      note: "An address: open it first, then a web search.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("localhost:3000", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-rows"));
      },
    },
    "omnibar-row-kinds": {
      note: "Opened from text: the field holds it, selected, with no rows until it is edited.",
      ready: newTab({
        location: "release notes",
        omnibar: {
          tabs: [{ id: "tab-1", kind: "browser", title: "Release notes", detail: "cmux.dev" }],
          workspaces: [{ id: "workspace-1", name: "Docs", detail: "~/src/docs" }],
          folders: [CWD],
          commands: ["bun test"],
          history: [{ url: "https://cmux.dev/docs", title: "cmux docs" }],
        },
      }),
      snapshot: noChat(manySessions(3)),
    },
  },
});
