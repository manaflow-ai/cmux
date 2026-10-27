// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// The New Tab page (NewTabScreen.tsx, ChatCards.tsx, variant B): the tab opens as the page when
// the `ready` answer carries `newTab`, as the app's new tab does.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CATALOG, CWD, fleetPeers, manySessions, noChat, session } from "../../../gallery/fixtures/acpmux";
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

/// The typed-tab-match variants' omnibar: open tabs, a workspace and visited pages that match "release".
const RELEASE_OMNIBAR = {
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
};

/// The suggestions-* variants' omnibar (Leo 2026-10-24): "ff" once listed toolbar-diffviewer and
/// app-efficiency above Ask, and the web search first. A review tab, three workspaces in the home
/// folder and the repo's page open in a browser tab.
const FF_OMNIBAR = {
  tabs: [
    { id: "tab-review", kind: "terminal", title: "All sessions", detail: "/tmp/review/review.diff" },
    {
      id: "tab-repo",
      kind: "browser",
      title: "manaflow-ai/cmux",
      detail: "github.com/manaflow-ai/cmux",
      icon: SITE_ICON,
    },
  ],
  workspaces: [
    { id: "workspace-chief", name: "chief-pet-default-off", detail: "~" },
    { id: "workspace-toolbar", name: "toolbar-diffviewer", detail: "~" },
    { id: "workspace-efficiency", name: "app-efficiency", detail: "~" },
  ],
  folders: [CWD],
  commands: [],
  history: [],
};

/// What plays, as the host pushes it (`nowPlaying`): Spotify's track with its art.
const nowPlayingTrack = (playing: boolean) => ({
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
  source: "Spotify",
  labels: { play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track" },
});

// The variants were drawn on Cards, the page an unset template showed before Minimal (Leo
// 2026-10-20) became the default; they keep it unless they name another (the minimal-* ones do).
const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    template: "cards",
    ...fields,
  },
  newSession: true,
});

// The weather widget's reading (AgentPaneNewTabWeather), read `age` ms ago.
const weatherAt = (age: number) => ({
  place: "Berlin",
  temperature: 18.4,
  high: 22.1,
  low: 11.6,
  code: 2,
  unit: "celsius",
  readAt: Date.now() - age,
});

// The machines widget's snapshot: an SSH peer acpmux lists (online) and a Cloud host an older chat
// ran on that it no longer lists (offline).
const ambientSnapshot = () => {
  const snapshot = noChat(manySessions(12));
  const [first] = snapshot.sessions;
  return {
    ...snapshot,
    peers: ["build-box"],
    peerKinds: { "build-box": "ssh" as const },
    sessions: first
      ? [...snapshot.sessions, { ...first, sessionId: "cloud-old", hostKind: "cloud" as const, host: "cloud-dev" }]
      : snapshot.sessions,
  };
};

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

/// A suggestion row as the popover draws it: its kind (`data-type`) and its title.
type SuggestionRow = { type: string; title: string };

/// Types `text` into the field and waits until the popover's rows pass `problem` (undefined when
/// they do); at the wait's cap it fails with what `problem` last said about the rows.
async function typedSuggestions(
  ctx: PlayContext,
  text: string,
  problem: (rows: SuggestionRow[]) => string | undefined,
): Promise<void> {
  const rows = (): SuggestionRow[] =>
    [...ctx.document.querySelectorAll<HTMLElement>(".nt-popover .nt-row")].map((row) => ({
      type: row.dataset.type ?? "",
      title: row.querySelector(".nt-row-title")?.textContent ?? "",
    }));
  await ctx.type(text, { selector: ".nt-field" });
  try {
    await ctx.waitFor(
      () =>
        ctx.document.querySelector<HTMLInputElement>(".nt-field")?.value === text &&
        rows().length > 0 &&
        problem(rows()) === undefined,
    );
  } catch {
    const seen = rows();
    throw new Error(
      `"${text}": ${problem(seen) ?? "no rows"} (rows: ${seen.map((row) => `${row.type}:${row.title}`).join(", ")})`,
    );
  }
}

/// The rows' kinds, first to last, without the create rows at the end.
const navigationTypes = (rows: SuggestionRow[]) => rows.filter((row) => row.type !== "create").map((row) => row.type);

/// "ff": Ask first, no workspace that only holds "ff" inside a word, the web search last, no create row.
function ffProblem(rows: SuggestionRow[]): string | undefined {
  const types = navigationTypes(rows);
  if (types[0] !== "ask") return "the first row is not Ask";
  if (rows.some((row) => row.type === "workspace" && /toolbar-diffviewer|app-efficiency/.test(row.title)))
    return "a workspace that only has ff inside a word shows";
  if (types.at(-1) !== "search") return "the web search is not the last row";
  if (rows.some((row) => row.type === "create")) return "a create row shows for text that names none";
  return undefined;
}

