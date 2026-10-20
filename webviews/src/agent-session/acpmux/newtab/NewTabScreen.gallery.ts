// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// The New Tab page (NewTabScreen.tsx, ChatCards.tsx, variant B): the tab opens as the page when
// the `ready` answer carries `newTab`, as the app's new tab does.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CATALOG, CWD, manySessions, noChat, session } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { composerStatePlays } from "../composerStatePlays";

/// Favicons as the host sends them (cx-d0d.8): small inline PNGs.
const SITE_ICON =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAOElEQVR42mNgoDZQTX79Hx+mSDNeQ4jVjNUQUjVjGIJNEh2QZAAuMJIMoDgQ6ZIWqJ+UqZKZyAEAwqPV6AATmH0AAAAASUVORK5CYII=";
const OTHER_SITE_ICON =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAPklEQVR42mNgoDZ4FcHzHx+mSDNeQ4jVjNUQUjVjGIJN8v/bqyiYJAPQNeMyZDgbQHEg0iUtUD8pUyUzkQMARpy6LDTJkq8AAAAASUVORK5CYII=";

/// No chat yet, Claude Code starting on Medium: the model and reasoning chips both show.
const reasoningChat = () =>
  noChat([], {
    catalog: CATALOG.map((entry) =>
      entry.id === "claude" ? { ...entry, start: { model: "claude-opus-5-5", effort: "medium" } } : entry,
    ),
  });

/// Album art as the host sends it: a small inline PNG (a gradient).
const ALBUM_ART =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAACU0lEQVR42tXPCTcTAAAH8P8nkZJyC8uSRUNzX8uRNS0amvvMckSOJkcTOXJHJCJHkyOyHJEjckS8Xr16vXr1en2E9jX+3+D3g5labZ6ttrxx0yorxyYr1zYz1y4jzyEjX5B+yzGtQJha4JRa6JxyW5Rc5JJc7JpULE4scUso9Ui4I4nXeKo03qoyn+t3/eLKA2IrAmMrgmMqpcqqEOW9sGva8GhtRFS1LOq+/GpNpKJGoaiNuvIgOrJOKa+PkdfHXW5QyRrjZQ8TI5qSLjWlhDenhbekh7VmhrZlhbZlh7SrL3bkSB/lSTvzgzsLgroKgx4XBXaXBPSU+vdo/J+U+fWW+z6t9O0Dtb7Kpw/Ueq13P6j11V7PQK2v8RoAtb7WcwDU+jrJIKj1DZLnoNY3XhgCtb7JYxjU+mb3YVDrW91HQK1vdxsFtb5D/ALU+k6xDtT6rvM6UOu7XcdAre9xeQlqfa/LOKj1fecmQK3vF02AWj8gmgS1ftB5CtT6obOvQK0fcZoGtX7UEKDW687MgFo/JnwNav24cBbU+klHPaj1U6f1oNZPC96AWj8jmAO1ftZhHtR6vf08qPVz9gug1i/YLYJav3jqLaj1S7ZLoNYvGwLU+hWbZVDr16zfgVq/br0Cav2G1Sqo9ZuWq6DWb1msgVq/Y7EOav2u+XtQ6/fMNkCt3zcEqPUHJzdBrT888QHU+s+mW6DWfzHdBrX+6/FtUOu/meyAWv/dZBfU+h/HPoJa//PoHqj1v4z3QK3/bbwPav2fI59Arf9rdABq/T+jw/8n7vrBWnViYgAAAABJRU5ErkJggg==";

const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
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

/// The widget view's fixtures: projects as the host sends them, and chats where three need the user.
const WIDGET_PROJECTS = ["/Users/you/src/cmux", "/Users/you/src/cmux-web", "/Users/you/src/manaflow"];
const widgetSessions = () => [
  session({
    sessionId: "widget-failed",
    title: "Composer + picker polish: no Tonka toys",
    indicator: "failed",
    preview: "Hit an error while running the gallery checks.",
    cwd: "/Users/you/src/cmux",
    updatedAt: minutesAgo(2),
  }),
  session({
    sessionId: "widget-input",
    title: "Ship the release notes for 0.64",
    status: "waiting",
    pendingPermissions: 1,
    indicator: "input",
    cwd: "/Users/you/src/cmux-web",
    updatedAt: minutesAgo(12),
  }),
  session({
    sessionId: "widget-lost",
    title: "Index the docs site",
    indicator: "lost",
    cwd: "/Users/you/src/manaflow",
    updatedAt: minutesAgo(40),
  }),
  ...manySessions(6).map((entry) => ({
    ...entry,
    indicator: "done" as const,
    status: "idle" as const,
    pendingPermissions: 0,
  })),
];

