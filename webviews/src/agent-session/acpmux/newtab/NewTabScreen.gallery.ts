// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// The New Tab page (NewTabScreen.tsx, ChatCards.tsx, variant B): the tab opens as the page when
// the `ready` answer carries `newTab`, as the app's new tab does.
import { agentPaneEntry } from "../../../gallery/format";
import { CWD, manySessions, noChat, session } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";

/// Favicons as the host sends them (cx-d0d.8): small inline PNGs.
const SITE_ICON =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAOElEQVR42mNgoDZQTX79Hx+mSDNeQ4jVjNUQUjVjGIJNEh2QZAAuMJIMoDgQ6ZIWqJ+UqZKZyAEAwqPV6AATmH0AAAAASUVORK5CYII=";
const OTHER_SITE_ICON =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAPklEQVR42mNgoDZ4FcHzHx+mSDNeQ4jVjNUQUjVjGIJN8v/bqyiYJAPQNeMyZDgbQHEg0iUtUD8pUyUzkQMARpy6LDTJkq8AAAAASUVORK5CYII=";

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

// One page of the device chat index as the host answers `chats.page` (AllChatsList): titled
// chats, untitled ones in several projects (named apart by their project), newest first.
const CHAT_TITLES = [
  "cmux-next chief",
  "Browser use and cmux computer use for cmux-next",
  "/loop keep improving things until we are at the theoretical limit for iteration speed",
  "cx-4eho scope watch test",
  "does it work for me? can i try it?",
  "iMessage clone Swift demo for cmux",
  "subscription extra usage: how much per account?",
  "GPUI CEF browser with libghostty tabs",
];
const CHAT_PROJECTS = ["/Users/you/src/cmux", "/Users/you/src/cmux-web", "/Users/you/.acpmux/tags/dev/unattended"];
const allChatsPage = {
  ready: true,
  design: "age",
  chats: Array.from({ length: 40 }, (_, index) => ({
    key: `claude:chat-${index}`,
    harness: index % 3 === 1 ? "codex" : "claude",
    ...(index < CHAT_TITLES.length ? { title: CHAT_TITLES[index] } : {}),
    cwd: CHAT_PROJECTS[index % CHAT_PROJECTS.length],
    updatedAt: minutesAgo(index < 3 ? 0 : index * 2),
  })),
};
const withAllChats = <V extends object>(variants: Record<string, V>) =>
  Object.fromEntries(
    Object.entries(variants).map(([name, variant]) => [name, { native: { "chats.page": allChatsPage }, ...variant }]),
  ) as Record<string, V>;

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
    "agent-session/acpmux/newtab/TemplateDots.tsx#TemplateDots",
    "agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList",
    "agent-session/acpmux/newtab/OpenTabsList.tsx#OpenTabsList",
    "agent-session/acpmux/newtab/ClosedList.tsx#ClosedList",
    "ui/VirtualList.tsx#VirtualList",
  ],
  variants: withAllChats({
    empty: {
      note: "No chats yet.",
      ready: newTab(),
      snapshot: noChat(),
    },
    "many-chats": {
      note: "The running chat and the one waiting on the user as cards; every chat in All chats below, named apart by project. The list's rows stay inside the list (dogfood 2026-10-10: they drew from the page top over the field).",
      ready: newTab(),
      snapshot: noChat(manySessions(14)),
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const list = ctx.document.querySelector(".nt-all-scroll")?.getBoundingClientRect();
          const box = ctx.document.querySelector(".nt-box")?.getBoundingClientRect();
          const row = ctx.document.querySelector(".nt-all-item:not(.is-loader)")?.getBoundingClientRect();
          return !!list && !!box && !!row && row.top >= list.top - 1 && row.top >= box.bottom;
        });
      },
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
    "split-open-tabs": {
      note: "Opened by Split Right from a browser tab (cx-jfo7): the workspace's tabs, each one moved into this pane by a click.",
      ready: newTab({
        openTabs: [
          { id: "t1", kind: "terminal", title: "zsh", detail: "~/src/cmux" },
          { id: "t2", kind: "browser", title: "PR #17516", detail: "github.com/manaflow-ai/cmux", icon: SITE_ICON },
          { id: "t3", kind: "agent", title: "cmux-next chief" },
        ],
      }),
      snapshot: noChat(manySessions(3)),
    },
    "recently-closed": {
      note: "Recently Closed (cx-d0d.60): the newest closed tabs, screens and workspaces, each reopened by a click; one on a machine that is not connected is dimmed.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      play: async (ctx) => {
        ctx.document.defaultView?.cmuxAcpmuxBridge?.applyRecentlyClosed?.([
          {
            id: "closed:1",
            kind: "browser",
            title: "PR #17516",
            detail: "https://github.com/manaflow-ai/cmux/pull/17516",
            closedAt: minutesAgo(1),
            icon: SITE_ICON,
            available: true,
          },
          {
            id: "closed:2",
            kind: "terminal",
            title: "zsh",
            detail: "~/src/cmux",
            closedAt: minutesAgo(4),
            available: true,
          },
          {
            id: "closed:3",
            kind: "browser",
            title: "Docs",
            detail: "https://developer.apple.com/documentation",
            closedAt: minutesAgo(9),
            icon: OTHER_SITE_ICON,
            available: true,
          },
          {
            id: "closed:4",
            kind: "workspace",
            title: "cmux-web",
            detail: "~/src/cmux-web",
            closedAt: minutesAgo(30),
            available: true,
          },
          {
            id: "closed:5",
            kind: "terminal",
            title: "build",
            detail: "~/src/relay",
            closedAt: minutesAgo(60),
            available: false,
          },
        ]);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-closed .nt-open-tab").length === 5);
      },
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
      note: "Text that matches open tabs and visited pages: those rows (with their favicons, a glyph while one loads) and a web search; Ctrl-N to the last row scrolls to it (dogfood 2026-10-08).",
      ready: newTab({
        omnibar: {
          tabs: [
            { id: "tab-1", kind: "browser", title: "Release notes", detail: "cmux.dev", icon: SITE_ICON },
            { id: "tab-2", kind: "terminal", title: "release build", detail: "~/src/release" },
          ],
          workspaces: [{ id: "workspace-1", name: "Release", detail: "~/src/release" }],
          folders: [CWD],
          commands: [],
          // A visited page with its site's icon, and one whose icon is still loading (the glyph).
          history: [
            { url: "https://cmux.dev/release", title: "cmux release notes", icon: OTHER_SITE_ICON },
            { url: "https://example.com/release", title: "example release" },
          ],
        },
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("release", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-rows"));
        // Two tabs, the two pages and the search: five presses end on the last row.
        for (let step = 0; step < 5; step++) await ctx.press("ArrowDown");
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
    "template-composer": {
      note: "Composer template (tabs.newTabTemplate): one large prompt, no cards or Tools.",
      ready: newTab({ template: "composer" }),
      snapshot: noChat(manySessions(4)),
    },
    "template-threads": {
      note: "Threads template: the field and the recent chats as a list.",
      ready: newTab({ template: "threads" }),
      snapshot: noChat(manySessions(6)),
    },
    "template-console": {
      note: "Console template: a monospace field with a > prompt, chats as lines.",
      ready: newTab({ template: "console" }),
      snapshot: noChat(manySessions(6)),
    },
    "template-classic": {
      note: "Classic template: the Terminal | Browser | Agent page, with the template dots.",
      ready: newTab({ template: "classic", templateSwitcher: true }),
      snapshot: noChat(manySessions(4)),
    },
    "switcher-off": {
      note: "The template switcher is off by default until it is styled (cx-7qqu): no dots.",
      ready: newTab(),
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-screen"));
        if (ctx.document.querySelector(".nt-templates"))
          throw new Error("the template dots show with the switcher off");
      },
    },
    "switcher-on": {
      note: "With Debug Settings newTab.templateSwitcher on, a dot switches the page in place (cx-7qqu).",
      ready: newTab({ templateSwitcher: true }),
      snapshot: noChat(manySessions(6)),
      play: async (ctx) => {
        await ctx.click({ selector: '.nt-template-dot[data-template="threads"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.nt-screen[data-template="threads"]'));
      },
    },
  }),
});
