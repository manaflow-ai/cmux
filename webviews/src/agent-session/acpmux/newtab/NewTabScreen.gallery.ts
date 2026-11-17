// l10n-allow-file: gallery fixtures (sample chats), not shipped UI.
// The New Tab page (NewTabScreen.tsx, ChatCards.tsx, variant B): the tab opens as the page when
// the `ready` answer carries `newTab`, as the app's new tab does.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import type { MarkdownFieldElement } from "../MarkdownField";
import { CATALOG, CWD, fleetPeers, manySessions, noChat, session } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { composerStatePlays } from "../composerStatePlays";
import { newTabComposerTrailingGap } from "./composerGap.experiment";
import { MODEL_PICKER } from "../composerSelectors";
import { translateNewTab } from "./strings";

/// Favicons as the host sends them (cx-d0d.8): small inline PNGs.
const SITE_ICON =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAOElEQVR42mNgoDZQTX79Hx+mSDNeQ4jVjNUQUjVjGIJNEh2QZAAuMJIMoDgQ6ZIWqJ+UqZKZyAEAwqPV6AATmH0AAAAASUVORK5CYII=";
const OTHER_SITE_ICON =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAPklEQVR42mNgoDZ4FcHzHx+mSDNeQ4jVjNUQUjVjGIJN8v/bqyiYJAPQNeMyZDgbQHEg0iUtUD8pUyUzkQMARpy6LDTJkq8AAAAASUVORK5CYII=";

