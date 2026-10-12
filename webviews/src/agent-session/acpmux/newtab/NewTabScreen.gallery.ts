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
    "agent-session/acpmux/newtab/RowGlyph.tsx#RowGlyph",
    "ui/VirtualList.tsx#VirtualList",
  ],
  variants: withAllChats({
    empty: {
      note: "No chats yet.",
      ready: newTab(),
      snapshot: noChat(),
    },
    "chats-unavailable": {
      note: "The chat index did not answer: All chats says it could not load and offers Try again.",
      ready: newTab(),
      snapshot: noChat(),
      native: {},
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
        // The rows stay inside the list's box after a scroll too (cx-p8ul): every drawn row sits
        // within the scroller, below the field. The scroll is a measured step, so the play reports.
        await ctx.scroll({ selector: ".nt-all-list" }, "bottom");
        if ((ctx.document.querySelector(".nt-all-list")?.scrollTop ?? 0) === 0)
          throw new Error("All chats did not scroll");
        const list = ctx.document.querySelector(".nt-all-list")!.getBoundingClientRect();
        const rows = [...ctx.document.querySelectorAll(".nt-all-item:not(.is-loader)")];
        if (rows.length === 0) throw new Error("All chats drew no rows");
        // A row outside the scroller's box must be clipped: the point at its center shows
        // something else (the field, a card), never a row.
        const outside = rows.filter((row) => {
          const rect = row.getBoundingClientRect();
          const x = rect.left + rect.width / 2;
          const y = rect.top + rect.height / 2;
          const within = y >= list.top && y <= list.bottom && x >= list.left && x <= list.right;
          return !within && !!ctx.document.elementFromPoint(x, y)?.closest(".nt-all-item");
        });
        if (outside.length) throw new Error(`${outside.length} All chats rows draw outside the list`);
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
    "tool-menu-open": {
      note: "A tool's extra actions open from its trailing disclosure without moving the page or clipping the popup.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      checks: {
        popupLayer: { value: true, reason: "The tool menu must be above the New Tab page and fully visible." },
        layoutShiftMax: { value: 0, reason: "Opening a portaled tool menu must not move the page." },
      },
      play: async (ctx) => {
        await ctx.click({ selector: ".nt-tool-menu-button" });
        await ctx.waitFor(() => ctx.document.querySelector('.nt-tool-menu-popover[role="menu"]'));
      },
    },
    "tool-menu-keyboard": {
      note: "Arrow navigation and Escape keep the tool menu's focus contract explicit.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      checks: {
        popupLayer: { value: true, reason: "Keyboard tool menus must remain on top of the page." },
        layoutShiftMax: { value: 0, reason: "Keyboard menu navigation must not move page content." },
      },
      play: async (ctx) => {
        const trigger = { selector: ".nt-tool-menu-button" };
        const items = () => ctx.document.querySelectorAll('.nt-tool-menu-popover [role="menuitem"]');
        const focused = (index: number) => items().length === 2 && ctx.document.activeElement === items()[index];
        await ctx.focus(trigger);
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => focused(0));
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => focused(1));
        await ctx.press("Escape");
        await ctx.waitFor(
          () =>
            ctx.find(trigger).getAttribute("aria-expanded") === "false" &&
            ctx.document.activeElement === ctx.find(trigger),
        );
      },
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
      note: "Text that matches open tabs, workspaces and visited pages: Ask first (Return's), a web search, then those rows (with their favicons, a glyph while one loads) in the popover; Down to the last row scrolls to it (dogfood 2026-10-08).",
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
        // Ask, the search and four matches: six presses from Ask end on the last row.
        for (let step = 0; step < 6; step++) await ctx.press("ArrowDown");
      },
    },
    "typed-reddit": {
      note: 'The omnibar (Leo 2026-10-12): "reddit" completes to reddit.com (a top site), highlighted for Return, then the matching tab and workspace, a web search and Ask, in a popover over the page (no reflow); a blank browser tab is never offered.',
      ready: newTab({
        omnibar: {
          tabs: [
            { id: "tab-blank", kind: "browser", title: "about:blank", detail: "about:blank", workspace: "workspace-3" },
            { id: "tab-1", kind: "browser", title: "Reddit API docs", detail: "reddit.com/dev/api", icon: SITE_ICON },
          ],
          workspaces: [{ id: "workspace-1", name: "reddit-scraper", detail: "~/src/reddit-scraper" }],
          folders: [CWD],
          commands: [],
          history: [{ url: "about:blank" }],
        },
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("reddit", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover"));
      },
    },
    "typed-address": {
      note: "An address: open it first (highlighted), then a web search and Ask.",
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
    projects: {
      note: "All chats' Projects view (cx-ncc.66): the chats grouped under their project folder, the newest project first; a header folds its chats.",
      ready: newTab(),
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Projects" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-all-group"));
      },
    },
    "switcher-off": {
      note: "With Debug Settings newTab.templateSwitcher off (it is on by default, cx-l1jv): no dots.",
      ready: newTab(),
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-screen"));
        if (ctx.document.querySelector(".nt-templates"))
          throw new Error("the template dots show with the switcher off");
      },
    },
    "switcher-on": {
      note: "The template dots, drawn like the space dots: a dot switches the page in place and the chip slides to it (cx-l1jv).",
      ready: newTab({ templateSwitcher: true }),
      snapshot: noChat(manySessions(6)),
      play: async (ctx) => {
        await ctx.click({ selector: '.nt-template-dot[data-template="threads"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.nt-screen[data-template="threads"]'));
      },
    },
    "switcher-keys": {
      note: "The arrow keys switch templates from a focused dot and keep focus there, through Classic; arrowing onto Terminal only focuses it (cx-l1jv).",
      ready: newTab({ templateSwitcher: true }),
      snapshot: noChat(manySessions(6)),
      play: async (ctx) => {
        const onDot = (template: string) =>
          ctx.document.activeElement?.matches(`.nt-template-input[value="${template}"]`);
        await ctx.focus({ role: "radio", name: "Default" });
        for (const template of ["composer", "threads", "console"]) {
          await ctx.press("ArrowRight");
          await ctx.waitFor(() => ctx.document.querySelector(`.nt-screen[data-template="${template}"]`));
          if (!onDot(template)) throw new Error(`switching to ${template} with the keys moved focus off the dots`);
        }
        // Classic is another page, which focuses its field as it mounts: focus stays on the dots.
        await ctx.press("ArrowRight");
        await ctx.waitFor(() => !ctx.document.querySelector(".nt-screen") && onDot("classic"));
        // Terminal would turn the page into a terminal: the keys only focus it.
        await ctx.press("ArrowRight");
        await ctx.waitFor(() => onDot("terminal"));
        if (!ctx.document.querySelector('.nt-template-input[value="classic"]:checked'))
          throw new Error("arrowing onto Terminal switched the page");
      },
    },
  }),
});