/// The first two rows' kinds are `first` and `second` (one of them Ask); the other one is `title`.
function leadProblem(first: string, second: string, title: string) {
  return (rows: SuggestionRow[]): string | undefined => {
    const [one, two] = rows;
    if (one?.type !== first) return `the first row is not ${first}`;
    if (two?.type !== second) return `the second row is not ${second}`;
    const named = one?.type === "ask" ? two : one;
    if (named?.title !== title) return `the ${first === "ask" ? "second" : "first"} row is not ${title}`;
    if (navigationTypes(rows).at(-1) !== "search") return "the web search is not the last row";
    return undefined;
  };
}

/// Types a prompt, pastes an image and starts Now Playing, then checks that the composer's card
/// and its field are where the empty page drew them (Leo 2026-10-19: the composer kept moving).
async function holdsItsPlace(ctx: PlayContext): Promise<void> {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
  const place = () => {
    const box = ctx.document.querySelector(".nt-box")!.getBoundingClientRect();
    const field = ctx.document.querySelector(".nt-field")!.getBoundingClientRect();
    return `${box.top},${box.left},${box.width} ${field.top},${field.left}`;
  };
  const start = place();
  await ctx.type("why does the release build fail", { selector: ".nt-field" });
  await ctx.waitFor(() => ctx.document.querySelector(".nt-popover .nt-row") !== null);
  const view = ctx.document.defaultView as unknown as typeof globalThis & {
    cmuxAcpmuxBridge?: { applyNowPlaying?(track: unknown): void };
  };
  const canvas = ctx.document.createElement("canvas");
  canvas.width = 320;
  canvas.height = 200;
  const paint = canvas.getContext("2d")!;
  paint.fillStyle = "#3a7bd5";
  paint.fillRect(0, 0, 320, 200);
  const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
  const data = new view.DataTransfer();
  data.items.add(new view.File([blob], "Screenshot.png", { type: "image/png" }));
  ctx
    .find({ selector: ".nt-field" })
    .dispatchEvent(new view.ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  await ctx.waitFor(() => ctx.document.querySelector(".nt-box .acpmux-attachment-image:not([aria-busy])") !== null);
  view.cmuxAcpmuxBridge?.applyNowPlaying?.({
    title: "Weightless",
    artist: "Marconi Union",
    artwork: ALBUM_ART,
    playing: false,
    position: 132,
    duration: 480,
    rate: 1,
    positionDate: Date.now(),
    canPrevious: true,
    canNext: true,
    labels: { play: "Play", pause: "Pause", previous: "Previous Track", next: "Next Track" },
  });
  await ctx.waitFor(() => ctx.document.querySelector(".nt-player") !== null);
  // The suggestions close, so the capture shows the image under the text.
  await ctx.press("Escape");
  await ctx.waitFor(() => ctx.document.querySelector(".nt-popover") === null);
  if (place() !== start) throw new Error(`the composer moved from ${start} to ${place()}`);
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
    "agent-session/acpmux/newtab/AmbientWidgets.tsx#AmbientWidgets",
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
    "agent-session/acpmux/newtab/WidgetEditing.tsx",
    "agent-session/acpmux/newtab/StageCards.tsx",
    "agent-session/acpmux/DictationMic.tsx#DictationMic",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "ui/HideableChrome.tsx#HideableChrome",
    "ui/HideableChrome.tsx#ChromeArea",
    "ui/VirtualList.tsx#VirtualList",
  ],
  variants: withAllChats({
    "start-refused": {
      note: "A refused new chat keeps the typed prompt and SSH machine, with the host's reason inline.",
      ready: newTab({ template: "minimal", pageWidgets: [] }),
      snapshot: noChat([], { peers: ["devbox"], peerKinds: { devbox: "ssh" } }),
      native: { "chat.new": { nativeError: { code: "agent.start_failed", userMessage: "devbox: agent unavailable" } } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.click({ selector: '.nt-location .acpmux-location-picker[data-kind="computer"] button' });
        await ctx.click({ role: "menuitem", name: /devbox/ });
        await ctx.type("Inspect the failed build and suggest a fix.", { selector: ".nt-field" });
        await ctx.press("Enter");
        await ctx.waitFor(() => galleryNativeCalls(ctx.document).some((call) => call.method === "chat.new"));
        // Also ends on the unpatched base, so the comparison records its lost draft rather than
        // waiting for a reason that the old action swallowed.
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".nt-field") ||
            !!ctx.document.querySelector('[role="alert"]')?.textContent?.includes("agent unavailable"),
        );
      },
    },
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
    // The model button opens its one menu (Leo 2026-10-20), whole: the card does not clip it
    // (Lawrence 2026-10-13). Points near its top and bottom edges hit the menu, not the page. On New
    // Tab More models shows its models in place, under its row (newTabComposer.ts), then Add harness….
    "machines-fleet": {
      note: "The machine chip with 21 machines acpmux lists (`host ls`): every one, in This Mac, My machines and Cloud and VMs; in each the ones a chat can start on first, in number order, the rest greyed with their state and no pick.",
      ready: newTab(),
      snapshot: noChat([], fleetPeers()),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.click({ selector: '.nt-location .acpmux-location-picker[data-kind="computer"] button' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="listbox"] [role="option"]') !== null);
      },
    },
    "model-picker-open": {
      note: "The New Tab model button's menu, open down: the harness rail and the models, never cut by the card; More models opens in place and ends on Add harness….",
      ready: newTab(),
      snapshot: noChat(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.click({ role: "button", name: "Model" });
        await ctx.waitFor(() => {
          const menu = ctx.document.querySelector<HTMLElement>(".acpmux-quick-menu");
          if (!menu || !menu.querySelector('[role="menuitemradio"]')) return false;
          const box = menu.getBoundingClientRect();
          if (box.height < 120) return false;
          const x = box.left + box.width / 2;
          return [box.top + 6, box.bottom - 6].every((y) => menu.contains(ctx.document.elementFromPoint(x, y)));
        });
        // The row itself, by role: the menu's hidden width probe (QuickMenuSpacer) repeats its text
        // later in the document, and a text target takes the last match.
        await ctx.click({ role: "menuitem", name: "More models" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-list > .acpmux-quick-more-list"));
        const more = ctx.document.querySelector(".acpmux-quick-list > .acpmux-quick-more-list")!;
        if (!more.nextElementSibling?.textContent?.includes("Add harness"))
          throw new Error("the model menu's More models does not end on Add harness…");
      },
    },
    // The effort is part of the one model button (Leo 2026-10-20: "Opus 5.5  Medium"), and its
    // levels are the menu's Effort submenu (P0 #8: a live pick, never a picture): acpmux starts
    // Claude Code on Medium, so the button names it before any chat exists.
    "reasoning-chip": {
      note: "Before any chat: the model button names the model and the level acpmux starts Claude Code on (Medium); its menu's Effort row opens the levels. No separate Reasoning chip.",
      ready: newTab(),
      snapshot: reasoningChat(),
    },
    "catalog-fast-menu": {
      note: "Before a session reports config options: the New Tab model menu offers the model's catalog Fast mode beside Effort, as a started chat does.",
      ready: newTab(),
      snapshot: reasoningChat(),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-model .acpmux-picker-button") !== null);
        await ctx.click({ selector: ".acpmux-model .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-fast") !== null);
      },
    },
    "reasoning-chip-stage": {
      note: "The Default template's stage layout before any chat: its own composer at the foot of the page, the one model button (model and effort) in the box, text at rest, the soft pill only on the hovered control.",
      ready: newTab({ template: "default" }),
      snapshot: reasoningChat(),
    },
    // Minimal, the page as it opens by default (Leo 2026-10-20, newtab/pageWidgets.ts): the composer
    // alone, no greeting (Leo 2026-10-22), with chats on this Mac it does not list. The optional
    // headline is agent-pane.new-tab-headline. `minimal-default` is a host that
    // sends no template (the app's unset key); `minimal-widgets` turns the stage's widgets on.
    "minimal-default": {
      note: "Minimal, New Tab's default layout: the composer alone, with its folder and machine, model, effort, mic and Send, and under the page the three dots (Claude Minimal, Claude Minimal with the quick actions, Codex Minimal), the first marked. No greeting. The headline, project card, quick actions, chats and other template dots are widgets, off by default.",
      ready: newTab({ template: undefined }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        const extra = ctx.document.querySelector(".nt-greeting, .nt-headline, .nt-stage, .nt-cards, .nt-create");
        if (extra) throw new Error(`the minimal page shows ${extra.className}`);
        // The three dots only (newtab/tabDots.ts, Leo 2026-10-23), not the other styles.
        const dots = ctx.document.querySelectorAll(".nt-style input[type=radio]").length;
        if (dots !== 3) throw new Error(`the minimal page shows ${dots} dots, not the three`);
      },
    },
    "widgets-all-off": {
      note: "All optional New Tab widgets off: the composer is the whole page.",
      ready: newTab({ template: "minimal", pageWidgets: [] }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        if (ctx.document.querySelector(".nt-extras, .nt-headline, .nt-stage, .nt-create, .nt-ambient"))
          throw new Error("optional widget rendered while all are off");
      },
    },
    "widgets-all-on": {
      note: "All optional New Tab widgets on: work-on headline, projects, actions, chats, clock, stopwatch, warm greeting and quote of the day.",
      ready: newTab({
        template: "minimal",
        pageWidgets: [
          "greeting",
          "projects",
          "actions",
          "chats",
          "styleDots",
          "weather",
          "machines",
          "clock",
          "timer",
          "warmGreeting",
          "quote",
        ],
        weather: weatherAt(60_000),
      }),
      snapshot: ambientSnapshot(),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-headline, .nt-stage") !== null);
        await ctx.waitFor(() => ctx.document.querySelector(".nt-extras") !== null);
        if (!ctx.document.querySelector(".nt-extra-clock, .nt-extra-timer, .nt-extra-warm, .nt-extra-quote"))
          throw new Error("all-on extras missing");
      },
    },
    "layout-codex-tabs-above": {
      note: "Codex-style comparison: project and machine context sit above the composer, with the model name and a free Fast bolt together in the model picker.",
      ready: newTab({ template: "minimal", pageWidgets: ["greeting"] }),
      snapshot: noChat(manySessions(12)),
    },
    "layout-claude-chips-below": {
      note: "Claude-style comparison: the composer stays spacious while project, machine, permission and model controls sit in the quiet row below it; paid Fast remains in the model menu.",
      ready: newTab({ template: "default" }),
      snapshot: noChat(manySessions(12)),
    },
    "layout-current-fixed": {
      note: "Current fixed layout: the work-on headline names the project picker, real project and machine icons remain visible, and the existing glass spacing is preserved.",
      ready: newTab({ template: "minimal", pageWidgets: ["greeting"] }),
      snapshot: noChat(manySessions(12)),
    },
    // A user who had turned the greeting off before it went (`"greeting": false` in cmux.json, which
    // the host sends as `headlineOff`): the composer stays where it sat for them, at the page's top
    // padding, with no room kept for the headline.
    "minimal-headline-off": {
      note: "Minimal for someone who had turned the greeting off (greeting: false in cmux.json): the composer alone, where it sat for them before, with no room kept over it for the headline.",
      ready: newTab({ template: undefined, pageWidgets: [], headlineOff: true }),
      snapshot: noChat(manySessions(12)),
      play: (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null),
    },
    "minimal-widgets": {
      note: "Minimal with the project card, quick actions, recent chats and the template dots turned on in Settings: Default's stage around the same composer.",
      ready: newTab({
        template: "minimal",
        pageWidgets: ["greeting", "projects", "actions", "chats", "styleDots"],
      }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-stage .nt-env") !== null);
        await ctx.waitFor(() => ctx.document.querySelector(".nt-style") !== null);
      },
    },
    // The ambient widgets (`tabs.newTabWidgets.weather|machines`, newtab/ambient.ts): one quiet row
    // under the composer. `minimal-ambient` has a fresh reading and an SSH peer online beside an old
    // Cloud host; `minimal-ambient-offline` has a reading older than its refresh, drawn dimmed.
    "minimal-ambient": {
      note: "Minimal with Weather and Machines on: under the composer, today's weather (glyph, temperature, high and low, city) and each machine with its color, icon and an online dot (this Mac and an SSH peer online, an old Cloud host offline).",
      ready: newTab({
        template: "minimal",
        pageWidgets: ["greeting", "weather", "machines"],
        weather: weatherAt(60_000),
      }),
      snapshot: ambientSnapshot(),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-ambient-machine").length === 3);
        if (ctx.document.querySelector(".nt-ambient-weather[data-stale]")) throw new Error("a fresh reading is dimmed");
        const field = ctx.document.querySelector(".nt-field")?.getBoundingClientRect();
        const row = ctx.document.querySelector(".nt-ambient")?.getBoundingClientRect();
        if (!field || !row || row.top < field.bottom) throw new Error("the ambient row is not under the field");
        if (ctx.document.querySelectorAll(".nt-ambient-machine[data-online]").length !== 2)
          throw new Error("this Mac and the SSH peer should be online, the Cloud host offline");
      },
    },
    "minimal-ambient-offline": {
      note: "The weather could not refresh (offline): the last reading stays, dimmed; its tooltip says it is the last reading.",
      ready: newTab({ template: "minimal", pageWidgets: ["greeting", "weather"], weather: weatherAt(3 * 60 * 60_000) }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-ambient-weather[data-stale]") !== null);
      },
    },
    "minimal-stage-foot": {
      note: "Minimal with the project card, quick actions and recent chats on, the template dots off: the composer at the page's foot, its quiet row a few px over the page's bottom edge, as Claude Code's (Leo 2026-10-21).",
      ready: newTab({
        template: "minimal",
        pageWidgets: ["greeting", "projects", "actions", "chats"],
      }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-stage .nt-env") !== null);
        await ctx.waitFor(() => ctx.document.querySelector(".nt-foot .acpmux-composer-foot") !== null);
      },
    },
    // Minimal's widgets in the user's order (`tabs.newTabWidgets.order`) and its edit mode
    // (newtab/WidgetEditing.tsx): right-click > Edit New Tab, and the widgets wiggle with their ✕.
    "minimal-widgets-ordered": {
      note: "Minimal with Recent Chats dragged over the project card in edit mode: the stage draws the widgets in the order the user left them.",
      ready: newTab({ template: "minimal", pageWidgets: ["greeting", "chats", "projects"] }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-stage .nt-env") !== null);
        const chats = ctx.document.querySelector(".nt-chats");
        const projects = ctx.document.querySelector(".nt-env");
        if (!chats || !projects || !(chats.compareDocumentPosition(projects) & Node.DOCUMENT_POSITION_FOLLOWING))
          throw new Error("Recent Chats should come before the project card");
      },
    },
    "minimal-edit-mode": {
      note: "Minimal's edit mode, as an iPhone's home screen: each widget wiggles (still with Reduce Motion or animations off) and has a ✕ that turns it off; drag one, or Option-Up / Option-Down, to move it. Add Widgets opens App Store Features on New Tab; Done or Escape ends it.",
      ready: newTab({ template: "minimal", pageWidgets: ["greeting", "projects", "actions", "chats"] }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-stage .nt-env") !== null);
        await ctx.contextMenu({ selector: ".nt-env" });
        await ctx.click({ role: "menuitem", name: "Edit New Tab" });
        // Four ✕: the headline over the stage is a widget too, with its own frame.
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-widget-frame .nt-widget-remove").length === 4);
        await ctx.waitFor(() => ctx.document.querySelector(".nt-edit-bar") !== null);
      },
    },
    // The New Tab composer's states, as the chat composer's (agent-pane.composer composer-*): the
    // same chips, pills, caret and rim (test/composer-caret-focus.test.ts).
    ...Object.fromEntries(
      Object.entries(composerStatePlays(".nt-field")).map(([state, variant]) => [
        `composer-${state}`,
        { ...variant, ready: newTab(), snapshot: reasoningChat() },
      ]),
    ),
    // The mic never leaves the box (Leo 2026-10-19, as Claude Code's): the prompt shrinks instead.
    // The box holds the prompt, the mic and Send; the model, effort and permission mode sit in the
    // quiet row under it. `composer-mic` at the stage's width, `composer-mic-narrow` with the page
    // squeezed to 300 px (a narrow split pane).
    ...Object.fromEntries(
      (
        [
          ["composer-mic", 0],
          ["composer-mic-narrow", 300],
        ] as const
      ).map(([name, width]) => [
        name,
        {
          note: width
            ? "The New Tab composer squeezed to 300 px: the mic and Send stay in the box, the prompt shrinks; the quiet row under it keeps the mode, model and effort."
            : "The New Tab composer: the box holds the prompt, the mic and Send; under it the quiet row with the permission mode on the left and the model and effort on the right.",
          // Cards, the page an unset template shows (the first dot), draws Claude Code's split; the
          // Default template (the second dot) keeps the chips in its box.
          ready: newTab({ template: "cards" }),
          snapshot: reasoningChat(),
          play: async (ctx: PlayContext) => {
            await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
            if (width) ctx.document.body.style.maxWidth = `${width}px`;
            await ctx.waitFor(() => {
              const box = ctx.document.querySelector(".nt-box")?.getBoundingClientRect();
              const mic = ctx.document.querySelector(".nt-box .acpmux-mic")?.getBoundingClientRect();
              const send = ctx.document.querySelector(".nt-box .acpmux-send")?.getBoundingClientRect();
              if (!box || !mic || !send || mic.width < 12 || send.width < 12) return false;
              if (width && box.width > width) return false;
              return mic.right <= send.left + 0.5 && send.right <= box.right + 0.5 && mic.left >= box.left;
            });
            if (!ctx.document.querySelector(".nt-foot .acpmux-model"))
              throw new Error("the model chip is not in the quiet row under the box");
          },
        },
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
    "attachment-menu": {
      note: "The New Tab composer keeps the chat composer's leading + attachment control: opening it exposes the same Attach option without moving the field.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.waitFor(
          () => ctx.document.querySelector(".nt-pickers .acpmux-newtab-plus .acpmux-picker-button") !== null,
        );
        await ctx.click({ selector: ".acpmux-newtab-plus .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-newtab-plus [data-value="attach"]') !== null);
        const input = ctx.document.querySelector<HTMLInputElement>(".nt-pickers .acpmux-attach-input");
        if (!input || !input.multiple) throw new Error("the New Tab attachment chooser is missing or single-file");
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
    "stage-layout": {
      note: "The Default template's layout (Leo 2026-10-19, Claude Code desktop's new-session screen): the composer at the foot with the plain footer (folder and mode left, model and effort right); over it, centered, the environment card (this project checked, the other projects, Choose environment) and the suggested actions card (the chats that need you, then New terminal, New browser tab, New chat); the recent chats under them.",
      ready: newTab({ template: "default", projects: WIDGET_PROJECTS }),
      snapshot: noChat(widgetSessions()),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-stage .nt-env") !== null);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-suggest-chat").length > 0);
        const composer = ctx.document.querySelector(".nt-composer")!.getBoundingClientRect();
        const env = ctx.document.querySelector(".nt-env")!.getBoundingClientRect();
        if (env.bottom > composer.top) throw new Error("the environment card is not above the composer");
      },
    },
    "stage-hover": {
      note: "A pointer over a chat that needs you: its hover card floats over the page, offset from the row, solid, never over the row's own text.",
      ready: newTab({ template: "default", projects: WIDGET_PROJECTS }),
      snapshot: noChat(widgetSessions()),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".nt-suggest-chat").length > 0);
        await ctx.hover({ selector: ".nt-suggest-chat" });
        // The card settled: its fade-in ended, so the capture shows the solid card, not a ghost.
        await ctx.waitFor(() => {
          const card = ctx.document.querySelector<HTMLElement>(".nt-hovercard");
          return (
            !!card &&
            !card.hasAttribute("data-starting-style") &&
            ctx.document.defaultView?.getComputedStyle(card).opacity === "1"
          );
        });
        const row = ctx.document.querySelector(".nt-suggest-chat .nt-stage-text")!.getBoundingClientRect();
        const card = ctx.document.querySelector(".nt-hovercard")!.getBoundingClientRect();
        if (card.bottom > row.top && card.top < row.bottom) throw new Error("the hover card covers its row's text");
      },
    },
    "no-harness-installed": {
      note: "No harness installed (Leo 2026-10-14): the composer's chip says Add harness and opens the Harnesses page. No line under the field, no grey placeholder pills.",
      // The mock daemon answers with no harness, as acpmux does on a Mac without an agent CLI.
      ready: { ...newTab(), transport: "mock" },
      mockHarnesses: [],
      snapshot: { ...noChat(), catalog: [] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-composer .acpmux-add-harness") !== null);
        if (ctx.document.querySelector(".nt-no-agent")) throw new Error("a No agent to ask line shows under the field");
        const chip = ctx.document.querySelector(".nt-composer .acpmux-add-harness")!.getBoundingClientRect();
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
      note: "Now Playing, playing: what plays on this Mac (Spotify here) in one soft card under the create actions: rounded artwork, the title in the primary color and the artist in the secondary one, quiet level bars, a thin progress line, and compact Previous, Pause (the one filled control) and Next. The controls ask the host, and a pause stills the bars.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        const bridge = ctx.document.defaultView?.cmuxAcpmuxBridge;
        bridge?.applyNowPlaying?.(nowPlayingTrack(true));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=true]") !== null);
        await ctx.click({ role: "button", name: "Pause" });
        await ctx.waitFor(() =>
          galleryNativeCalls(ctx.document).some(
            (call) => call.method === "nowPlaying.command" && call.params?.command === "playPause",
          ),
        );
        bridge?.applyNowPlaying?.(nowPlayingTrack(false));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=false]") !== null);
        bridge?.applyNowPlaying?.(nowPlayingTrack(true));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=true]") !== null);
      },
    },
    "now-playing-paused": {
      note: "Now Playing, paused: Play is the filled control, the level bars rest low and dimmer, and the progress line holds still.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        ctx.document.defaultView?.cmuxAcpmuxBridge?.applyNowPlaying?.(nowPlayingTrack(false));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-playing=false]") !== null);
      },
    },
    "now-playing-no-artwork": {
      note: "Now Playing without artwork (a browser tab or a stream without art): a music note on the card's fill in the artwork's rounded slot; no progress line without a known length.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        const { artwork: _artwork, duration: _duration, ...track } = nowPlayingTrack(true);
        ctx.document.defaultView?.cmuxAcpmuxBridge?.applyNowPlaying?.({
          ...track,
          title: "Lo-fi beats to code to",
          artist: "YouTube",
        });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player[data-artwork=false]") !== null);
      },
    },
    "now-playing-long-title": {
      note: "Now Playing with a long title and artist: each stays on one line and ends in an ellipsis; the card keeps its width and the level bars and controls keep their place.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        ctx.document.defaultView?.cmuxAcpmuxBridge?.applyNowPlaying?.({
          ...nowPlayingTrack(true),
          title:
            "Symphony No. 9 in D Minor, Op. 125 \u201cChoral\u201d: IV. Presto \u2013 Allegro assai \u2013 Alla marcia",
          artist: "Berliner Philharmoniker, Herbert von Karajan, Gundula Janowitz, Hilde R\u00f6ssel-Majdan",
        });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player") !== null);
      },
    },
    "now-playing-menu": {
      note: "Now Playing's right-click menu (Shift-F10 too): Pause, Next, Previous, Open in Spotify, then Hide Now Playing and Now Playing Settings\u2026 after a separator. Next is disabled here: the source has no next track.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        ctx.document.defaultView?.cmuxAcpmuxBridge?.applyNowPlaying?.({ ...nowPlayingTrack(true), canNext: false });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player") !== null);
        await ctx.contextMenu({ selector: ".nt-player-title" });
        await ctx.waitFor(() => ctx.document.querySelector('.ui-context-menu [role="menuitem"]') !== null);
      },
    },
    "now-playing-off": {
      note: "Show Now Playing on New Tab off (or nothing plays): the host sends no track, so the page draws no card and keeps no space; it is the plain New Tab page from the first frame.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        ctx.document.defaultView?.cmuxAcpmuxBridge?.applyNowPlaying?.(null);
        await ctx.waitFor(
          () => ctx.document.querySelector(".nt-screen") !== null && ctx.document.querySelector(".nt-player") === null,
        );
      },
    },
    "now-playing-hidden": {
      note: "After Hide Now Playing: the card is gone and one quiet line says it is hidden and can come back in Settings, with Undo; the next New Tab page draws nothing and keeps no space.",
      ready: newTab(),
      snapshot: noChat(manySessions(2)),
      native: { "nowPlaying.command": null },
      play: async (ctx) => {
        const bridge = ctx.document.defaultView?.cmuxAcpmuxBridge;
        bridge?.applyNowPlaying?.(nowPlayingTrack(true));
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player") !== null);
        await ctx.contextMenu({ selector: ".nt-player-title" });
        await ctx.click({ role: "menuitem", name: "Hide Now Playing" });
        await ctx.waitFor(() =>
          galleryNativeCalls(ctx.document).some(
            (call) => call.method === "nowPlaying.command" && call.params?.command === "hide",
          ),
        );
        bridge?.applyNowPlaying?.(null);
        await ctx.waitFor(() => ctx.document.querySelector(".nt-player-note") !== null);
      },
    },
    "typed-prompt": {
      note: "A typed instruction: Ask first (Return's, highlighted), a web search, then New terminal, New browser tab and New chat in the popover over the cards; the cards stay where they were.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("fix the flaky upload test", { selector: ".nt-field" });
      },
    },
    "typed-keywords": {
      note: 'Leo 2026-10-20 (no Search | Ask switch) and 2026-10-24 ("Search the web. Do you really want that first?"): plain keywords. Ask Claude Code leads (Return\'s, highlighted), the web search is the last row.',
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("rust serde", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector('#nt-row-0[data-type="ask"][aria-selected="true"]'));
      },
    },
    "typed-question": {
      note: "A question: Ask Claude Code leads (Return's, highlighted), the web search one row down.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("why does the upload test flake?", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector('#nt-row-0[data-type="ask"][aria-selected="true"]'));
      },
    },
    "typed-tab-match-stage": {
      note: "The Default template's stage layout with text that matches open tabs: the composer at the foot, so the rows open above it (popup-escape).",
      ready: newTab({ template: "default", omnibar: RELEASE_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
    },
    "typed-tab-match": {
      note: "Text that matches open tabs, workspaces and visited pages: the Release workspace first (its exact name, Return's), Ask, then those rows (with their favicons, a glyph while one loads), the web search and the create strip in the popover; Down to the last row scrolls to it (dogfood 2026-10-08).",
      ready: newTab({
        omnibar: RELEASE_OMNIBAR,
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.type("release", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-rows"));
        // The workspace, Ask, then the first tab. Down to the last option (the create strip's end),
        // then three more wrap round to the first tab.
        const options = ctx.document.querySelectorAll('.nt-popover [role="option"]').length;
        for (let step = 0; step < options - 1; step++) await ctx.press("ArrowDown");
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
    "suggestions-ff": {
      note: 'Leo 2026-10-24 ("Search the web. Do you really want that first?"): "ff" asks the agent first, offers no workspace that only holds ff inside a word, and keeps the web search last; nothing in the text names a create row.',
      ready: newTab({ omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", ffProblem);
        // The create actions stay one click away, as the strip under the rows.
        const strip = ctx.document.querySelectorAll(".nt-popover .nt-create-strip-item").length;
        if (strip !== 3) throw new Error(`the create strip shows ${strip} actions, not 3`);
      },
    },
    "suggestions-url": {
      note: "An address an open tab already shows: Switch to tab first, Ask right under it, the web search last.",
      ready: newTab({ omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "github.com/manaflow-ai/cmux", leadProblem("tab", "ask", "manaflow-ai/cmux"));
      },
    },
    "suggestions-session": {
      note: "A workspace's exact name: that workspace first, Ask right under it, the web search last.",
      ready: newTab({ omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "app-efficiency", leadProblem("workspace", "ask", "app-efficiency"));
      },
    },
    "suggestions-create": {
      note: 'Text that names a create action ("new t"): the New terminal row shows at the end of the list.',
      ready: newTab({ omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "new t", (rows) =>
          rows.some((row) => row.type === "create" && /terminal/i.test(row.title)) ? undefined : "no New terminal row",
        );
      },
    },
    "suggestions-chat-ff": {
      note: 'The chat order (newTab.suggestionOrder "chat"): Ask always first; "ff" lists Ask, the web search, then the three create rows (no strip).',
      ready: newTab({ suggestionOrder: "chat", omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", (rows) => {
          const types = navigationTypes(rows);
          if (types[0] !== "ask") return "the first row is not Ask";
          if (types.at(-1) !== "search") return "the web search is not the last row";
          if (rows.filter((row) => row.type === "create").length !== 3)
            return "the three create rows do not end the list";
          return undefined;
        });
        if (ctx.document.querySelector(".nt-create-strip")) throw new Error("the chat order draws the create strip");
      },
    },
    "suggestions-chat-url": {
      note: "The chat order: Ask first even for an address an open tab shows; Switch to tab right under it.",
      ready: newTab({ suggestionOrder: "chat", omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "github.com/manaflow-ai/cmux", leadProblem("ask", "tab", "manaflow-ai/cmux"));
      },
    },
    "suggestions-minimal-ff": {
      note: 'The minimal order (newTab.suggestionOrder "minimal"): as the default, at most three matches and no create rows while typing; "ff" lists Ask, then the web search.',
      ready: newTab({ suggestionOrder: "minimal", omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", ffProblem);
      },
    },
    "suggestions-minimal-url": {
      note: "The minimal order with an address an open tab shows: Switch to tab first, Ask under it, the web search last, no create rows.",
      ready: newTab({ suggestionOrder: "minimal", omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "github.com/manaflow-ai/cmux", (rows) => {
          if (rows.some((row) => row.type === "create")) return "a create row shows in the minimal order";
          if (rows.filter((row) => ["tab", "workspace", "history", "open"].includes(row.type)).length > 4)
            return "more than the address and three matches show";
          return leadProblem("tab", "ask", "manaflow-ai/cmux")(rows);
        });
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
    "template-cards": {
      note: "Cards template, the default and the first dot (u2851): Claude Code's split, the project strip heading the card, the box with the prompt, the mic and Send, the mode, model and effort in the quiet row under it, then three chat cards.",
      ready: newTab({ template: "cards" }),
      snapshot: noChat(manySessions(6)),
    },
    "template-cards-typed": {
      note: "Cards template with keywords typed: the box keeps the mic and Send, and the suggestions (Ask first) open under the quiet row, never over its chips.",
      ready: newTab({ template: "cards" }),
      snapshot: noChat(manySessions(6)),
      play: async (ctx) => {
        await ctx.type("rust serde", { selector: ".nt-field" });
        await ctx.waitFor(() => ctx.document.querySelector('#nt-row-0[data-type="ask"]'));
      },
    },
    "template-composer": {
      note: "Composer template (tabs.newTabTemplate): one large prompt, no chats.",
      ready: newTab({ template: "composer" }),
      snapshot: noChat(manySessions(4)),
    },
    "composer-holds-its-place": {
      note: "After typing, a pasted image and Now Playing: the composer and the typed text are where the empty page drew them; the image sits under the text (Leo 2026-10-19: the composer kept moving).",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: holdsItsPlace,
    },
    "composer-template-holds-its-place": {
      note: "Composer template after typing, a pasted image and Now Playing: the card stays where the empty page drew it, about the middle, instead of re-centering on what grew under it.",
      ready: newTab({ template: "composer", projects: [CWD] }),
      snapshot: noChat(manySessions(4)),
      play: holdsItsPlace,
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