type GalleryNativeCall = { method: string; params?: Record<string, unknown> };

function galleryNativeCalls(document: Document): GalleryNativeCall[] {
  return (
    (
      document.defaultView as unknown as {
        cmuxGalleryLog?: GalleryNativeCall[];
      }
    ).cmuxGalleryLog ?? []
  );
}

async function waitForTabJump(
  ctx: PlayContext,
  target: "tab" | "here" | "closed" | "workspace",
  id: string,
): Promise<void> {
  await ctx.waitFor(() =>
    galleryNativeCalls(ctx.document).some(
      (call) => call.method === "tab.jump" && call.params?.target === target && call.params?.id === id,
    ),
  );
}

export default agentPaneEntry({
  id: "agent-pane.new-tab",
  title: "New Tab page",
  area: "New Tab",
  height: 560,
  checks: {
    layoutShiftMax: {
      value: 0.4,
      reason:
        "Typing an address or an open tab's name shows the rows between the field and the recent chats, which move down.",
    },
    settleMaxMs: {
      value: 250,
      reason: "New Tab navigation, menu selection, and local suggestion updates should settle within a quarter second.",
    },
  },
  covers: [
    "agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen",
    "agent-session/acpmux/newtab/ChatCards.tsx",
    "agent-session/acpmux/newtab/NowPlayingPlayer.tsx#NowPlayingPlayer",
    "agent-session/acpmux/newtab/NowPlayingPlayer.tsx#NowPlayingCard",
    "agent-session/acpmux/NewTabPage.tsx#AgentMark",
    "agent-session/acpmux/NewTabPage.tsx#FolderIcon",
    "agent-session/acpmux/newtab/AllChatsList.tsx#AllChatsList",
    "agent-session/acpmux/newtab/ChatFilterMenu.tsx#ChatFilterMenu",
    "agent-session/acpmux/newtab/OpenTabsList.tsx#OpenTabsList",
    "agent-session/acpmux/newtab/ClosedList.tsx#ClosedList",
    "agent-session/acpmux/newtab/RowGlyph.tsx#RowGlyph",
    "agent-session/acpmux/newtab/StyleSwitch.tsx#StyleSwitch",
    "agent-session/acpmux/newtab/WidgetCards.tsx#WidgetCards",
    "agent-session/acpmux/DictationMic.tsx#DictationMic",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "ui/HideableChrome.tsx#HideableChrome",
    "ui/HideableChrome.tsx#ChromeArea",
    "ui/VirtualList.tsx#VirtualList",
  ],
  variants: withAllChats({
    empty: {
      note: "No chats yet. A harness is installed, so the chip names its model and nothing on the page offers Add harness.",
      ready: newTab(),
      snapshot: noChat(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        if (ctx.document.querySelector(".nt-no-agent, .acpmux-add-harness"))
          throw new Error("Add harness shows on the page with a harness installed");
      },
    },
    // The chip's model picker opens whole: the card does not clip it to its search field
    // (Lawrence 2026-10-13). Points near its top and bottom edges hit the picker, not the page.
    "model-picker-open": {
      note: "The New Tab chip's model picker, open: at least its search field and about six rows, never cut by the card. Its list ends on Add harness….",
      ready: newTab(),
      snapshot: noChat(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.click({ role: "button", name: "Model" });
        await ctx.waitFor(() => {
          const menu = ctx.document.querySelector<HTMLElement>(".acpmux-mp");
          if (!menu || menu.style.visibility !== "visible") return false;
          const box = menu.getBoundingClientRect();
          if (box.height < 219) return false;
          const x = box.left + box.width / 2;
          return [box.top + 6, box.bottom - 6].every((y) => menu.contains(ctx.document.elementFromPoint(x, y)));
        });
        const options = ctx.document.querySelectorAll(".acpmux-mp-models [role=option]");
        if (!options[options.length - 1]?.classList.contains("acpmux-mp-add-harness"))
          throw new Error("the model picker's list does not end on Add harness…");
      },
    },
    // Reasoning is its own chip beside the model chip, with its own menu (P0 #8): acpmux starts
    // Claude Code on Medium, so the chip names it before any chat exists.
    "reasoning-chip": {
      note: "Before any chat: the Reasoning chip names the level acpmux starts Claude Code on (Medium) and opens the reasoning menu on its own, apart from the model chip.",
      ready: newTab(),
      snapshot: reasoningChat(),
    },
    // The New Tab composer's states, as the chat composer's (agent-pane.composer composer-*): the
    // same chips, pills, caret and rim (test/composer-caret-focus.test.ts).
    ...Object.fromEntries(
      Object.entries(composerStatePlays(".nt-field")).map(([state, variant]) => [
        `composer-${state}`,
        { ...variant, ready: newTab(), snapshot: reasoningChat() },
      ]),
    ),
    "chats-unavailable": {
      note: "The chat index did not answer: All chats says it could not load and offers Try again.",
      ready: newTab(),
      snapshot: noChat(),
      native: {},
    },
    "calm-default": {
      note: "The default page is calm (Leo 2026-10-11): the composer with its arrow-up Send, then the five newest chats as quiet rows and All Chats for the rest. No tools row, no Recently Closed, no All chats table.",
      ready: newTab(),
      snapshot: noChat(manySessions(14)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-cards[data-variant=list] .nt-card").length === 5);
        // Quiet rows, one line each (the fleet capture drew them 86px tall).
        const tall = [...ctx.document.querySelectorAll(".nt-cards[data-variant=list] .nt-card")].filter(
          (row) => row.getBoundingClientRect().height > 32,
        );
        if (tall.length) throw new Error(`${tall.length} recent chat rows are taller than one line`);
      },
    },
    "current-composer": {
      note: "Current composer visual reference: the latest New Tab surface with folder/computer, model, effort, dictation, Send, create actions, and quiet chat rows. This variant is visual-only; workspace switching is covered by the separate behavior journey.",
      ready: newTab(),
      snapshot: noChat(manySessions(14)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-cards[data-variant=list] .nt-card").length === 5);
        if ([...ctx.document.querySelectorAll(".nt-row")].some((row) => row.textContent?.includes("Release")))
          throw new Error("the visual-only composer fixture unexpectedly contains the Release journey");
      },
    },
    // The widget view (Debug Settings `newTab.widgets`, Leo 2026-10-18): soft cards under the create
    // actions, from the page's own data. Projects: this Mac, then its recent projects, the one a chat
    // starts in checked. Needs you: the chats asking for input or that hit an error, each with ×.
    widgets: {
      note: "Widget view on (Debug Settings newTab.widgets): a Projects card with this Mac and its recent projects, the picked one checked; a Needs you card with the chats waiting on you or that hit an error, each dismissable. Then the calm chat rows.",
      ready: newTab({ widgets: true, projects: WIDGET_PROJECTS }),
      snapshot: noChat(widgetSessions()),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-widget-chat").length === 3);
        await ctx.click({ text: "cmux" });
        await ctx.waitFor(() => ctx.document.querySelector('.nt-widget-row[aria-pressed="true"]') !== null);
      },
    },
    "widgets-off": {
      note: "The same chats and projects with the widget view off (the default): no cards, only the calm chat rows.",
      ready: newTab({ projects: WIDGET_PROJECTS }),
      snapshot: noChat(widgetSessions()),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-cards[data-variant=list] .nt-card").length > 0);
        if (ctx.document.querySelector(".nt-widgets")) throw new Error("widget cards show with the widget view off");
      },
    },
    "widgets-hover": {
      note: "Widget view, a pointer over a Needs you chat: a hover card with its whole title and why it needs you (its last line).",
      ready: newTab({ widgets: true, projects: WIDGET_PROJECTS }),
      snapshot: noChat(widgetSessions()),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-widget-chat").length === 3);
        await ctx.hover({ selector: ".nt-widget-chat[data-state=failed] .nt-widget-chat-open" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-widget-tip") !== null);
      },
    },
    "no-harness-installed": {
      note: "No harness installed (Leo 2026-10-14): the composer's chip says Add harness and opens the Harnesses page. No line under the field, no grey placeholder pills.",
      // The mock daemon answers with no harness, as acpmux does on a Mac without an agent CLI.
      ready: { ...newTab(), transport: "mock" },
      mockHarnesses: [],
      snapshot: { ...noChat(), catalog: [] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-pickers .acpmux-add-harness") !== null);
        if (ctx.document.querySelector(".nt-no-agent")) throw new Error("a No agent to ask line shows under the field");
        const chip = ctx.document.querySelector(".nt-pickers .acpmux-add-harness")!.getBoundingClientRect();
        if (chip.height > 32) throw new Error(`the Add harness chip is ${chip.height}px tall, not one chip`);
      },
    },
    "typed-over-note": {
      note: "hq#1925 12: suggestions open over the New terminal / browser / chat row and cover it; no text under the popover shows through.",
      ready: { ...newTab(), transport: "mock" },
      mockHarnesses: [],
      snapshot: { ...noChat(), catalog: [] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-create") !== null);
        await ctx.type("fix the flaky upload test", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover .nt-row") !== null);
        const popover = ctx.document.querySelector<HTMLElement>(".nt-popover")!;
        const style = ctx.document.defaultView!.getComputedStyle(popover);
        const alpha = /\/\s*([\d.]+%?)\s*\)$|rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)/.exec(style.backgroundColor);
        const fill = alpha ? (alpha[1] ?? alpha[2])! : "1";
        const opaque = fill.endsWith("%") ? parseFloat(fill) >= 100 : parseFloat(fill) >= 1;
        if (!opaque || parseFloat(style.opacity) < 1)
          throw new Error(
            `the suggestions show the page through them (${style.backgroundColor}, opacity ${style.opacity})`,
          );
        const cover = popover.getBoundingClientRect();
        const under = [...ctx.document.querySelectorAll<HTMLElement>(".nt-create > *")].filter((item) => {
          const rect = item.getBoundingClientRect();
          return (
            rect.width > 0 && rect.top < cover.bottom - 2 && rect.bottom > cover.top && rect.left < cover.right - 8
          );
        });
        if (!under.length) throw new Error("the suggestions do not reach the create row under the field");
        for (const item of under) {
          const rect = item.getBoundingClientRect();
          const y = Math.min((rect.top + rect.bottom) / 2, cover.bottom - 2);
          const hit = ctx.document.elementFromPoint(Math.max(rect.left, cover.left) + Math.min(8, rect.width / 2), y);
          if (!hit?.closest(".nt-popover")) throw new Error(`"${item.textContent?.trim()}" draws over the suggestions`);
        }
      },
    },
    "harnesses-from-menu": {
      note: "Play: Integrate a Harness… from the palette or the File menu on this page (cx-9fqw) shows the Harnesses page here, in place, not in a second tab.",
      ready: newTab(),
      snapshot: noChat(),
      play: async (ctx) => {
        const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { command?(name: string): void } };
        await ctx.waitFor(() => page.cmuxAcpmuxBridge?.command !== undefined);
        page.cmuxAcpmuxBridge?.command?.("showHarnesses");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-harnesses") !== null);
      },
    },
    "chats-filter-open": {
      note: "Threads template with the All chats Filter open (cx-htpk0): All, Working, Needs input, Done, in the pane's own menu style, over the list.",
      ready: newTab({ template: "threads" }),
      snapshot: noChat(manySessions(14)),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Filter" });
        await ctx.waitFor(
          () => ctx.document.querySelectorAll('.nt-chats-filter-list [role="menuitemradio"]').length === 4,
        );
      },
    },
    "many-chats": {
      note: "Threads template: every chat in All chats below the field, named apart by project. The list's rows stay inside the list (dogfood 2026-10-10: they drew from the page top over the field).",
      ready: newTab({ template: "threads" }),
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
    "split-open-tabs": {
      note: "Opened by Split Right from a browser tab (cx-jfo7): clicking a workspace tab moves it into this pane.",
      ready: newTab({
        openTabs: [
          { id: "t1", kind: "terminal", title: "zsh", detail: "~/src/cmux" },
          { id: "t2", kind: "browser", title: "PR #17516", detail: "github.com/manaflow-ai/cmux", icon: SITE_ICON },
          { id: "t3", kind: "agent", title: "cmux-next chief" },
        ],
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: /PR #17516/ });
        await waitForTabJump(ctx, "here", "t2");
      },
    },
    "split-open-tabs-context-menu": {
      note: "The same split-open tabs can be moved with the row context menu's Move Here action.",
      ready: newTab({
        openTabs: [
          { id: "t1", kind: "terminal", title: "zsh", detail: "~/src/cmux" },
          { id: "t2", kind: "browser", title: "PR #17516", detail: "github.com/manaflow-ai/cmux", icon: SITE_ICON },
          { id: "t3", kind: "agent", title: "cmux-next chief" },
        ],
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.contextMenu({ role: "button", name: /PR #17516/ });
        await ctx.click({ role: "menuitem", name: "Move Here" });
        await waitForTabJump(ctx, "here", "t2");
      },
    },
    "recently-closed": {
      note: "Threads template, Recently Closed (cx-d0d.60): the newest closed tabs, screens and workspaces, each reopened by a click; one on a machine that is not connected is dimmed.",
      ready: newTab({ template: "threads" }),
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
        await ctx.click({ role: "button", name: /PR #17516/ });
        await waitForTabJump(ctx, "closed", "closed:1");
        await ctx.contextMenu({ role: "button", name: /zsh/ });
        await ctx.click({ role: "menuitem", name: "Reopen" });
        await waitForTabJump(ctx, "closed", "closed:2");
        const unavailable = ctx.find({ selector: ".nt-closed .nt-open-tab[disabled]" });
        if (!(unavailable as HTMLButtonElement).disabled) throw new Error("unavailable closed row is not disabled");
      },
    },
    "now-playing": {
      note: "Now Playing: what plays on this Mac (Spotify here), large under the create actions, with its artwork, level bars and Play or Pause; the controls ask the host, and a pause stills the bars.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        const track = (playing: boolean) => ({
          title: "Weightless",
          artist: "Marconi Union",
          artwork: ALBUM_ART,
          playing,
          position: 132,
          duration: 480,
          rate: 1,
          positionDate: Date.now(),
          canPrevious: true,
          canNext: true,
          labels: { play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track" },
        });
        const bridge = ctx.document.defaultView?.cmuxAcpmuxBridge;
        bridge?.applyNowPlaying?.(track(true));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=true]") !== null);
        await ctx.click({ role: "button", name: "Pause" });
        await ctx.waitFor(() =>
          galleryNativeCalls(ctx.document).some(
            (call) => call.method === "nowPlaying.command" && call.params?.command === "playPause",
          ),
        );
        bridge?.applyNowPlaying?.(track(false));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=false]") !== null);
        bridge?.applyNowPlaying?.(track(true));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=true]") !== null);
      },
    },
    "typed-prompt": {
      note: "A typed prompt: Ask first (Return's, highlighted), a web search, then New terminal, New browser tab and New chat in the popover over the cards; the cards stay where they were.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("fix the flaky upload test", { selector: ".nt-field" });
      },
    },
    "typed-search-mode": {
      note: "Leo 2026-10-18 (reverses R86): Tab flips the glass Search | Ask switch at the field's right; in Search the web search leads and Return takes it.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("fix the flaky upload test", { selector: ".nt-field" });
        await ctx.press("Tab");
        // What React renders, not the data-mode the switch writes first: the rows in Search order.
        await ctx.waitFor(
          () =>
            ctx.document.querySelector('.nt-mode button[data-mode="search"][aria-pressed="true"]') &&
            ctx.document.querySelector('#nt-row-0[data-type="search"]'),
        );
      },
    },
    "typed-ask-mode": {
      note: "Ask, the mode a tab opens in: the switch's thumb on Ask, and Ask Claude Code first (Return's) over the web search.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("fix the flaky upload test", { selector: ".nt-field" });
        await ctx.waitFor(
          () =>
            ctx.document.querySelector('.nt-mode button[data-mode="ask"][aria-pressed="true"]') &&
            ctx.document.querySelector('#nt-row-0[data-type="ask"]'),
        );
      },
    },
    "empty-search-mode": {
      note: 'Search mode on an empty field: Tab moved the thumb to Search and the placeholder reads "Search the web or type a URL".',
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.focus({ selector: ".nt-field" });
        await ctx.press("Tab");
        await ctx.waitFor(() => ctx.document.querySelector('.nt-field[placeholder="Search the web or type a URL"]'));
      },
    },
    "typed-url-search-mode": {
      note: "An address in Search mode: it still opens first (highlighted), ahead of the web search, as in Ask.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("localhost:3000", { selector: ".nt-field" });
        await ctx.press("Tab");
        await ctx.waitFor(
          () =>
            ctx.document.querySelector('.nt-mode button[data-mode="search"][aria-pressed="true"]') &&
            ctx.document.querySelector('#nt-row-0[data-type="open"]'),
        );
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
        // Ask, the search, two tabs, the workspace, a page and the three create actions: eight
        // presses from Ask end on the last row, and three more wrap round to the first tab.
        for (let step = 0; step < 8; step++) await ctx.press("ArrowDown");
        for (let step = 0; step < 3; step++) await ctx.press("ArrowDown");
        await ctx.press("Enter");
        await waitForTabJump(ctx, "tab", "tab-1");
      },
    },
    "workspace-switch-animation-audit": {
      note: "Workspace switch review: type Release, choose the workspace suggestion, and wait for the native jump receipt. The play runner records settle time, layout shift, and long frames for this transition.",
      ready: newTab({
        omnibar: {
          tabs: [{ id: "tab-release", kind: "browser", title: "Release notes", detail: "cmux.dev" }],
          workspaces: [{ id: "workspace-release", name: "Release", detail: "~/src/release" }],
          folders: [CWD],
          commands: [],
          history: [],
        },
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("Release", { selector: ".nt-field" });
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll<HTMLElement>('[role="option"]')].some(
            (row) => row.dataset.type === "workspace" && row.textContent?.includes("Release"),
          ),
        );
        await ctx.click({ role: "option", name: /^Release\s+~\/src\/release/ });
        await waitForTabJump(ctx, "workspace", "workspace-release");
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
      checks: {
        popupLayer: { value: true, reason: "The omnibar's popover floats above the page sections." },
        // The page never moves (typed-prompt holds it at 0); here the popover's own rows move as
        // "red" brings reddit.com in on top, as any omnibar's list does while you type.
        layoutShiftMax: { value: 0.02, reason: "Only the popover's rows reorder while typing; the page stays put." },
      },
      play: async (ctx) => {
        await ctx.type("reddit", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover"));
      },
    },
    "typed-red-duplicates": {
      note: 'Leo 10-13 (photo): "red" with Reddit open on a `?solution=…` challenge address and visited twice. One Reddit row, the open tab (Switch to tab) with a clean title and a short host; then the other open tab, the visited page, the web search and Ask, on a solid surface over the page.',
      ready: newTab({
        omnibar: {
          tabs: [
            {
              id: "tab-reddit",
              kind: "browser",
              title: "Reddit - The heart of the internet",
              detail: `reddit.com/?solution=${"eb7139b868b8d71e".repeat(2)}&js_challenge=1`,
              workspace: "workspace-1",
              icon: SITE_ICON,
            },
            { id: "tab-redis", kind: "browser", title: "Redis docs", detail: "redis.io/docs", workspace: "notes" },
          ],
          workspaces: [],
          folders: [CWD],
          commands: [],
          history: [
            {
              url: `https://www.reddit.com/?solution=${"eb7139b868b8d71e".repeat(2)}&js_challenge=1`,
              title: "Reddit - The heart of the internet",
              icon: SITE_ICON,
            },
            { url: "https://www.reddit.com/", title: "Reddit", icon: SITE_ICON },
            { url: "https://www.redblobgames.com/", title: "Red Blob Games", icon: OTHER_SITE_ICON },
          ],
        },
      }),
      snapshot: noChat(manySessions(3)),
      checks: {
        popupLayer: { value: true, reason: "The suggestions float above the page sections." },
        layoutShiftMax: { value: 0.02, reason: "Only the popover's rows reorder while typing; the page stays put." },
      },
      play: async (ctx) => {
        await ctx.type("red", { selector: ".nt-field" });
        await ctx.waitFor(() => {
          const titles = [...ctx.document.querySelectorAll(".nt-row-title")].map((node) => node.textContent);
          const first = ctx.document.querySelector('.nt-row[data-type="tab"] .nt-row-title');
          return titles.filter((title) => title?.startsWith("Reddit")).length === 1 && first?.textContent === "Reddit";
        });
      },
    },
    "typed-dismissed": {
      note: "Leo 10-13: a press outside the composer closes the suggestions; the typed text stays.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("reddit", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover"));
        await ctx.click({ selector: ".nt-screen" });
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".nt-popover") &&
            ctx.document.querySelector<HTMLInputElement>(".nt-field")?.value === "reddit",
        );
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
    "dictation-mic": {
      note: "The agent composer's mic, beside send (cx-32bdm): the same dictation, its words land in this field.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-pickers .acpmux-mic-menu:has(.acpmux-mic) + .nt-send"));
      },
    },
    "dictation-menu": {
      note: "Right-click on the mic offers Hide Dictation Button, which hides it in every composer until a right-click on the button row offers Show Dictation Button (cx-32bdm, cx-wab7m).",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      checks: {
        popupLayer: { value: true, reason: "The mic's menu must be above the New Tab page and fully visible." },
        layoutShiftMax: { value: 0, reason: "Opening the mic's menu must not move the page." },
      },
      play: async (ctx) => {
        const mic = ctx.find({ selector: ".nt-pickers .acpmux-mic" });
        const box = mic.getBoundingClientRect();
        mic.dispatchEvent(
          new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left, clientY: box.bottom }),
        );
        await ctx.waitFor(
          () => ctx.document.querySelector('[role="menuitem"]')?.textContent === "Hide Dictation Button",
        );
      },
    },
    "dictation-show": {
      note: "Hidden from its own right-click, the mic comes back from the same row: a right-click there offers Show Dictation Button (cx-wab7m).",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      checks: {
        popupLayer: { value: true, reason: "The row's menu must be above the New Tab page and fully visible." },
        layoutShiftMax: { value: 0.1, reason: "Hiding the mic only closes its 24px gap beside Send." },
      },
      play: async (ctx) => {
        const rightClick = (element: Element) => {
          const box = element.getBoundingClientRect();
          element.dispatchEvent(
            new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: box.left, clientY: box.bottom }),
          );
        };
        const item = (label: string) =>
          [...ctx.document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((row) => row.textContent === label);
        rightClick(ctx.find({ selector: ".nt-pickers .acpmux-mic" }));
        await ctx.waitFor(() => item("Hide Dictation Button"));
        item("Hide Dictation Button")!.click();
        await ctx.waitFor(() => !ctx.document.querySelector(".nt-pickers .acpmux-mic"));
        rightClick(ctx.find({ selector: ".nt-pickers .nt-send" }));
        await ctx.waitFor(() => item("Show Dictation Button"));
      },
    },
    "template-composer": {
      note: "Composer template (tabs.newTabTemplate): one large prompt, no chats.",
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
      note: "Classic template: the Terminal | Browser | Agent page.",
      ready: newTab({ template: "classic" }),
      snapshot: noChat(manySessions(4)),
    },
    projects: {
      note: "All chats' Projects view (cx-ncc.66): the chats grouped under their project folder, the newest project first; a header folds its chats. The calm default lists recent chats only, so this is the Threads template, which lists them all.",
      ready: newTab({ template: "threads" }),
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Projects" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-all-group"));
      },
    },
    "style-switch": {
      note: "The New Tab style dots (Leo 2026-10-14): one small round dot per style under the page, the current one in the accent and the accent dot sliding to a pick. A pointer over a dot shows its name; a pick shows the picked name for a moment, then fades it, and is saved as tabs.newTabTemplate.",
      ready: newTab({ template: "default" }),
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-style input[value=default]:checked"));
        await ctx.click({ role: "radio", name: "Threads" });
        await ctx.waitFor(() =>
          galleryNativeCalls(ctx.document).some(
            (call) => call.method === "newTab.setTemplate" && call.params?.template === "threads",
          ),
        );
        await ctx.waitFor(() => ctx.document.querySelector(".nt-style input[value=threads]:checked"));
      },
    },
    "no-template-dots": {
      note: "New Tab shows no template dots and no default-kind toggle: the template is set in Settings, and a terminal opens only when picked (Leo 2026-10-12). The host payload is what it sent before, dots on.",
      ready: newTab({ template: "classic", templateSwitcher: true, defaultKind: "terminal" }),
      snapshot: noChat(manySessions(4)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-newtab"));
        if (ctx.document.querySelector('.nt-templates, input[name="nt-template"], .acpmux-newtab-default'))
          throw new Error("the New Tab page still shows template dots or the default-kind toggle");
      },
    },
  }),
});