/// No chat yet, Claude Code starting on Medium: the model and reasoning chips both show.
const reasoningChat = () =>
  noChat([], {
    listedSessions: true,
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

/// The machine chip's machine list: Machines… on its right-click menu (its main list is This Mac
/// and Cloud, #28999).
const openMachineList = async (ctx: PlayContext) => {
  await ctx.contextMenu({ selector: '.nt-location .acpmux-location-picker[data-kind="computer"] button' });
  await ctx.click({ role: "menuitem", name: "Machines…" });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover.acpmux-env-machines [role="option"]'));
};

/// New Project (newProject.ts): the folder menu's New project row, then its name field in the strip.
const chooseNewProject = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
  await ctx.click({ selector: '.nt-location [aria-label="Folder"]' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
  await ctx.click({ role: "option", name: /^New project$/ });
  await ctx.waitFor(() => ctx.document.querySelector(".nt-project-name__field"));
};
const projectNameValue = (ctx: PlayContext) =>
  ctx.document.querySelector<HTMLInputElement>(".nt-project-name__field")?.value;

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

/// The stage's fixtures: projects as the host sends them, and chats where three need the user.
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

async function typePrompt(ctx: PlayContext, text: string): Promise<void> {
  const selector = ".nt-field [contenteditable=true]";
  await ctx.waitFor(() => ctx.document.querySelector(selector));
  await ctx.type(text, { selector });
}

function noFixedCreateButtons(ctx: PlayContext): void {
  if (ctx.document.querySelector(".nt-create [data-create]"))
    throw new Error("the home screen still shows fixed creation buttons");
}

async function wrapPrompt(ctx: PlayContext, wrapped: boolean): Promise<void> {
  await ctx.waitFor(() => Boolean(ctx.document.querySelector<MarkdownFieldElement>(".nt-field")?.acpmuxMarkdownField));
  const field = ctx.document.querySelector<MarkdownFieldElement>(".nt-field")!;
  const prompt = "Check the composer layout and keep the first line steady while the prompt wraps. ".repeat(8);
  const lines = (length: number) => {
    field.acpmuxMarkdownField!.type(prompt.slice(0, length));
    const paragraph = field.querySelector<HTMLElement>(".ProseMirror > p")!;
    const lineHeight = Number.parseFloat(ctx.document.defaultView!.getComputedStyle(paragraph).lineHeight);
    return Math.round(paragraph.offsetHeight / lineHeight);
  };
  let low = 1;
  let high = prompt.length;
  while (high - low > 1) {
    const middle = Math.floor((low + high) / 2);
    if (lines(middle) === 1) low = middle;
    else high = middle;
  }
  lines(wrapped ? high : low);
  await ctx.waitFor(() => field.getAnimations().length === 0);
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
  await typePrompt(ctx, text);
  try {
    await ctx.waitFor(
      () =>
        ctx.document.querySelector<MarkdownFieldElement>(".nt-field")?.acpmuxMarkdownField?.plainText() === text &&
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

/// The suggestion kinds in their displayed order.
const navigationTypes = (rows: SuggestionRow[]) => rows.map((row) => row.type);

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

function checkSuggestionSurface(ctx: PlayContext): void {
  const view = ctx.document.defaultView!;
  const box = view.getComputedStyle(ctx.document.querySelector(".nt-box")!);
  const popover = ctx.document.querySelector(".nt-popover")!;
  const list = view.getComputedStyle(popover);
  for (const property of [
    "--glass-tint",
    "--glass-backdrop",
    "--glass-opaque",
    "--glass-edge",
    "--glass-elevation",
    "background-color",
    "background-image",
    "backdrop-filter",
    "border-width",
    "border-color",
    "box-shadow",
    "opacity",
  ]) {
    if (box.getPropertyValue(property) !== list.getPropertyValue(property))
      throw new Error(`suggestions differ from the composer: ${property}`);
  }
  if (popover.hasAttribute("data-host-glass")) throw new Error("suggestions draw a separate native popup material");
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
  await typePrompt(ctx, "why does the release build fail");
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
    .find({ selector: ".nt-field [contenteditable=true]" })
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
  experiment: {
    definition: newTabComposerTrailingGap,
    script: [
      {
        name: "measure trailing controls",
        run: (ctx) => ctx.waitFor(() => ctx.document.querySelector(".nt-pickers .acpmux-composer-actions") !== null),
      },
    ],
  },
  covers: [
    "agent-session/acpmux/newtab/screen.css",
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
    "agent-session/acpmux/newtab/StageCards.tsx",
    "agent-session/acpmux/DictationMic.tsx#DictationMic",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/newtab/NewProjectName.tsx#NewProjectName",
    "agent-session/acpmux/newtab/NewProjectName.tsx#NewProjectFailure",
    "ui/HideableChrome.tsx#HideableChrome",
    "ui/HideableChrome.tsx#ChromeArea",
    "ui/VirtualList.tsx#VirtualList",
  ],
  variants: withAllChats({
    ...Object.fromEntries(
      (["terminal", "browser", "chat"] as const).map((kind) => [
        `create-command-${kind}`,
        {
          note: `The ${kind} creation command appears only when the composer search matches.`,
          ready: newTab(),
          snapshot: noChat(manySessions(3)),
          play: async (ctx: PlayContext) => {
            await ctx.waitFor(() => ctx.document.querySelector(".nt-field"));
            noFixedCreateButtons(ctx);
            await typedSuggestions(ctx, translateNewTab(`create.${kind}`), (rows) =>
              rows.filter((row) => row.type === "create").length === 1
                ? undefined
                : "the search did not isolate one creation command",
            );
          },
        },
      ]),
    ),
    ...Object.fromEntries(
      [0.8, 0.9, 1, 1.1, 1.2].map((scale) => [
        `density-${Math.round(scale * 100)}`,
        {
          note: `Minimal composer and searchable suggestions at ${scale} times Default.`,
          ready: newTab({ template: "minimal", omnibar: FF_OMNIBAR }),
          snapshot: reasoningChat(),
          play: async (ctx: PlayContext) => {
            for (const key of ["composer-zoom", "density-scale", "density-text-scale"]) {
              ctx.document.documentElement.style.setProperty(`--cmux-${key}`, String(scale));
            }
            ctx.document.documentElement.style.setProperty("--cmux-interface-scale", String(Math.max(1, scale)));
            ctx.document.documentElement.style.setProperty("--cmux-row-text-scale", String(scale));
            ctx.document.documentElement.style.setProperty(
              "--cmux-row-icon-scale",
              String(Math.round(16.5 * scale * 2) / 2 / 16.5),
            );
            ctx.document.defaultView?.dispatchEvent(new Event("cmux-ui-scale-change"));
            await ctx.waitFor(() => ctx.document.querySelector(".nt-field"));
            noFixedCreateButtons(ctx);
            await typedSuggestions(ctx, "ff", ffProblem);
          },
        },
      ]),
    ),
    "start-refused": {
      note: "A refused new chat keeps the typed prompt and SSH machine, says why in plain words, and keeps the host's reason under Details.",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([], { peers: ["devbox"], peerKinds: { devbox: "ssh" } }),
      native: { "chat.new": { nativeError: { code: "agent.start_failed", userMessage: "devbox: agent unavailable" } } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await openMachineList(ctx);
        await ctx.click({ role: "option", name: /devbox/ });
        await typePrompt(ctx, "Inspect the failed build and suggest a fix.");
        await ctx.press("Enter");
        await ctx.waitFor(() => galleryNativeCalls(ctx.document).some((call) => call.method === "chat.new"));
        // Also ends on the unpatched base, so the comparison records its lost draft rather than
        // waiting for a reason that the old action swallowed.
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".nt-field") ||
            !!ctx.document.querySelector('[role="alert"]')?.textContent?.includes("agent unavailable") ||
            // Plain words over the box; the host's reason waits under Details (newtab/StartFailure.tsx).
            !!ctx.document.querySelector("[data-error-detail]")?.textContent?.includes("agent unavailable"),
        );
      },
    },
    "customize-slash-menu": {
      note: "Typing /cust offers cmux's own /customize with what it does: ask, watch it change live, then apply or discard.",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([]),
      play: async (ctx) => {
        await typePrompt(ctx, "/cust");
        await ctx.waitFor(() =>
          [...ctx.document.querySelectorAll('[role="option"]')].some((row) => row.textContent?.includes("customize")),
        );
      },
    },
    "customize-refused-elsewhere": {
      note: "/customize with another machine picked: refused inline, since its agent would change that machine's cmux; the prompt stays.",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([], { peers: ["devbox"], peerKinds: { devbox: "ssh" } }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await openMachineList(ctx);
        await ctx.click({ role: "option", name: /devbox/ });
        await typePrompt(ctx, "/customize make the sidebar compact");
        // Picking a machine may itself call chat.new (the pick switches the draft); only a start
        // after Enter would be /customize's.
        const starts = () => galleryNativeCalls(ctx.document).filter((call) => call.method === "chat.new").length;
        const before = starts();
        await ctx.press("Enter");
        await ctx.waitFor(() => !!ctx.document.body.textContent?.includes("changes cmux on this computer"));
        if (starts() > before) throw new Error("/customize started a chat on another machine");
      },
    },
    empty: {
      note: "No chats yet. A harness is installed, so the chip names its model and nothing on the page offers Add harness.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-chats-empty") !== null);
        if (ctx.document.querySelector(".nt-no-agent, .acpmux-add-harness"))
          throw new Error("Add harness shows on the page with a harness installed");
      },
    },
    "chats-loading": {
      note: "The first session list is pending: recent chats use placeholders until it settles.",
      ready: newTab(),
      snapshot: noChat(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-cards[aria-busy=true]") !== null);
      },
    },
    // New Project (Leo, 2026-11-08): the folder menu's New project row makes a new folder with an
    // empty git repository for the chat; the strip names it, from the prompt until the person types one.
    "new-project-chosen": {
      note: "New project just chosen, prompt empty: the strip reads New project / project (the placeholder name until a prompt names one).",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await chooseNewProject(ctx);
        if (projectNameValue(ctx) !== "project") throw new Error("an empty prompt's project is not named project");
        if (!ctx.document.querySelector(".nt-location")?.textContent?.includes("New project"))
          throw new Error("the strip does not read New project");
      },
    },
    "new-project-derived": {
      note: 'New project with a prompt typed: "a habit tracker web app" names the folder habit-tracker in the strip, the kind words dropped.',
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await chooseNewProject(ctx);
        await typePrompt(ctx, "a habit tracker web app");
        await ctx.waitFor(() => projectNameValue(ctx) === "habit-tracker");
      },
    },
    "new-project-long-name-narrow": {
      note: "New project in a 300 px pane with a long name the person typed: the name field gives up width before the folder control and ends in an ellipsis; nothing leaves the strip.",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await chooseNewProject(ctx);
        ctx.document.body.style.maxWidth = "300px";
        await typePrompt(ctx, "Build me a recipe box that imports recipes from photos");
        await ctx.waitFor(() => projectNameValue(ctx) === "recipe-box");
        await ctx.focus({ selector: ".nt-project-name__field" });
        ctx.document.querySelector<HTMLInputElement>(".nt-project-name__field")?.select();
        await ctx.type("Family Recipe Box With Photo Import And Weekly Meal Plans");
        await ctx.waitFor(() => projectNameValue(ctx) === "family-recipe-box-with-photo-import-and-weekly-meal-plans");
        // Return hands the keyboard back to the prompt, so the capture shows the name at rest.
        await ctx.press("Enter");
        const strip = ctx.document.querySelector(".acpmux-composer-context")?.getBoundingClientRect();
        const name = ctx.document.querySelector(".nt-project-name__field")?.getBoundingClientRect();
        if (!strip || !name || name.width <= 0) throw new Error("the project name field is not drawn");
        if (name.right > strip.right + 0.5) throw new Error("the project name runs out of the strip");
      },
    },
    "new-project-refused": {
      note: "New project refused: acpmux made no folder, so the reason shows above the card with Dismiss, no chat starts and the prompt stays.",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await chooseNewProject(ctx);
        await typePrompt(ctx, "a habit tracker web app");
        await ctx.waitFor(() => projectNameValue(ctx) === "habit-tracker");
        // The gallery's acpmux has no `_acpmux/project_new`, so the pane refuses as an older one does.
        await ctx.press("Enter");
        await ctx.waitFor(
          () => !!ctx.document.querySelector('[role="alert"]')?.textContent?.includes("Couldn’t make the project"),
        );
        if (galleryNativeCalls(ctx.document).some((call) => call.method === "chat.new"))
          throw new Error("a refused New project started a chat");
      },
    },
    "inherited-project": {
      note: "A fresh workspace inherits its last project: the machine/project controls keep their established slots and the inherited project stays selected without requiring a new pick.",
      ready: newTab({ template: "minimal", cwd: "/Users/you", startedProject: CWD, projects: [CWD] }),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        const location = ctx.document.querySelector<HTMLElement>(".nt-location");
        const project = ctx.document.querySelector<HTMLElement>(
          ".nt-location .acpmux-location-leading > .acpmux-location-picker:first-child button",
        );
        if (!location || !project || !project.textContent?.includes("atlas-web"))
          throw new Error("the inherited project is not shown in the established location slot");
        const before = project.getBoundingClientRect();
        if (before.width <= 0 || before.height <= 0) throw new Error("the location slot is not mounted");
        await typePrompt(ctx, "keep this project");
        await ctx.waitFor(() => !(ctx.document.querySelector<HTMLButtonElement>(".nt-send")?.disabled ?? true));
        const after = project.getBoundingClientRect();
        if (Math.abs(after.left - before.left) > 1 || Math.abs(after.top - before.top) > 1)
          throw new Error("the inherited location slot moved after input");
      },
    },
    // The model button opens its columns menu, whole: the card does not clip it (Lawrence
    // 2026-10-13). Points near its top and bottom edges hit the menu, not the page. The models
    // column ends on its Legacy models, with no caption; Add harness… ends the rail.
    "computer-first-setup": {
      note: "Fresh home with Labs off and only Studio Mac: the machine menu lists This Mac and Cloud (signed out, with Sign in for Cloud); Add Machine… and New Cloud Machine… are its right-click menu.",
      ready: { ...newTab(), machineName: "Studio Mac" },
      snapshot: noChat(),
      native: { "cloudMachine.list": { signedIn: false, loaded: true, machines: [] } },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.click({ selector: '.nt-location .acpmux-location-picker[data-kind="computer"] button' });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-location-menu [role="option"]'));
      },
    },
    "machines-fleet": {
      note: "Machines… (the machine chip's right-click menu) with 21 machines acpmux lists (`host ls`): every one, This Mac first; in each group the ones a chat can start on first, in number order, the rest greyed with their state and no pick; the four acpmux cannot reach wait under a closed Unavailable (4) row.",
      ready: newTab(),
      snapshot: noChat([], { ...fleetPeers(), listedSessions: true }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await openMachineList(ctx);
        await ctx.waitFor(() => ctx.document.querySelectorAll('.acpmux-env-popover [role="option"]').length > 17);
      },
    },
    "model-picker-open": {
      note: "The New Tab model button's columns, open down: the harness rail and the models, never cut by the card; Legacy models follow the top ones with no caption, and the rail ends on Add harness….",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        await ctx.click({ role: "button", name: "Model" });
        await ctx.waitFor(() => {
          const menu = ctx.document.querySelector<HTMLElement>(".acpmux-cols");
          if (!menu || !menu.querySelector('[role="listbox"] [role="option"]')) return false;
          const box = menu.getBoundingClientRect();
          if (box.height < 120) return false;
          const x = box.left + box.width / 2;
          return [box.top + 6, box.bottom - 6].every((y) => menu.contains(ctx.document.elementFromPoint(x, y)));
        });
        const models = ctx.find({ selector: '.acpmux-cols [role="listbox"]' });
        if (models.querySelector(".acpmux-cols-caption"))
          throw new Error("the models column must be one plain list: no tab or Legacy models caption");
        if (models.querySelector('[aria-label="Add harness…"]'))
          throw new Error("the models column must contain models only; Add harness belongs in the rail");
        const rail = ctx.find({ selector: '.acpmux-cols [role="tablist"]' });
        if (rail.lastElementChild?.getAttribute("aria-label") !== "Add harness…")
          throw new Error("the model menu's harness rail must end on Add harness…");
      },
    },
    // The effort is part of the one model button (Leo 2026-10-20: "Opus 5.5  Medium"), and its
    // levels are the menu's Effort column (P0 #8: a live pick, never a picture): acpmux starts
    // Claude Code on Medium, so the button names it before any chat exists.
    "reasoning-chip": {
      note: "Before any chat: the model button names the model and the level acpmux starts Claude Code on (Medium); its menu's Effort column lists the levels. No separate Reasoning chip.",
      ready: newTab(),
      snapshot: reasoningChat(),
    },
    "catalog-fast-menu": {
      note: "Before a session reports config options: the New Tab model menu offers the model's catalog Fast mode under Effort, as a started chat does.",
      ready: newTab(),
      snapshot: reasoningChat(),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(MODEL_PICKER) !== null);
        await ctx.click({ selector: MODEL_PICKER });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-cols-tune [role="switch"]') !== null);
      },
    },
    "reasoning-chip-stage": {
      note: "The Default template's stage layout before any chat: its own composer at the foot of the page, the one model button (model and effort) in the box, text at rest, the soft pill only on the hovered control.",
      ready: newTab({ template: "default" }),
      snapshot: reasoningChat(),
    },
    // Minimal opens with the composer, without fixed creation buttons, a greeting or widgets.
    // `minimal-default` is a host that sends no template (the app's unset key).
    "wrap-one-line": {
      note: "One character before wrapping, with the typing caret at the end and suggestions below the box.",
      ready: newTab({ template: "minimal", location: "Check composer wrapping" }),
      snapshot: noChat(manySessions(3)),
      play: (ctx) => wrapPrompt(ctx, false),
    },
    "wrap-two-lines": {
      note: "One character after wrapping, with the same first line and controls, and the caret on the new line.",
      ready: newTab({ template: "minimal", location: "Check composer wrapping" }),
      snapshot: noChat(manySessions(3)),
      play: (ctx) => wrapPrompt(ctx, true),
    },
    "minimal-default": {
      note: "Minimal, New Tab's default layout: the composer and its chips, without fixed creation buttons, a look switcher, greeting or widgets.",
      ready: newTab({ template: undefined }),
      snapshot: noChat(manySessions(12)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        if (ctx.document.querySelector('.nt-screen[data-template="default"]'))
          throw new Error("an unset NewTabScreen template still renders the Default stage");
        if (!ctx.document.querySelector('.nt-screen[data-template="minimal"]'))
          throw new Error("an unset NewTabScreen template did not render Minimal");
        const extra = ctx.document.querySelector(".nt-greeting, .nt-stage, .nt-cards");
        if (extra) throw new Error(`the minimal page shows ${extra.className}`);
        if (ctx.document.querySelector(".nt-style")) throw new Error("the minimal page shows a look switcher");
        if (ctx.document.querySelector(".nt-composer[data-composer-look]"))
          throw new Error("the minimal page did not keep Claude's look");
        noFixedCreateButtons(ctx);
      },
    },
    "minimal-saved-codex-create": {
      composerLook: "codex",
      note: "A saved Codex preference keeps Claude Minimal without fixed creation buttons.",
      ready: newTab({ template: "minimal" }),
      snapshot: reasoningChat(),
    },
    "minimal-create-narrow": {
      composerLook: "claude",
      note: "Claude Minimal in a narrow pane: a matching creation command appears in the composer suggestions.",
      ready: newTab({ template: "minimal" }),
      snapshot: reasoningChat(),
      play: async (ctx: PlayContext) => {
        ctx.document.body.style.maxWidth = "300px";
        await typedSuggestions(ctx, translateNewTab("create.browser"), (rows) =>
          rows.some((row) => row.type === "create") ? undefined : "the browser creation command is missing",
        );
        noFixedCreateButtons(ctx);
      },
    },
    "fix-from-link": {
      note: "A lone GitHub issue URL leaves the normal composer intact and offers the explicit Fix in a new worktree action beneath it.",
      ready: newTab({
        template: "minimal",
        location: "https://github.com/manaflow-ai/cmux/issues/38426",
        projects: [CWD],
      }),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-fix-chip") !== null);
        if (ctx.document.querySelector(".nt-fix-error")) throw new Error("the idle fix action shows an error");
      },
    },
    "fix-from-link-stage": {
      note: "The same explicit issue action in the optional stage layout; the default minimal layout keeps the focus on the pasted report.",
      ready: newTab({
        template: "default",
        location: "https://github.com/manaflow-ai/cmux/issues/38426",
        projects: [CWD],
      }),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-fix-chip") !== null);
      },
    },
    "fix-from-link-error": {
      note: "When checkout discovery fails, the Fix in a new worktree action stays in place and reports the host error inline beside the composer.",
      ready: newTab({
        template: "minimal",
        location: "https://github.com/manaflow-ai/cmux/issues/38426",
        projects: [CWD],
      }),
      snapshot: noChat(manySessions(3), { listedSessions: true }),
      native: {
        "chat.fix_from_link": {
          nativeError: {
            code: "fix.checkout_missing",
            userMessage: "No local checkout found; choose its folder or clone it first.",
          },
        },
      },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector<HTMLButtonElement>(".nt-fix-chip") !== null);
        await ctx.click({ selector: ".nt-fix-chip" });
        await ctx.waitFor(() => ctx.document.querySelector(".nt-fix-error[role=alert]") !== null);
      },
    },
    "layout-codex-tabs-above": {
      note: "Minimal keeps project, machine and model controls below the composer, with a free Fast bolt in the model picker.",
      ready: newTab({ template: "minimal" }),
      snapshot: noChat(manySessions(12)),
    },
    "layout-claude-chips-below": {
      composerLook: "claude",
      note: "Claude-style comparison: the composer stays spacious while project, machine, permission and model controls sit in the quiet row below it; paid Fast remains in the model menu.",
      ready: newTab({ template: "default" }),
      snapshot: noChat(manySessions(12)),
    },
    // The New Tab composer's states, as the chat composer's (agent-pane.composer composer-*): the
    // same chips, pills, caret and rim (test/composer-caret-focus.test.ts).
    ...Object.fromEntries(
      Object.entries(composerStatePlays(".nt-field [contenteditable=true]")).map(([state, variant]) => [
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
          composerLook: "claude",
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
      snapshot: noChat([], { listedSessions: true }),
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
      note: "The New Tab composer keeps the chat composer's leading + attachment control: opening it exposes the same Attach option, then Search chats and Search pages, without moving the field.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.waitFor(
          () => ctx.document.querySelector(".nt-composer .acpmux-newtab-plus .acpmux-picker-button") !== null,
        );
        await ctx.click({ selector: ".acpmux-newtab-plus .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-newtab-plus [data-value="add.files"]') !== null);
        const input = ctx.document.querySelector<HTMLInputElement>(".nt-composer .acpmux-attach-input");
        if (!input || !input.multiple) throw new Error("the New Tab attachment chooser is missing or single-file");
        // The ChatGPT-style + searches (Search chats, Search pages); the page has no Search files.
        for (const id of ["agentPane.searchChats", "history.search"])
          if (!ctx.document.querySelector(`.acpmux-newtab-plus [data-value="${id}"]`))
            throw new Error(`the New Tab + lost ${id}`);
        if (ctx.document.querySelector('.acpmux-newtab-plus [data-value="files.search"]'))
          throw new Error("the New Tab + offers Search files, which it cannot run");
      },
    },
    // Leo, 2026-10-31: "our + button is ass" / "inside chat and in the composer it's ass". New Tab's
    // + is the chat composer's (ComposerPlusMenu): it opens over the project and machine pills above
    // the box, and its glass hides them (it draws outside the box's backdrop root).
    "attachment-menu-pills": {
      note: "Play: open New Tab's +: Attach files or images, then Search chats and Search pages, each title and its muted hint on one line, over the project and machine pills, which do not show through.",
      ready: newTab({ template: undefined }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-composer .acpmux-newtab-plus .acpmux-picker-button"));
        await ctx.click({ selector: ".acpmux-newtab-plus .acpmux-picker-button" });
        // test/composer-plus-menu-shape.browser.test.ts holds the shape (one-line rows, no header band,
        // the pills covered); the play only opens it, so the same state draws the menu before the fix.
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-newtab-plus [data-value="history.search"]'));
      },
    },
    "stage-layout": {
      note: "The Default template's layout (Leo 2026-10-19, Claude Code desktop's new-session screen): the composer at the foot with the plain footer (folder and mode left, model and effort right); over it, centered, the environment card (this project checked, the other projects, Choose environment) and the suggested actions card (the chats that need you); the recent chats under them.",
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
      snapshot: { ...noChat([], { listedSessions: true }), catalog: [] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-composer .acpmux-add-harness") !== null);
        if (ctx.document.querySelector(".nt-no-agent")) throw new Error("a No agent to ask line shows under the field");
        const chip = ctx.document.querySelector(".nt-composer .acpmux-add-harness")!.getBoundingClientRect();
        if (chip.height > 32) throw new Error(`the Add harness chip is ${chip.height}px tall, not one chip`);
      },
    },
    "typed-over-note": {
      note: "Suggestions keep the composer's tint, blur, rim and shadow without fixed creation controls.",
      ready: { ...newTab(), transport: "mock" },
      mockHarnesses: [],
      snapshot: { ...noChat([], { listedSessions: true }), catalog: [] },
      play: async (ctx) => {
        await typePrompt(ctx, "fix the flaky upload test");
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover .nt-row") !== null);
        checkSuggestionSurface(ctx);
        noFixedCreateButtons(ctx);
      },
    },
    "harnesses-from-menu": {
      note: "Play: Integrate a Harness… from the palette or the File menu on this page (cx-9fqw) shows the Harnesses page here, in place, not in a second tab.",
      ready: newTab(),
      snapshot: noChat([], { listedSessions: true }),
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
        await ctx.scroll({ selector: ".nt-screen" }, "bottom");
        if ((ctx.document.querySelector(".nt-screen")?.scrollTop ?? 0) === 0) throw new Error("New Tab did not scroll");
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
      note: "A typed instruction: Ask first (Return's, highlighted), then a web search in the popover. Unrelated creation commands stay hidden; the cards stay where they were.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "fix the flaky upload test");
      },
    },
    "typed-hover": {
      note: '"helo" typed, the pointer resting on the web search suggestion. Ask Claude Code keeps Return\'s highlight, so Return sends the prompt.',
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "helo");
        await ctx.hover({ selector: '.nt-row[data-type="search"]' });
      },
    },
    "typed-hover-return": {
      note: 'The same, then Return: the page asks Claude Code with "helo" (chat.new), never opens the hovered web search.',
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "helo");
        await ctx.hover({ selector: '.nt-row[data-type="search"]' });
        await ctx.press("Enter");
        // Ends on the unpatched base too (it opens the browser tab, and the state fails there).
        await ctx.waitFor(() =>
          galleryNativeCalls(ctx.document).some((call) => call.method === "chat.new" || call.method === "tab.open"),
        );
        if (galleryNativeCalls(ctx.document).some((call) => call.method === "tab.open"))
          throw new Error("Return opened the hovered row instead of asking the agent");
      },
    },
    "typed-keywords": {
      note: 'Leo 2026-10-20 (no Search | Ask switch) and 2026-10-24 ("Search the web. Do you really want that first?"): plain keywords. Ask Claude Code leads (Return\'s, highlighted), the web search is the last row.',
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "rust serde");
        await ctx.waitFor(() => ctx.document.querySelector('#nt-row-0[data-type="ask"][aria-selected="true"]'));
      },
    },
    "typed-question": {
      note: "A question: Ask Claude Code leads (Return's, highlighted), the web search one row down.",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "why does the upload test flake?");
        await ctx.waitFor(() => ctx.document.querySelector('#nt-row-0[data-type="ask"][aria-selected="true"]'));
      },
    },
    "typed-tab-match-stage": {
      note: "The Default template's stage layout with text that matches open tabs: the composer at the foot, so the rows open above it (popup-escape).",
      ready: newTab({ template: "default", omnibar: RELEASE_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
    },
    "typed-tab-match": {
      note: "Text that matches open tabs, workspaces and visited pages: the Release workspace first (its exact name, Return's), Ask, then those rows (with their favicons, a glyph while one loads) and the web search in the popover; Down to the last row scrolls to it (dogfood 2026-10-08).",
      ready: newTab({
        omnibar: RELEASE_OMNIBAR,
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "release");
        await ctx.waitFor(() => ctx.document.querySelector(".nt-rows"));
        // The workspace, Ask, then the first tab. Wrap from the last suggestion to that tab.
        const options = ctx.document.querySelectorAll('.nt-popover [role="option"]').length;
        for (let step = 0; step < options - 1; step++) await ctx.press("ArrowDown");
        for (let step = 0; step < 3; step++) await ctx.press("ArrowDown");
        await ctx.press("Enter");
        await waitForTabJump(ctx, "tab", "tab-1");
      },
    },
    "suggestions-overflow": {
      note: "Matching open tabs fill the capped suggestions list in a short pane, with soft scroll edges.",
      ready: newTab({
        suggestionOrder: "chat",
        omnibar: {
          ...RELEASE_OMNIBAR,
          tabs: Array.from({ length: 20 }, (_, index) => ({
            id: `release-${index}`,
            kind: "terminal" as const,
            title: `Release build ${index}`,
            detail: "~/src/release",
          })),
        },
      }),
      snapshot: noChat([]),
      play: async (ctx) => {
        await typePrompt(ctx, "release");
        await ctx.waitFor(() => ctx.document.querySelectorAll('.nt-rows [role="option"]').length >= 6);
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
        await typePrompt(ctx, "Release");
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
        await typePrompt(ctx, "reddit");
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
        await typePrompt(ctx, "red");
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
        await typePrompt(ctx, "reddit");
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover"));
        await ctx.click({ selector: ".nt-screen" });
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector(".nt-popover") &&
            ctx.document.querySelector<MarkdownFieldElement>(".nt-field")?.acpmuxMarkdownField?.plainText() ===
              "reddit",
        );
      },
    },
    "typed-address": {
      note: "An address: open it first (highlighted), then a web search and Ask.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "localhost:3000");
        await ctx.waitFor(() => ctx.document.querySelector(".nt-rows"));
      },
    },
    "create-strip-narrow": {
      note: "An address in the composer shows navigation matches without fixed creation buttons or unrelated creation commands.",
      ready: newTab(),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typePrompt(ctx, "localhost:3000");
        await ctx.waitFor(() => ctx.document.querySelector(".nt-popover"));
        noFixedCreateButtons(ctx);
        if (ctx.document.querySelector('.nt-popover [data-type="create"]'))
          throw new Error("an unrelated creation command appears for an address");
      },
    },
    "suggestions-ff": {
      note: "Suggestions use the composer's surface. Ask comes first, web search last, and unrelated creation commands stay hidden.",
      ready: newTab({ omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", ffProblem);
        checkSuggestionSurface(ctx);
        noFixedCreateButtons(ctx);
      },
    },
    "suggestions-spacing": {
      note: "The chip text has equal space above and below it between the box and suggestions.",
      ready: newTab({ template: "minimal", omnibar: FF_OMNIBAR }),
      snapshot: reasoningChat(),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", ffProblem);
      },
    },
    "suggestions-spacing-stage": {
      note: "The stage suggestions still open above the whole composer.",
      ready: newTab({ template: "default", omnibar: FF_OMNIBAR }),
      snapshot: reasoningChat(),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", ffProblem);
      },
    },
    "omnibar-start-agent": {
      note: 'Lawrence 2026-11-13 ("launch claude code/codex/opencode in certain directories"): "codex cmux" leads with Codex in each cmux folder, above Ask; Return starts Codex there.',
      ready: newTab({ omnibar: FF_OMNIBAR, projects: WIDGET_PROJECTS }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "codex cmux", (rows) =>
          rows[0]?.type === "launch" && rows[0].title.startsWith("Codex") ? undefined : "Codex does not lead",
        );
      },
    },
    "omnibar-sections": {
      note: "Matches keep their ranking with no section headings. Chat details show only the agent name, even for a long folder path.",
      native: { "chats.page": { ready: true, design: "age", chats: [] } },
      ready: newTab({
        omnibar: {
          ...FF_OMNIBAR,
          history: [{ url: "https://github.com/manaflow-ai/cmux", title: "manaflow-ai/cmux: the terminal for agents" }],
        },
        projects: WIDGET_PROJECTS,
      }),
      snapshot: noChat([
        session({
          sessionId: "chat-claude",
          displayTitle: "cmux suggestions",
          harness: "claude",
          cwd: "/Users/you/Developer/cmux/cmuxterm-hq/worktrees/newtab-suggestions",
        }),
        session({
          sessionId: "chat-codex",
          displayTitle: "cmux ranking",
          harness: "codex",
          cwd: "/Users/you/Developer/cmux/cmuxterm-hq/worktrees/omnibar-ranking",
        }),
      ]),
      play: async (ctx) => {
        await typedSuggestions(ctx, "cmux", (rows) =>
          rows.some((row) => row.type === "chat") && rows.some((row) => row.type === "launch")
            ? undefined
            : "no chat or start rows",
        );
        const details = [...ctx.document.querySelectorAll('.nt-row[data-type="chat"] .nt-row-detail')].map(
          (detail) => detail.textContent,
        );
        if (details.length !== 2 || !details.includes("Claude Code") || !details.includes("Codex"))
          throw new Error("chat details must show only the agent name");
        if (ctx.document.querySelector(".nt-popover .nt-section")) throw new Error("section headings still show");
      },
    },
    "omnibar-folder-complete": {
      note: "A typed path completes from the folder's subfolders (folder.complete, asked once the field stays still); Tab fills the folder in.",
      ready: newTab({ omnibar: FF_OMNIBAR, projects: WIDGET_PROJECTS }),
      snapshot: noChat(manySessions(3)),
      native: { "chats.page": allChatsPage, "folder.complete": { folders: ["cmux", "cmux-web", "manaflow", "notes"] } },
      play: async (ctx) => {
        await typedSuggestions(ctx, "claude ~/src/", (rows) =>
          rows.filter((row) => row.type === "launch").length >= 2 ? undefined : "no folder rows",
        );
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
      note: "Commands keep their icons and shortcuts without group labels. Ask logos match the outline icons beside them.",
      ready: newTab({
        omnibar: {
          ...FF_OMNIBAR,
          actions: [
            {
              id: "palette.toggleTerminalChat",
              title: "Toggle Terminal and Chat",
              detail: "Panes",
              keywords: ["toggle", "panes"],
              symbol: "arrow.left.arrow.right",
              keycaps: ["⌃", "`"],
            },
            {
              id: "toggleSidebar",
              title: "Toggle Left Sidebar",
              detail: "Sidebar",
              keywords: ["toggle", "sidebar"],
              symbol: "sidebar.left",
              keycaps: ["⌘", "B"],
            },
            {
              id: "toggleTerminalCopyMode",
              title: "Toggle Copy Mode",
              detail: "Terminal",
              keywords: ["toggle", "terminal"],
              symbol: "character.cursor.ibeam",
            },
          ],
        },
      }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "toggle", (rows) =>
          rows.some((row) => row.type === "action") ? undefined : "no commands",
        );
        if (ctx.document.querySelectorAll(".nt-row-shortcut").length !== 2)
          throw new Error("command shortcuts are missing");
        if (ctx.document.querySelector('.nt-row[data-type="action"] .nt-row-detail'))
          throw new Error("command group labels still show");
        if (!ctx.document.querySelector('.nt-row[data-type="ask"] .nt-row-detail')?.textContent)
          throw new Error("Ask model is missing");
        if (ctx.document.querySelector(".nt-section, .nt-popover .nt-row-action"))
          throw new Error("suggestion labels still show");
      },
    },
    "suggestions-chat-ff": {
      note: "Chat order asks first and keeps web search last. Create actions stay outside suggestions.",
      ready: newTab({ suggestionOrder: "chat", omnibar: FF_OMNIBAR }),
      snapshot: noChat(manySessions(3)),
      play: async (ctx) => {
        await typedSuggestions(ctx, "ff", (rows) => {
          const types = navigationTypes(rows);
          if (types[0] !== "ask") return "the first row is not Ask";
          if (types.at(-1) !== "search") return "the web search is not last";
          if (rows.some((row) => row.type === "create")) return "create actions are suggestions";
          return undefined;
        });
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
        await typePrompt(ctx, "rust serde");
        await ctx.waitFor(() => ctx.document.querySelector('#nt-row-0[data-type="ask"]'));
      },
    },
    "template-composer": {
      note: "Legacy Composer template id: saved input is migrated to Minimal, whose shared composer remains the one visible style.",
      ready: newTab({ template: "composer" }),
      snapshot: noChat(manySessions(4)),
      play: async (ctx: PlayContext) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field") !== null);
        if (ctx.document.querySelector('.nt-screen[data-template="composer"]'))
          throw new Error("legacy Composer id still renders the retired template");
        if (!ctx.document.querySelector('.nt-screen[data-template="minimal"]'))
          throw new Error("legacy Composer id did not migrate to Minimal");
        if (ctx.document.querySelector('[data-style="composer"]'))
          throw new Error("legacy Composer id is still selectable");
      },
    },
    "composer-holds-its-place": {
      note: "After typing, a pasted image and Now Playing: the composer and the typed text are where the empty page drew them; the image sits under the text (Leo 2026-10-19: the composer kept moving).",
      ready: newTab({ projects: [CWD] }),
      snapshot: noChat(manySessions(3)),
      play: holdsItsPlace,
    },
    "composer-template-holds-its-place": {
      note: "Legacy Composer input after typing, a pasted image and Now Playing: migration keeps the shared Minimal composer in place.",
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
