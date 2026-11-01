// l10n-allow-file: gallery fixtures (sample drafts and chats), not shipped UI.
// The composer's states (Composer.tsx, ComposerPickers.tsx, ComposerContext.tsx: the prompt,
// the mode and model chips, the location row, Send and Stop), through the pane's own inputs: the
// `ready` answer's draft and new-chat fields, and the snapshot.
import { agentPaneEntry, type AgentPaneVariant } from "../../gallery/format";
import { minutesAgo } from "../../gallery/clock";
import {
  assistant,
  CATALOG,
  chat,
  CWD,
  noChat,
  session,
  SESSION_ID,
  summary,
  user,
} from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { MarkdownFieldElement } from "./MarkdownField";
import type { AcpmuxSnapshot } from "./model";
import type { SessionPullRequest } from "./sessionList";
import { composerStatePlays } from "./composerStatePlays";
import { SCREEN_RECORDING_POSTER_JPEG } from "../../gallery/fixtures/videoPoster";

/// A screen recording on the Desktop, as the host's `video.info` reads it (AgentPaneVideoInfo.swift).
const VIDEO_PATH = "/Users/dev/Desktop/Screen Recording 2026-10-25 at 10.42.13.mov";
const VIDEO_INFO = {
  durationMs: 42_400,
  width: 1920,
  height: 1080,
  poster: `data:image/jpeg;base64,${SCREEN_RECORDING_POSTER_JPEG}`,
  frames: [5300, 15900, 26500, 37100].map((atMs) => ({ atMs, data: SCREEN_RECORDING_POSTER_JPEG })),
};

/// Drops a screenshot and the screen recording on the composer, as Finder does (Leo's capture).
function dropScreenshotAndVideo(ctx: PlayContext) {
  const view = ctx.document.defaultView!;
  const png = Uint8Array.from(
    atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="),
    (char) => char.charCodeAt(0),
  );
  const files = [
    new view.File([png], "Screenshot.png", { type: "image/png" }),
    new view.File([new Uint8Array([0, 0, 0, 0x14, 0x66, 0x74, 0x79, 0x70])], VIDEO_PATH.split("/").pop()!, {
      type: "video/quicktime",
    }),
  ];
  const drop = new view.Event("drop", { bubbles: true, cancelable: true });
  Object.defineProperty(drop, "dataTransfer", { value: { files, types: ["Files"] } });
  ctx.find({ selector: ".acpmux-md" }).dispatchEvent(drop);
}

// Claude desktop's box (Leo 2026-10-20): no Send until there is a draft, then Send comes in after the
// mic, which moves one slot left. The plays that start a draft from an empty prompt measure that move.
const SEND_ARRIVES = {
  layoutShiftMax: {
    value: 0.003,
    reason:
      "Send comes in after the mic with the draft's first letter, moving the mic one slot left. Clean Linux Chromium runs measure 0.0026 for this intentional one-slot move; 0.003 leaves only rounding headroom.",
  },
};

/// The one model button (Leo 2026-10-20: "Opus 5.5  Medium"): it names the model and its effort and
/// opens the one menu, whose Effort row opens the levels beside it.
const MODEL_BUTTON = { selector: ".acpmux-model .acpmux-picker-button" };
const MODEL_DETAIL = ".acpmux-model .acpmux-model-detail:not(.acpmux-fit-label)";

async function openModelMenu(ctx: PlayContext) {
  await ctx.click(MODEL_BUTTON);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-quick-menu [role="menuitemradio"]'));
}

/// Opens the model menu, then its Effort submenu; resolves with the submenu's popup.
async function openEffortMenu(ctx: PlayContext): Promise<HTMLElement> {
  await openModelMenu(ctx);
  return openEffortSubmenu(ctx);
}

/// With the model menu open, resolves with the current model's effort levels: its side dropdown
/// beside the running row (#27948) when the row has one, else the Effort submenu, opened (pressing
/// the model button again would close the menu).
async function openEffortSubmenu(ctx: PlayContext): Promise<HTMLElement> {
  const RUNNING = ".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger";
  const side = () => ctx.document.querySelector<HTMLElement>(RUNNING) ?? undefined;
  const row = () =>
    [...ctx.document.querySelectorAll<HTMLElement>('.acpmux-quick-menu [role="menuitem"]')].find((item) =>
      item.textContent?.trim().startsWith("Effort"),
    );
  await ctx.waitFor(() => side() ?? row());
  if (side()) {
    await ctx.focus({ selector: RUNNING });
    await ctx.press("ArrowRight");
    let dropdown: HTMLElement | undefined;
    await ctx.waitFor(() => {
      dropdown = ctx.document.querySelector<HTMLElement>(".acpmux-quick-effort-menu") ?? undefined;
      return dropdown;
    });
    return dropdown!;
  }
  // A submenu row opens on hover or from the keyboard: Base UI's submenu trigger ignores a mouse
  // press while it opens on hover. Enter on the focused row opens it, as a keyboard user does.
  await ctx.focus({ role: "menuitem", name: /^Effort/ });
  await ctx.press("Enter");
  let levels: HTMLElement | undefined;
  await ctx.waitFor(() => {
    levels = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu")].find(
      // The submenu is the quick menu with no submenu rows of its own (the main one has Effort's).
      (menu) => !menu.querySelector(".acpmux-quick-sub") && menu.querySelector('[role="menuitemradio"]') !== null,
    );
    return levels;
  });
  return levels!;
}

const working = [user("Add retries", 1), assistant("Reading the helper…", 0.5, { streaming: true })];
const historyPageB = user("B: update the retry helper", 6);
const historyPageC = user("C: add the 429 test", 3);
const historyPageRows = [
  historyPageB,
  assistant("Updated the helper.", 5),
  historyPageC,
  assistant("Added the test.", 2),
];
const historyPageOlderRows = [
  user("A: inspect the backoff path", 9),
  assistant("Inspected the path.", 8),
  ...historyPageRows,
];
// Three prompts waiting for the running turn.
const waiting = [
  { id: "q1", prompt: "Then add a test for the 429 path" },
  { id: "q2", prompt: "And update the README" },
  { id: "q3", prompt: "Run the whole suite" },
];

// A screenshot-like picture (a title bar, a sidebar and lines of text) in `hue`, as a data URL, so
// a queued prompt's thumbnails draw without acpmux.
const shot = (hue: number, width = 1440, height = 900) =>
  `data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">` +
      `<rect width="100%" height="100%" fill="hsl(${hue} 30% 16%)"/>` +
      `<rect width="100%" height="7%" fill="hsl(${hue} 30% 26%)"/>` +
      `<rect width="22%" height="100%" fill="hsl(${hue} 30% 24%)"/>` +
      [0, 1, 2, 3, 4, 5]
        .map(
          (line) =>
            `<rect x="27%" y="${14 + line * 11}%" width="${30 + ((line * 37) % 40)}%" height="3%" fill="hsl(${hue} 70% 62%)"/>`,
        )
        .join("") +
      "</svg>",
  )}`;
// Another agent's message waiting behind the turn (Leo, 2026-10-21: it drew as the person's prompt).
const QUEUED_MESSAGE =
  "**Rebase onto #23738** before you push: it moves the queue rows.\n\n- `ComposerQueue.tsx` changes\n- the gallery cases too";
const QUEUED_LANE_REPORT = [
  "**cx3-s71-jank · lane report**",
  "",
  "| case | PR | result |",
  "|---|---:|---|",
  "| queue | [#24772](https://github.com/manaflow-ai/cmux/pull/24772) | green |",
  "| transcript | [compare](https://cmux.com/compare/agent-message-style) | review |",
  "",
  "See [https://github.com/manaflow-ai/cmux/actions](https://github.com/manaflow-ai/cmux/actions) for the run.",
  "Commit 4c656ea8f42e3d1b9a7c0e6f5d4c3b2a19081716 is the current head.",
  "The queued report keeps the table readable and shows its sender above the bubble.",
].join("\n");
// A prompt queued with two screenshots (Leo, 2026-10-21: "do queued messages have pics?").
const pictured = {
  id: "q1",
  prompt: "Why does the sidebar overlap the toolbar here?",
  images: [
    { id: "a".repeat(64), mimeType: "image/svg+xml", name: "sidebar.png", src: shot(220) },
    { id: "b".repeat(64), mimeType: "image/svg+xml", name: "image.png", src: shot(150, 2458, 1180) },
  ],
};

// A turn that took two steers, one the agent read and one it has not yet, and a prompt sent now
// to an agent that cannot steer (it goes on with the turn).
const steerMarks = () =>
  chat(
    [
      user("Add retries", 6),
      user("Use the cache dir, not tmp", 5, { steer: "landed" }),
      assistant("Using the cache dir now.", 4),
      user("Stop and fix the space thing first", 3, { continues: true }),
      assistant("Fixing the space handling…", 2),
      user("Also keep the old flag working", 1, { steer: "waiting", steerPromptId: "p-steer" }),
      assistant("Reading the flag parser…", 0.5, { streaming: true }),
    ],
    { isWorking: true },
  );

// Two steers the agent has not read yet, one after the other: each one's Send now leads its action
// row under the bubble, and the pair is as tall as two prompts.
const waitingSteers = () =>
  chat(
    [
      user("Add retries", 6),
      assistant("Adding retries to the fetch loop…", 3, { streaming: true }),
      user("Use the cache dir, not tmp", 1, { steer: "waiting", steerPromptId: "p-steer-1" }),
      user("Also keep the old flag working", 0.5, { steer: "waiting", steerPromptId: "p-steer-2" }),
    ],
    { isWorking: true },
  );

// One steer Claude has not read yet, in a Claude Code chat under its own family name (Leo's
// claude-sr2): it steers, so Send now and the X lead the steer's action row.
const waitingSteerSr2 = () => {
  const running = chat(
    [
      user("Add retries", 6),
      assistant("Adding retries to the fetch loop…", 3, { streaming: true }),
      user("Also keep the old flag working", 0.5, { steer: "waiting", steerPromptId: "p-steer" }),
    ],
    { isWorking: true },
  );
  return {
    ...running,
    summary: {
      ...running.summary!,
      harness: "claude-sr2",
      family: "claude-sr2",
      steering: true,
      backgroundsWork: true,
    },
  };
};

// A running turn of an agent that steers (Claude Code, Codex) or not (acpmux `steering`).
const steering = (steers: boolean) => {
  const running = chat(working, { isWorking: true });
  return { ...running, summary: { ...running.summary!, steering: steers } };
};

// A new chat in CWD beside a recent chat there with a PR (the suggested prompt's source).
const suggesting = (pr: Pick<SessionPullRequest, "state" | "checks">) =>
  noChat(
    [
      session({
        sessionId: "older",
        title: "Retry failed uploads",
        cwd: CWD,
        updatedAt: Date.now() - 60 * 60 * 1000,
        turnCount: 6,
        pullRequest: { number: 4182, title: "Retry failed uploads with backoff", ...pr } as SessionPullRequest,
      }),
    ],
    { summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" } },
  );

// A chat started without a project lives in cmux's agent home, one UUID folder per chat.
const AGENT_HOME = "/Users/you/Library/Application Support/cmux/agent-home/6b16a112-289d-4467-9675-8e6feee99481";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

// Chips a chat kept from a draft (`chat.draftAttachments.get`, keptAttachments.ts). A paste no longer
// makes these (a PDF or an image the engine cannot draw goes to the session as its file path,
// intakeFiles.ts), but a draft kept from before still brings them back.
const TWO_PAGE_PDF = `%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n2 0 obj << /Type /Page >> endobj\n%%EOF`;
const KEPT_PDF = {
  id: "kept-pdf",
  kind: "document",
  name: "design-notes.pdf",
  mimeType: "application/pdf",
  size: TWO_PAGE_PDF.length,
  data: btoa(TWO_PAGE_PDF),
  pageCount: 2,
};
const KEPT_BROKEN_IMAGE = {
  id: "kept-broken-image",
  kind: "image",
  name: "image.png",
  mimeType: "image/png",
  size: 8,
  data: btoa(String.fromCharCode(0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4)),
};

/// Pastes files into the prompt as the browser does: a paste event whose clipboardData is a real
/// DataTransfer, so the prompt's paste handler can read it (getData) as it reads a person's paste.
function pasteFiles(ctx: PlayContext, files: File[]): void {
  const view = ctx.document.defaultView!;
  const data = new view.DataTransfer();
  for (const file of files) data.items.add(file);
  const paste = new view.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(paste, "clipboardData", { value: data });
  ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
}

// A side session `/btw` opened: the question and its answer, its composer replying in it.
const sideSession = (() => {
  const side = chat(
    [
      user("Why did the retry test flake?", 2),
      assistant("The backoff timer raced the mocked clock: the first retry waited 0 ms.", 1),
    ],
    { title: "Why did the retry test flake?", model: "claude-haiku-4-5" },
  );
  return { ...side, sessions: side.sessions.map((entry) => ({ ...entry, side: true })) };
})();
// A chat beside others, for the @ picker (Leo's Claude desktop screenshot, 2026-10-19): what
// `@proje` finds among chats, folders and the chat folder's files.
function mentionChat() {
  const base = chat(finished);
  return {
    ...base,
    sessions: [
      ...base.sessions,
      session({
        sessionId: "0cfd5322-a913-4e01-b71c-aaf0edfb4de8",
        title: "Resume: projects-70 coordinator (0cfd5322)",
        cwd: "/Users/you/Projects",
        updatedAt: minutesAgo(12),
      }),
      session({
        sessionId: "ccd31935-1f2e-4a5b-8c7d-6e5f4a3b2c1d",
        title: "Resume: parity + mg-lint session (ccd31935)",
        cwd: "/Users/you/code/mg-lint",
        updatedAt: minutesAgo(30),
      }),
      session({ sessionId: "7d1c2b3a-4e5f-4061-8a9b-0c1d2e3f4a5b", title: "Fix the dock", updatedAt: minutesAgo(3) }),
    ],
  };
}
const MENTION_FILES = {
  root: CWD,
  results: [
    { path: "terminal-lab/ios/project.yml", matches: [17, 18, 19, 20, 21] },
    { path: "tools/cmux-backlog/.project-number", matches: [20, 21, 22, 23, 24] },
    { path: "tools/cmux-backlog/sync_project.py", matches: [24, 25, 26, 27, 28] },
    { path: "plans/feat-resume/claude/projects/a5107a2b.jsonl", matches: [25, 26, 27, 28, 29] },
    { path: "cmux-code/python/pyproject.toml", matches: [19, 20, 21, 22, 23] },
    { path: "cmux-lite/CmuxTransport/Sources/JSONValue.swift", matches: [] },
  ],
};

const composerControls = {
  configOptions: [
    {
      id: "thought_level",
      name: "Speed",
      category: "thought_level",
      currentValue: "medium-fast",
      options: [
        { value: "slow", name: "Slow" },
        { value: "medium-fast", name: "Medium Fast" },
        { value: "fast", name: "Fast" },
      ],
    },
  ],
  modes: {
    currentModeId: "bypassPermissions",
    availableModes: [
      { id: "ask", name: "Ask before edits", description: "Review changes before they run" },
      { id: "bypassPermissions", name: "Bypass permissions", description: "Run actions without approval" },
    ],
  },
};

// A Claude chat as Leo's app shows it (2026-10-13): the agent names its model with the vendor
// ("Claude Opus 5.5"), the access mode is the default, nothing used yet, on this Mac.
function footerChat(mode: "default" | "full-access") {
  const base = chat(finished);
  return {
    ...base,
    catalog: CATALOG.map((entry) =>
      entry.id === "claude"
        ? {
            ...entry,
            models: entry.models.map((model) =>
              model.id === "claude-opus-5-5" ? { ...model, name: "Claude Opus 5.5" } : model,
            ),
          }
        : entry,
    ),
    summary: {
      ...base.summary!,
      usage: { used: 0, size: 200_000 },
      modes: {
        currentModeId: mode,
        availableModes: [
          { id: "default", name: "Default", description: "Ask before sensitive actions." },
          { id: "full-access", name: "Full access", description: "Run actions without asking." },
        ],
      },
    },
  };
}

// A chat on a Claude profile acpmux lists under its own id (claude-sr2), its models by id only.
function profileIdsChat() {
  const base = chat(finished, { harness: "claude-sr2" });
  return {
    ...base,
    catalog: [
      ...CATALOG,
      {
        id: "claude-sr2",
        name: "Claude Code (sr2)",
        models: ["claude-opus-5-5", "claude-sonnet-5-5"].map((id) => ({ id, name: id })),
      },
    ],
    summary: {
      ...base.summary!,
      usage: { used: 84_000, size: 200_000 },
      modes: {
        currentModeId: "bypassPermissions",
        availableModes: [
          { id: "default", name: "Default", description: "Ask before sensitive actions." },
          { id: "bypassPermissions", name: "Bypass permissions", description: "Run actions without asking." },
        ],
      },
      configOptions: [
        {
          id: "effort",
          name: "Reasoning",
          category: "thought_level",
          currentValue: "default",
          options: ["default", "low", "medium", "high", "xhigh", "max"].map((value) => ({ value })),
        },
        {
          id: "fast-mode",
          name: "Fast mode",
          category: "model_config",
          currentValue: "off",
          options: [
            { value: "off", name: "Off" },
            { value: "on", name: "On" },
          ],
        },
      ],
    },
  };
}

/// A finished Claude chat that lists `/fast` as Claude Code does, its fast mode option at `fast`.
function fastChat(fast: "on" | "off"): AcpmuxSnapshot {
  const base = chat(finished, {
    commands: [
      { name: "compact", description: "Clear conversation history but keep a summary in context" },
      { name: "fast", description: "Toggle fast mode (Opus 5.5)" },
      { name: "review", description: "Review a pull request" },
    ],
  });
  return {
    ...base,
    summary: {
      ...base.summary!,
      configOptions: [
        {
          id: "fast-mode",
          name: "Fast mode",
          category: "model_config",
          currentValue: fast,
          options: [
            { value: "off", name: "Off" },
            { value: "on", name: "On" },
          ],
        },
      ],
    },
  };
}

// A new chat in a project on `branch`, before its first send.
const onBranch = (branch: string) =>
  noChat([session({ sessionId: "older", title: "An older chat" })], {
    summary: { sessionId: "", cwd: CWD, branch, harness: "claude", model: "claude-opus-5-5", effort: "high" },
  });

/// Claude Code's Ultracode switch, as acpmux's claude_stdio lists it beside the levels.
const CLAUDE_ULTRACODE_OFF = {
  id: "ultracode",
  name: "Ultracode",
  category: "model_config",
  currentValue: "off",
  options: [
    { value: "off", name: "Off" },
    { value: "on", name: "On", description: "Extra High effort plus multi-agent workflow orchestration" },
  ],
};

// The chat font setting reaches the draft as well as the conversation, in either composer.
const fontSizeVariants: Record<string, AgentPaneVariant> = Object.fromEntries(
  [14, 21, 28].flatMap((size) =>
    ["chat", "new-chat", "new-tab"].map((context) => [
      `font-size-${context}-${size}`,
      {
        note: `Chat text at ${size}px, including the draft's headings and code.`,
        display: { "agentPane.display.font.size": size },
        ready: {
          newSession: context !== "chat",
          ...(context === "new-tab"
            ? { newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude" } }
            : {}),
          cwd: CWD,
          draft: "### Review the retry helper\nKeep `fetch` idempotent.\n\n```ts\nawait retry(request)\n```",
        },
        snapshot:
          context !== "chat"
            ? onBranch("main")
            : chat([
                assistant(
                  "# Retry plan\nThe body follows your font size.\n\n| Attempt | Wait |\n|---|---|\n| 1 | 1 second |",
                  1,
                ),
              ]),
      },
    ]),
  ),
);

export default agentPaneEntry({
  id: "agent-pane.composer",
  title: "Composer",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  // The transcript must not move while a play step opens a menu over it, and the composer box
  // must not move when queued prompts come and go above it.
  anchors: [
    { selector: ".acpmux-scroll" },
    { selector: ".acpmux-composer-box" },
    { selector: ".acpmux-composer-context" },
  ],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Footer menus and the capped draft must preserve the transcript and footer geometry.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "The location row is the composer card's footer and must not reflow the transcript.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Composer interactions must stay below one display frame on the gallery host.",
    },
  },
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerBox.tsx#ComposerBox",
    "agent-session/acpmux/ComposerFoot.tsx#ComposerFoot",
    "agent-session/acpmux/conversation/PendingSteer.tsx#PendingSteer",
    "agent-session/acpmux/conversation/icons.tsx#Clock",
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/ComposerPickers.tsx#Picker",
    "agent-session/acpmux/FastToggle.tsx",
    // The `/` menu's Fast row (slash-menu-fast-on, slash-menu-fast-off).
    "agent-session/acpmux/BoltIcon.tsx#BoltIcon",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/composer/PromptEditor.tsx",
    "agent-session/acpmux/MarkdownField.tsx",
    "agent-session/acpmux/EmptyState.tsx",
    "agent-session/acpmux/ComposerQueue.tsx#ComposerQueue",
    "agent-session/acpmux/QueuedImages.tsx#QueuedImages",
    "agent-session/acpmux/MentionMenu.tsx#MentionMenu",
  ],
  variants: {
    ...fontSizeVariants,
    "new-chat": {
      note: "A new chat: empty prompt; the card's footer row holds the folder and computer, under a hairline.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
    },
    "side-session": {
      note: "A side session (/btw) is available by default: the empty prompt reads Reply in this session…, and /btw is not offered in it.",
      snapshot: sideSession,
    },
    // Leo 2026-10-18: an idle new chat suggests the open PR another chat in this checkout made, Tab
    // to take it (promptSuggestion.ts).
    "new-chat-suggest-open": {
      note: "A new chat beside a chat with an open PR: the empty prompt suggests continuing it, with a Tab keycap.",
      ready: { newSession: true, cwd: CWD },
      snapshot: suggesting({ state: "open", checks: "passing" }),
    },
    "new-chat-suggest-failing": {
      note: "The same PR with failing checks: the suggestion is to fix them.",
      ready: { newSession: true, cwd: CWD },
      snapshot: suggesting({ state: "open", checks: "failing" }),
    },
    "new-chat-suggest-draft": {
      note: "A draft PR: the suggestion is to finish it.",
      ready: { newSession: true, cwd: CWD },
      snapshot: suggesting({ state: "draft", checks: "pending" }),
    },
    "new-chat-reasoning": {
      note: "Play: a new chat on a harness no chat has shown here yet names the level acpmux starts it on (Medium) before its session reports, never nothing.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([], {
        catalog: CATALOG.map((entry) =>
          entry.id === "claude" ? { ...entry, start: { model: "claude-opus-5-5", effort: "medium" } } : entry,
        ),
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5" },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.waitFor(() => ctx.document.querySelector(MODEL_DETAIL)?.textContent?.trim() === "Medium");
      },
    },
    "agent-home": {
      note: "A new chat with no project (cmux's agent home): the hero asks what to build, the folder reads Choose folder.",
      ready: { newSession: true, cwd: AGENT_HOME, chooseFolder: true },
      // A new chat's session starts at once (the prewarmed process), so the snapshot and its
      // summary name the same session, as the app's do; the folder control is then the new chat's
      // folder menu (Choose folder…), not the path field.
      snapshot: noChat([], {
        sessionId: "prewarmed",
        summary: {
          sessionId: "prewarmed",
          cwd: AGENT_HOME,
          harness: "claude",
          model: "claude-opus-5-5",
          effort: "high",
        },
      }),
    },
    "agent-home-path": {
      note: "Play: a chat the folder field serves (no folder list from the host): the field reads as a menu row, never a native text box.",
      ready: { newSession: true, cwd: AGENT_HOME, chooseFolder: true },
      snapshot: noChat([], {
        summary: { sessionId: "", cwd: AGENT_HOME, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-search"));
      },
    },
    "agent-home-folders": {
      note: "Play: open the folder menu; it lists real projects, never the agent home's UUID folders.",
      ready: { newSession: true, cwd: AGENT_HOME, chooseFolder: true },
      snapshot: noChat(
        [
          session({ sessionId: "home-chat", title: "A chat with no project", cwd: AGENT_HOME }),
          session({ sessionId: "atlas", title: "Retry the fetch helper" }),
          session({ sessionId: "cmux", title: "Fix the sidebar", cwd: "/Users/you/src/cmux" }),
        ],
        { summary: { sessionId: "", cwd: AGENT_HOME, harness: "claude", model: "claude-opus-5-5", effort: "high" } },
      ),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Folder"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu"));
      },
    },
    "footer-essentials": {
      note: "Leo 2026-10-13, the footer \"tells too much\": the model without its vendor, the mode as its symbol and Claude Code's own name (Manual), no context ring before any use, the folder without this Mac's name. Titles and labels keep the full text.",
      snapshot: footerChat("default"),
    },
    // The location row is a new chat's only (locationRow.ts).
    "footer-essentials-new-chat": {
      note: "A new chat's location row: the folder by name, the computer as the strip draws it.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
    },
    // Leo's nightly (2026-10-20): a Claude chat on a second Claude profile (claude-sr2) whose
    // acpmux list names its models by id, on Claude Code's own level, with fast mode offered. The
    // button names Opus 5.5 and Medium, not "claude-opus-5-5" and "Reasoning".
    "footer-profile-ids": {
      note: "A chat on a second Claude profile whose models carry only their ids, on the agent's default level: the footer names the model by its catalog short name (Opus 5.5) and the level it resolves to (Medium).",
      snapshot: profileIdsChat(),
      play: async (ctx) => {
        const text = (selector: string) => ctx.document.querySelector(selector)?.textContent?.trim() ?? "";
        await ctx.waitFor(() => text(".acpmux-composer-foot .acpmux-model .acpmux-picker-button").includes("Opus 5.5"));
        await ctx.waitFor(() => text(`.acpmux-composer-foot ${MODEL_DETAIL}`) === "Medium");
        await ctx.waitFor(() => !text(".acpmux-composer-foot").includes("claude-opus-5-5"));
        await ctx.waitFor(
          () =>
            ctx.document.querySelector(".acpmux-context-ring")?.getAttribute("aria-label") === "42% of context used",
        );
      },
    },
    "footer-full-access": {
      note: "Full access keeps its name in the bar: a mode that is not the default always says what it is.",
      snapshot: footerChat("full-access"),
    },
    // Leo 2026-10-24: the harness belongs in the model picker's rail, not in the quiet footer row.
    "footer-harness": {
      note: "A started Claude chat: the quiet row contains only mode and model controls; the harness is chosen from the model picker rail.",
      snapshot: footerChat("full-access"),
    },
    "footer-harness-codex": {
      note: "A started Codex chat: the quiet row contains no bottom-left harness label.",
      snapshot: withSummary(chat(finished, { harness: "codex", model: "gpt-6-astra", title: "Codex chat" }), {
        modes: {
          currentModeId: "full-access",
          availableModes: [
            { id: "auto", name: "Auto", description: "Ask before commands outside the workspace." },
            { id: "full-access", name: "Full access", description: "Run commands without asking." },
          ],
        },
      }),
    },
    "footer-harness-new-chat": {
      note: "Play: a new chat keeps the harness choice in the model picker; the footer has no harness item.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
      play: async (ctx) => {
        const item = { selector: ".acpmux-composer-foot .acpmux-model .acpmux-picker-button" };
        await ctx.waitFor(() => ctx.document.querySelector(item.selector));
        await ctx.click(item);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-menu"));
      },
    },
    "footer-harness-unpicked": {
      note: "A new chat with harnesses installed and none picked yet: the row names the installed harness the model button draws, never another.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })]),
    },
    // Leo 2026-10-19: no composer button draws a pill at rest (test/composer-quiet-chips.test.ts).
    // Fast mode is on, and shows only in the model button's menu (Leo 2026-10-20: no bolt).
    // The + is a bare glyph: its tooltip is Codex's short "Add files and more" (Leo, 2026-10-21).
    "plus-tooltip": {
      note: 'Play: hover the +; the tooltip reads "Add files and more".',
      snapshot: chat(finished),
      play: async (ctx) => {
        const selector = ".acpmux-composer-plus .acpmux-picker-button";
        await ctx.waitFor(() => ctx.document.querySelector(selector));
        await ctx.hover({ selector });
        await ctx.waitFor(
          () => ctx.document.querySelector(".ui-title-tooltip:not([hidden])")?.textContent === "Add files and more",
        );
      },
    },
    "quiet-chips": {
      note: "Every footer button at rest: +, the one model button (model and effort) and the mode, with Fast mode on and no bolt. None draws a pill until it is hovered, keyboard-focused, pressed or open.",
      snapshot: quietChips(),
    },
    // The composer's states, the New Tab page's beside them (agent-pane.new-tab composer-*):
    // test/composer-caret-focus.test.ts asserts the same.
    ...Object.fromEntries(
      Object.entries(composerStatePlays(".acpmux-composer-box .acpmux-md")).map(([state, variant]) => [
        `composer-${state}`,
        { ...variant, snapshot: quietChips() },
      ]),
    ),
    idle: {
      note: "After a turn: Send, the mode and model chips.",
      snapshot: chat(finished),
    },
    focused: {
      note: "The prompt focused: no ring drawn inside the composer box.",
      snapshot: chat(finished),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-md" });
        const field = ctx.find({ selector: ".acpmux-md" });
        await ctx.waitFor(() => ctx.document.activeElement === field);
        const outline = ctx.document.defaultView!.getComputedStyle(field).outlineStyle;
        if (outline !== "none") throw new Error(`the focused prompt draws an outline (${outline})`);
      },
    },
    // POLISH.md right-click contract: the prompt's own menu over selected text, never WebKit's.
    "context-menu": {
      note: "Right-click on selected prompt text: Cut, Copy, Paste, Paste as Plain Text, Attach Files…, Insert Mention.",
      ready: { draft: "Add retries with backoff to the fetch helper" },
      snapshot: chat(finished),
      play: async (ctx) => {
        const field = ctx.find({ selector: ".acpmux-md" });
        ctx.document.defaultView!.getSelection()!.selectAllChildren(field);
        const box = field.getBoundingClientRect();
        field.dispatchEvent(
          new MouseEvent("contextmenu", {
            bubbles: true,
            cancelable: true,
            clientX: box.left + 40,
            clientY: box.top + 12,
          }),
        );
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"]'));
      },
    },
    // Austin (dogfood 2026-10-20): typing "1. " drew the list number with its left edge cut off.
    // The marker hangs left of the item, and the editor scrolls, so it clips at the editor's edge.
    "ordered-list-draft": {
      note: "A numbered draft up to 10: every number draws whole inside the prompt, none cut at its left edge.",
      ready: { draft: Array.from({ length: 10 }, (_, i) => `${i + 1}. Step ${i + 1}`).join("\n") },
      snapshot: chat(finished),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-md ol > li").length === 10);
        const editor = ctx.find({ selector: ".acpmux-md" });
        const item = ctx.find({ selector: ".acpmux-md ol > li:last-child" });
        // The widest marker ("10.", in the tabular digits markers use) plus WebKit's gap before the
        // text must fit between the editor's clipping edge and the item's text.
        const probe = ctx.document.createElement("span");
        probe.textContent = "10.";
        probe.style.position = "absolute";
        probe.style.fontVariantNumeric = "tabular-nums";
        editor.parentElement!.append(probe);
        const fontSize = parseFloat(ctx.document.defaultView!.getComputedStyle(editor).fontSize);
        const marker = probe.getBoundingClientRect().width + 1.2 * fontSize;
        probe.remove();
        const room = item.getBoundingClientRect().left - editor.getBoundingClientRect().left;
        if (room < marker) throw new Error(`the list number needs ${marker}px but the prompt leaves ${room}px`);
      },
    },
    // Leo (dogfood 2026-10-08, 22-composer-image-chip.png): a pasted image draws as a cropped
    // thumbnail above the prompt, with a small × that shows on hover; a click opens the viewer.
    "image-attached": {
      note: "A pasted screenshot: a cropped thumbnail above the prompt, its small × shown on hover.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const canvas = new view.OffscreenCanvas(320, 200);
        const paint = canvas.getContext("2d")!;
        const gradient = paint.createLinearGradient(0, 0, 320, 200);
        gradient.addColorStop(0, "#f2b134");
        gradient.addColorStop(1, "#3a7bd5");
        paint.fillStyle = gradient;
        paint.fillRect(0, 0, 320, 200);
        paint.fillStyle = "#ffffff";
        paint.fillRect(40, 60, 240, 16);
        paint.fillRect(40, 92, 180, 16);
        const file = new view.File([await canvas.convertToBlob({ type: "image/png" })], "screenshot.png", {
          type: "image/png",
        });
        pasteFiles(ctx, [file]);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img[src^='data:image/png']"));
        await ctx.hover({ selector: ".acpmux-attachment-image" });
      },
    },
    // Leo (2026-10-20): every pasted image read "image.png" on hover, and one that could not be
    // drawn showed an empty checkerboard. WebKit names pasted image data "image.png".
    "image-pasted-unnamed": {
      note: "A pasted screenshot WebKit names image.png: hover names it Screenshot with its natural size.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const canvas = new view.OffscreenCanvas(2458, 2324);
        const paint = canvas.getContext("2d")!;
        paint.fillStyle = "#1f2a44";
        paint.fillRect(0, 0, 2458, 2324);
        paint.fillStyle = "#5b8def";
        for (let line = 0; line < 10; line += 1) paint.fillRect(560, 300 + line * 180, 1200 - line * 60, 60);
        const file = new view.File([await canvas.convertToBlob({ type: "image/png" })], "image.png", {
          type: "image/png",
        });
        pasteFiles(ctx, [file]);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img[src^='data:image/png']"));
        await ctx.hover({ selector: ".acpmux-attachment-image" });
      },
    },
    "image-failed": {
      note: "A kept draft's image whose bytes cannot be drawn: its chip says Couldn't load image and keeps its × (shown on hover).",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      native: { "chat.draftAttachments.get": [KEPT_BROKEN_IMAGE] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image-failed"));
        const chip = ctx.find({ selector: ".acpmux-attachment-image-failed" });
        if (chip.querySelector(".acpmux-attachment-failed-text")?.textContent !== "Couldn't load image")
          throw new Error("an image that cannot be drawn must say Couldn't load image");
        if (!chip.querySelector("button.acpmux-attachment-remove[aria-label]"))
          throw new Error("an image that cannot be drawn must keep its remove button");
        await ctx.hover({ selector: ".acpmux-attachment-image-failed" });
      },
    },
    // Leo (2026-10-21), as in Claude: a huge paste is a chip with its first words and line count,
    // the prompt as typed; a click puts it back in the prompt, × removes it (pastedText.ts).
    "text-pasted": {
      note: "A 40-line paste: a Pasted text chip (first words, Pasted text · 40 lines) over the typed prompt, × on hover.",
      ready: { draft: "Why does the build fail?" },
      snapshot: chat(finished),
      play: async (ctx) => {
        // The strip view (Settings): this state shows the strip; inline is the default.
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
        const view = ctx.document.defaultView!;
        const data = new view.DataTransfer();
        const log = Array.from(
          { length: 40 },
          (_, index) => `[build] step ${index + 1}: compiling module ${index + 1}`,
        );
        data.setData("text/plain", log.join("\n"));
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: data });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-pasted"));
        await ctx.hover({ selector: ".acpmux-attachment-pasted" });
      },
    },
    // Leo (2026-10-28): "double paste of long block text should reveal it instead of duplicating
    // the paste", "if you paste that and then paste again, then you don't have to click it. It just
    // does it." The same block pasted again opens its chip, as a click does (pastedChips.ts).
    "text-pasted-again": {
      note: "The same 40-line log pasted twice: the second paste opens the first's Pasted text chip, its text in the prompt after the typed words, and no second chip.",
      ready: { draft: "Why does the build fail? " },
      snapshot: chat(finished),
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const log = Array.from(
          { length: 40 },
          (_, index) => `[build] step ${index + 1}: compiling module ${index + 1}`,
        ).join("\n");
        const paste = () => {
          const data = new view.DataTransfer();
          data.setData("text/plain", log);
          const event = new view.Event("paste", { bubbles: true, cancelable: true });
          Object.defineProperty(event, "clipboardData", { value: data });
          ctx.find({ selector: ".acpmux-md" }).dispatchEvent(event);
        };
        // The Pasted text chip: in the prompt's line (the default inline view), or in the strip.
        const PASTED = '.acpmux-md-inline-chip[data-kind="file"], .acpmux-attachment-pasted';
        paste();
        await ctx.waitFor(() => ctx.document.querySelector(PASTED));
        paste();
        // Either way the second paste went: its text in the prompt with no chip, or a second chip.
        await ctx.waitFor(() => {
          const chips = ctx.document.querySelectorAll(PASTED).length;
          const prompt = ctx.document.querySelector(".acpmux-md")?.textContent ?? "";
          return chips > 1 || (chips === 0 && prompt.includes("step 40: compiling"));
        });
        if (ctx.document.querySelector(PASTED))
          throw new Error("the same long paste again must open its chip, never add a second");
      },
    },
    "quick-image-attached": {
      note: "Quick Composer: clicking a pasted image thumbnail opens the same image viewer as a full chat.",
      ready: { surface: "quick" },
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const canvas = new view.OffscreenCanvas(320, 200);
        const paint = canvas.getContext("2d")!;
        paint.fillStyle = "#3a7bd5";
        paint.fillRect(0, 0, 320, 200);
        paint.fillStyle = "#ffffff";
        paint.fillRect(40, 60, 240, 16);
        const file = new view.File([await canvas.convertToBlob({ type: "image/png" })], "quick-screenshot.png", {
          type: "image/png",
        });
        pasteFiles(ctx, [file]);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img[src^='data:image/png']"));
        await ctx.click({ selector: ".acpmux-attachment-open" });
        await ctx.waitFor(() => ctx.document.querySelector('[role="dialog"]'));
      },
    },
    "pdf-attached": {
      note: "A kept draft's PDF shows a preview card, its file name, and its page count before sending.",
      snapshot: chat(finished),
      native: { "chat.draftAttachments.get": [KEPT_PDF] },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-document"));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-document[data-page-count='2']"));
        if (ctx.find({ selector: ".acpmux-attachment-document-name" }).textContent !== "design-notes.pdf")
          throw new Error("the PDF card must name its file");
        await ctx.click({ selector: ".acpmux-attachment-document-open" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pdf-viewer"));
        const dialog = ctx.document.querySelector<HTMLElement>(".acpmux-pdf-viewer");
        if (!dialog || ctx.document.defaultView!.getComputedStyle(dialog).position !== "fixed")
          throw new Error("PDF preview must remain a fixed dialog over the composer");
        if (!ctx.document.querySelector(".ui-backdrop")) throw new Error("PDF preview is missing its backdrop");
      },
    },
    "file-saved-as-path": {
      note: "Pasted files (a text file, a zip, a video) are saved by the chat's host; each chip names the file and says it goes as a file path.",
      snapshot: chat(finished),
      native: {
        "chat.upload": {
          uploads: [
            { name: "notes.md", path: "/Users/dev/Library/Application Support/cmux/Chat Uploads/1/0/notes.md" },
            {
              name: "build-logs.zip",
              path: "/Users/dev/Library/Application Support/cmux/Chat Uploads/1/1/build-logs.zip",
            },
            { name: "repro.mov", path: "/Users/dev/Library/Application Support/cmux/Chat Uploads/1/2/repro.mov" },
          ],
        },
      },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const files = [
          new view.File(["# Notes\nRetry after 5 failures.\n"], "notes.md", { type: "text/markdown" }),
          new view.File([new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xff])], "build-logs.zip", {
            type: "application/zip",
          }),
          new view.File([new Uint8Array([0, 0, 0, 0x18, 0xff])], "repro.mov", { type: "video/quicktime" }),
        ];
        const field = ctx.find({ selector: ".acpmux-md" });
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files, types: ["Files"] } });
        field.dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-attachment-link[data-saved]").length === 3);
        const links = ctx.document.querySelectorAll<HTMLElement>(".acpmux-attachment-link[data-saved]");
        const chips = [...links].map((chip) => ({
          name: chip.querySelector(".acpmux-attachment-link-name")?.textContent,
          note: chip.querySelector(".acpmux-attachment-link-note")?.textContent,
          path: chip.title,
        }));
        for (const name of ["notes.md", "build-logs.zip", "repro.mov"]) {
          const chip = chips.find((entry) => entry.name === name);
          if (!chip) throw new Error(`no saved chip names ${name}`);
          if (chip.note) throw new Error(`${name}'s chip must not expose delivery mechanics`);
          if (!chip.path.endsWith(`/${name}`) || !chip.path.includes("/Chat Uploads/"))
            throw new Error(`${name}'s chip must link the copy the host saved, not ${chip.path}`);
        }
        if (ctx.find({ selector: ".acpmux-md" }).textContent?.includes("Chat Uploads"))
          throw new Error("a saved file's path must go as its chip's link, not as prompt text");
      },
    },
    "file-not-attached": {
      note: "A pasted file no content block takes, in a chat whose host saves nothing: its failed tile keeps its name, says why in its tooltip and offers one retry button.",
      snapshot: chat(finished),
      // A host that saves nothing refuses both the staged upload and the older single call.
      native: {
        "chat.upload.begin": { nativeError: { code: "unsupported" } },
        "chat.upload": { nativeError: { code: "unsupported" } },
      },
      play: async (ctx) => {
        // The strip view (Settings): this state shows the strip; inline is the default.
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
        const view = ctx.document.defaultView!;
        const file = new view.File([new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xff])], "build-logs.zip", {
          type: "application/zip",
        });
        const field = ctx.find({ selector: ".acpmux-md" });
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files: [file], types: ["Files"] } });
        field.dispatchEvent(paste);
        await ctx.waitFor(() => {
          const failed = ctx.document.querySelector<HTMLElement>(".acpmux-attachment-failed");
          return Boolean(
            failed?.querySelector(".acpmux-attachment-failed-name")?.textContent === "build-logs.zip" &&
            failed.getAttribute("title")?.includes("build-logs.zip") &&
            failed.querySelectorAll(".acpmux-attachment-retry").length === 1,
          );
        });
      },
    },
    "image-sent-as-path": {
      note: "A pasted screenshot for an agent that takes no images (promptCapabilities.image false) is saved by the host and goes as its file path; its chip says so.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: false } } }))(
        chat(finished),
      ),
      native: {
        "chat.upload": {
          uploads: [
            {
              name: "Screenshot.png",
              path: "/Users/dev/Library/Application Support/cmux/Chat Uploads/2/0/Screenshot.png",
            },
          ],
        },
      },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const png = Uint8Array.from(
          atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="),
          (char) => char.charCodeAt(0),
        );
        const file = new view.File([png], "Screenshot.png", { type: "image/png" });
        const field = ctx.find({ selector: ".acpmux-md" });
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files: [file], types: ["Files"] } });
        field.dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-link[data-saved]"));
      },
    },
    "folder-dropped-as-link": {
      note: "A folder and a zip dropped from Finder on a chat whose folder is on this Mac: the host knows where they are (chat.attach.dropped), so each chip links to the real path (the folder's name ends in a slash) and nothing is copied or uploaded. The screenshot beside them is an image as before.",
      snapshot: chat(finished),
      native: {
        "chat.attach.dropped": {
          items: [
            { path: `${CWD}/assets`, folder: true },
            { path: "/Users/dev/Downloads/build-logs.zip", folder: false },
            { path: "/Users/dev/Desktop/Screenshot.png", folder: false },
          ],
        },
      },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const png = Uint8Array.from(
          atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="),
          (char) => char.charCodeAt(0),
        );
        // A dropped folder: WebKit hands a File whose bytes cannot be read.
        const folder = new view.File([], "assets", { type: "" });
        Object.defineProperty(folder, "arrayBuffer", { value: () => Promise.reject(new Error("a folder")) });
        const files = [
          folder,
          new view.File([new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xff])], "build-logs.zip", {
            type: "application/zip",
          }),
          new view.File([png], "Screenshot.png", { type: "image/png" }),
        ];
        const drop = new view.Event("drop", { bubbles: true, cancelable: true });
        Object.defineProperty(drop, "dataTransfer", { value: { files, types: ["Files"] } });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(drop);
        await ctx.waitFor(
          () => ctx.document.querySelectorAll(".acpmux-attachment-link:not([data-saved])").length === 2,
        );
        if (ctx.document.querySelector("output.acpmux-attachment-note"))
          throw new Error("a folder dropped in a chat on this Mac must link, not be refused");
      },
    },
    "video-dropped": {
      note: 'Leo, 2026-10-25: "also why dont we have previews of videos we should". A screen recording dropped from the Desktop beside a screenshot, in a chat on this Mac: the host knows its path (chat.attach.dropped) and reads its poster and length off its main thread (video.info), so its chip is the poster in the image\'s tile with a play glyph and "0:42"; a click plays it in Quick Look. Before, it was a bare file name.',
      snapshot: chat(finished),
      native: {
        "chat.attach.dropped": {
          items: [
            { path: "/Users/dev/Desktop/Screenshot.png", folder: false },
            { path: VIDEO_PATH, folder: false },
          ],
        },
        "video.info": VIDEO_INFO,
      },
      play: async (ctx) => {
        dropScreenshotAndVideo(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-video img"));
      },
    },
    "video-reading": {
      note: "A dropped screen recording while the host still reads its poster: its tile spins in the shape it will have, its × removes it, and a send waits for it a few seconds at most (composer/videoAttachments.ts).",
      snapshot: chat(finished),
      native: {
        "chat.attach.dropped": {
          items: [
            { path: "/Users/dev/Desktop/Screenshot.png", folder: false },
            { path: VIDEO_PATH, folder: false },
          ],
        },
        "video.info": VIDEO_INFO,
      },
      nativeDelayMs: { "video.info": 3_600_000 },
      play: async (ctx) => {
        dropScreenshotAndVideo(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image.acpmux-attachment-pending"));
      },
    },
    "attachment-loading": {
      note: "Leo, 2026-10-24: \"why don't you put a spinner on the attachment rather than this placeholder that doesn't do anything... I can't even cancel these\". A pasted screenshot is its chip as soon as its preview is made (in a worker), whatever its original's upload does; a file still uploading spins, and its × cancels it.",
      snapshot: chat(finished),
      nativeDelayMs: { "chat.upload.begin": 3_600_000 },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const png = Uint8Array.from(
          atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="),
          (char) => char.charCodeAt(0),
        );
        const files = [
          new view.File([png], "Screenshot.png", { type: "image/png" }),
          new view.File([new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xff])], "build-logs.zip", {
            type: "application/zip",
          }),
        ];
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files, types: ["Files"] } });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img"));
        // Inline (the default) spins in the text at the caret; the strip spins in its chip.
        await ctx.waitFor(() =>
          ctx.document.querySelector(
            ".acpmux-md-inline-chip[data-state='loading'] .acpmux-md-inline-spinner, .acpmux-attachment-pending .acpmux-attachment-spinner",
          ),
        );
      },
    },
    "attachment-inline-caret": {
      note: 'Leo: "How many motherfucking times have I said, like the macOS fucking iMessage app?" A screenshot is pasted between words at the caret. Backspace removes the atom in one press; undo restores it. The strip remains available in Settings.',
      snapshot: chat(finished),
      ready: { draft: "Compare this with the previous result." },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        view.cmuxAcpmuxComposer?.({ attachmentView: "inline" });
        const field = ctx.find({ selector: ".acpmux-md-field" }) as MarkdownFieldElement;
        const handle = field.acpmuxMarkdownField!;
        handle.setCaret(13);
        const canvas = ctx.document.createElement("canvas");
        canvas.width = 320;
        canvas.height = 180;
        const drawing = canvas.getContext("2d")!;
        drawing.fillStyle = "#5783b5";
        drawing.fillRect(0, 0, 320, 180);
        drawing.fillStyle = "white";
        drawing.font = "24px system-ui";
        drawing.fillText("Before and after", 36, 96);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((value) => resolve(value!), "image/png"));
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", {
          value: {
            files: [new view.File([blob], "comparison.png", { type: "image/png" })],
            types: ["Files"],
            getData: () => "",
          },
        });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-md-inline img"));
      },
    },
    "attachment-inline-image-and-file": {
      note: 'Leo: "How many motherfucking times have I said, like the macOS fucking iMessage app?" A screenshot pasted after "Compare this" and a notes file pasted after "the notes in" sit in the text where they were pasted, as iMessage places them. With the strip view, both sit above the text.',
      snapshot: chat(finished),
      ready: { draft: "Compare this with the notes in and summarize." },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const field = ctx.find({ selector: ".acpmux-md-field" }) as MarkdownFieldElement;
        const handle = field.acpmuxMarkdownField!;
        const paste = (file: File) => {
          const event = new view.Event("paste", { bubbles: true, cancelable: true });
          Object.defineProperty(event, "clipboardData", {
            value: { files: [file], types: ["Files"], getData: () => "" },
          });
          ctx.find({ selector: ".acpmux-md" }).dispatchEvent(event);
        };
        const canvas = ctx.document.createElement("canvas");
        canvas.width = 320;
        canvas.height = 180;
        const drawing = canvas.getContext("2d")!;
        drawing.fillStyle = "#5783b5";
        drawing.fillRect(0, 0, 320, 180);
        drawing.fillStyle = "white";
        drawing.font = "24px system-ui";
        drawing.fillText("Before and after", 36, 96);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((value) => resolve(value!), "image/png"));
        handle.setCaret("Compare this".length);
        paste(new view.File([blob], "comparison.png", { type: "image/png" }));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img"));
        // An atom in the text is one position of the paragraph; the strip view adds none.
        const atoms = ctx.document.querySelectorAll("[data-inline-attachment]").length;
        handle.setCaret("Compare this with the notes in".length + atoms);
        paste(new view.File(["# Notes\nRetry after 5 failures.\n"], "notes.md", { type: "text/markdown" }));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-link[data-saved]"));
      },
    },
    // #26545's review at 2b4ccd42: in the prompt, a PDF, a video and an image that cannot be drawn
    // keep the strip chip's preview, open, play and fallback (composer/inlineAttachments.tsx).
    "attachment-inline-pdf": {
      note: "Inline view: a kept draft's PDF in the prompt's text is the strip's PDF card (sheet, name, page count), and a click on its sheet opens the PDF viewer.",
      snapshot: chat(finished),
      ready: { draft: "Summarize the design notes." },
      native: { "chat.draftAttachments.get": [KEPT_PDF] },
      play: async (ctx) => {
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "inline" });
        const card = "[data-inline-attachment] .acpmux-attachment-document[data-page-count='2']";
        await ctx.waitFor(() => ctx.document.querySelector(card));
        if (ctx.find({ selector: `${card} .acpmux-attachment-document-name` }).textContent !== "design-notes.pdf")
          throw new Error("the inline PDF card must name its file");
        await ctx.click({ selector: "[data-inline-attachment] .acpmux-attachment-document-open" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-pdf-viewer"));
      },
    },
    "attachment-inline-video": {
      note: "Inline view: a dropped screen recording in the prompt's text is the strip's video tile, its poster with a play glyph and 0:42; a click plays it in Quick Look.",
      snapshot: chat(finished),
      native: {
        "chat.attach.dropped": {
          items: [
            { path: "/Users/dev/Desktop/Screenshot.png", folder: false },
            { path: VIDEO_PATH, folder: false },
          ],
        },
        "video.info": VIDEO_INFO,
      },
      play: async (ctx) => {
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "inline" });
        dropScreenshotAndVideo(ctx);
        // Both in the text and drawn (the screenshot's thumbnail is made off the main thread).
        await ctx.waitFor(() => ctx.document.querySelectorAll("[data-inline-attachment] img").length === 2);
        await ctx.waitFor(() => ctx.document.querySelector("[data-inline-attachment] .acpmux-attachment-video img"));
        if (ctx.find({ selector: "[data-inline-attachment] .acpmux-attachment-video-length" }).textContent !== "0:42")
          throw new Error("the inline video tile must show its length");
        // The screenshot's loading tile became its narrower thumbnail as the waits ended: let that
        // frame's shift report before the hover is measured.
        const view = ctx.document.defaultView!;
        await new Promise((done) => view.requestAnimationFrame(() => view.requestAnimationFrame(done)));
        await ctx.hover({ selector: "[data-inline-attachment] .acpmux-attachment-video" });
      },
    },
    "attachment-inline-image-failed": {
      note: "Inline view: a kept draft's image whose bytes cannot be drawn says Couldn't load image in the prompt's text, as the strip's does, with Retry and its x.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      ready: { draft: "What is in this screenshot?" },
      native: { "chat.draftAttachments.get": [KEPT_BROKEN_IMAGE] },
      play: async (ctx) => {
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "inline" });
        const tile = "[data-inline-attachment] .acpmux-attachment-image-failed";
        await ctx.waitFor(() => ctx.document.querySelector(tile));
        const chip = ctx.find({ selector: tile });
        if (chip.querySelector(".acpmux-attachment-failed-text")?.textContent !== "Couldn't load image")
          throw new Error("an inline image that cannot be drawn must say Couldn't load image");
        if (!chip.querySelector("button.acpmux-attachment-retry"))
          throw new Error("an inline image that cannot be drawn must offer Retry");
        if (!chip.querySelector("button.acpmux-attachment-remove[aria-label]"))
          throw new Error("an inline image that cannot be drawn must keep its remove button");
        await ctx.hover({ selector: tile });
      },
    },
    "attachment-reorder": {
      note: "Leo, 2026-10-24: \"we ought to be able to drag and reorder images if we're seeing the non-inline attachment composer\". Three pasted screenshots; the first is being dragged past the second (it lifts and moves as the pointer goes), and the prompt sends them in the strip's order. Option-Left/Right moves a focused chip.",
      snapshot: chat(finished),
      play: async (ctx) => {
        // The strip view (Settings): this state shows the strip; inline is the default.
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
        const view = ctx.document.defaultView!;
        const files = await Promise.all(
          ["#5b8def", "#e0a84f", "#62b67a"].map(async (color, index) => {
            const canvas = ctx.document.createElement("canvas");
            canvas.width = 480;
            canvas.height = 300;
            const context = canvas.getContext("2d")!;
            context.fillStyle = color;
            context.fillRect(0, 0, 480, 300);
            const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
            return new view.File([blob], `Screenshot ${index + 1}.png`, { type: "image/png" });
          }),
        );
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files, types: ["Files"] } });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
        // The strip's chips: the text keeps each one's place in a hidden atom of its own.
        await ctx.waitFor(
          () => ctx.document.querySelectorAll(".acpmux-attachments .acpmux-attachment-image img").length === 3,
        );
        const chips = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-attachments .acpmux-attachment-image")];
        const from = chips[0]!.getBoundingClientRect();
        const to = chips[1]!.getBoundingClientRect();
        const at = (x: number) => ({
          clientX: x,
          clientY: from.top + from.height / 2,
          pointerId: 1,
          button: 0,
          buttons: 1,
          bubbles: true,
        });
        chips[0]!.dispatchEvent(new view.PointerEvent("pointerdown", at(from.left + from.width / 2)));
        chips[0]!.dispatchEvent(new view.PointerEvent("pointermove", at(from.left + from.width / 2 + 8)));
        chips[0]!.dispatchEvent(new view.PointerEvent("pointermove", at(to.right - 4)));
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-slot[data-dragging]"));
      },
    },
    "attachment-failed": {
      note: "A file the composer could not attach stays in the strip saying why (here the app could not save it), with Retry and its ×, instead of a placeholder that never loads.",
      snapshot: chat(finished),
      native: { "chat.upload.begin": { nativeError: { code: "io", userMessage: "The disk is full." } } },
      play: async (ctx) => {
        // The strip view (Settings): this state shows the strip; inline is the default.
        ctx.document.defaultView!.cmuxAcpmuxComposer?.({ attachmentView: "strip" });
        const view = ctx.document.defaultView!;
        const files = [
          // Not a picture after all: it goes as a file, and the app refuses it.
          new view.File([new Uint8Array(64).fill(7)], "Screenshot.png", { type: "image/png" }),
          new view.File([new Uint8Array([0x50, 0x4b, 0x03, 0x04, 0xff])], "build-logs.zip", {
            type: "application/zip",
          }),
        ];
        const paste = new view.Event("paste", { bubbles: true, cancelable: true });
        Object.defineProperty(paste, "clipboardData", { value: { files, types: ["Files"] } });
        ctx.find({ selector: ".acpmux-md" }).dispatchEvent(paste);
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-attachment-failed").length === 2);
      },
    },
    "image-original-failed": {
      note: "A pasted screenshot whose full-size original the app could not save: its preview stays staged and still sends, with a Retry badge whose tooltip says why.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      native: { "chat.upload.begin": { nativeError: { code: "io", userMessage: "The disk is full." } } },
      play: async (ctx) => {
        const view = ctx.document.defaultView!;
        const canvas = new view.OffscreenCanvas(320, 200);
        const paint = canvas.getContext("2d")!;
        paint.fillStyle = "#3a7bd5";
        paint.fillRect(0, 0, 320, 200);
        paint.fillStyle = "#ffffff";
        paint.fillRect(40, 60, 240, 16);
        const file = new view.File([await canvas.convertToBlob({ type: "image/png" })], "screenshot.png", {
          type: "image/png",
        });
        pasteFiles(ctx, [file]);
        await ctx.waitFor(() =>
          ctx.document.querySelector(".acpmux-attachment-image .acpmux-attachment-original-retry"),
        );
        const badge = ctx.find({ selector: ".acpmux-attachment-original-retry" });
        if (!badge.getAttribute("title")?.includes("The disk is full."))
          throw new Error("the Retry badge's tooltip must say why the original failed");
      },
    },
    draft: {
      note: "A draft the tab inherited (markdown, two lines).",
      ready: { draft: "Also add a **circuit breaker** after `5` failures.\nKeep the POST rule as is." },
      snapshot: chat(finished),
    },
    "long-draft": {
      note: "A long draft: the field grows to its limit, then scrolls.",
      ready: {
        draft: Array.from(
          { length: 18 },
          (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        ).join("\n"),
      },
      snapshot: chat(finished),
    },
    "long-draft-light": {
      note: "The capped long draft in the light theme proof matrix.",
      ready: {
        draft: Array.from(
          { length: 18 },
          (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        ).join("\n"),
      },
      snapshot: chat(finished, { summary: { ...chat(finished).summary!, ...composerControls } }),
    },
    "long-draft-dark": {
      note: "The capped long draft in the dark theme proof matrix.",
      ready: {
        draft: Array.from(
          { length: 18 },
          (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
        ).join("\n"),
      },
      snapshot: chat(finished, { summary: { ...chat(finished).summary!, ...composerControls } }),
    },
    working: {
      note: "A turn running: Send becomes Stop.",
      snapshot: chat(working, { isWorking: true }),
    },
    // Leo 2026-10-20: the empty prompt mid-turn teaches its keys, as Claude's composer does.
    "working-hint-steer": {
      note: "A turn running for an agent that steers: the empty prompt says ↵ steers and ⌘↵ queues.",
      snapshot: steering(true),
    },
    "working-hint-queue": {
      note: "The same for an agent that cannot steer: nothing sent stops the turn, so the empty prompt says it queues.",
      snapshot: steering(false),
    },
    "working-stop": {
      note: "Play: stop a running turn; Stop leaves after the host acknowledges cancellation, and with no draft the mic alone keeps the right edge.",
      snapshot: chat(working, { isWorking: true }),
      afterCall: { "chat.cancel": chat(working, { isWorking: false }) },
      checks: {
        layoutShiftMax: {
          value: 0.001,
          reason: "Stopping updates the location picker busy state and permits its subpixel compositor adjustment.",
        },
      },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Stop" });
        await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-cancel"));
      },
    },
    "working-escape-armed": {
      note: "Play: the first Esc of the double press. Stop keeps its plain square glyph and footprint and takes the theme's accent; its name and the placeholder say Esc again stops (Leo 2026-10-21: no discs).",
      snapshot: chat(working, { isWorking: true }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-box .acpmux-md" });
        await ctx.press("Escape");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cancel[data-escape-armed] svg"));
      },
    },
    // Leo 2026-10-21: "IDK IF IM ACTUALLY STOPPING YOU". Stop (or Esc) sent, the turn not ended yet.
    "working-stopping": {
      note: "Stop or Esc was sent and the agent has not ended its turn yet: Stop turns and the empty prompt says Stopping…, until the turn ends.",
      snapshot: chat(working, { isWorking: true, stopping: true }),
    },
    "working-steer": {
      note: "A prompt typed while the turn runs: Stop's slot before the mic turns into the one Send (↵ in Claude's look), which puts the prompt into the turn as Return does (read when the agent's current step ends); ⌘Return queues it for after the turn. No second ↵ control (Leo 2026-10-31).",
      snapshot: steering(true),
      ready: { draft: "Use the new tokenizer instead" },
      play: async (ctx) => {
        await ctx.waitFor(() => {
          const sends = ctx.document.querySelectorAll(".acpmux-composer-actions :is(.acpmux-send, .acpmux-cancel)");
          return (
            sends.length === 1 &&
            sends[0]!.getAttribute("title") === "Send now; the agent reads it mid-turn (Return)" &&
            ctx.document.querySelector(".acpmux-composer-actions > .acpmux-send + .acpmux-fit-mic")
          );
        });
      },
    },
    "working-queue": {
      note: "The same for an agent that cannot steer: the one Send queues, as Return and ⌘Return do.",
      snapshot: steering(false),
      ready: { draft: "Use the new tokenizer instead" },
    },
    queued: {
      note: "Two prompts waiting for the running turn on the composer's top edge, as ChatGPT and Codex draw them: one muted line each, cut with an ellipsis, a hairline between them, no header and no number. Their actions show on hover.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      }),
    },
    "queued-from-agent": {
      note: "Another agent's message waiting behind the turn: no queue row; it waits in the transcript's one collapsed group after the turn, no Read after this turn, its actions (Copy; ⋯ Send now, Dismiss) on its line (QueuedMessageCard.tsx). The person's prompt is the queue's one row, unchanged.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          {
            id: "q1",
            prompt: QUEUED_MESSAGE,
            message: { name: "coord-deputy", sessionId: "s-deputy", text: QUEUED_MESSAGE, raw: QUEUED_MESSAGE },
          },
          { id: "q2", prompt: "And update the README" },
        ],
      }),
    },
    "queued-from-agent-open": {
      note: "Play: the waiting agent's message opened in the transcript: its whole text as Markdown in the panel under its line.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          {
            id: "q1",
            prompt: QUEUED_MESSAGE,
            message: { name: "coord-deputy", sessionId: "s-deputy", text: QUEUED_MESSAGE, raw: QUEUED_MESSAGE },
          },
          { id: "q2", prompt: "And update the README" },
        ],
      }),
      play: async (ctx) => {
        // It waits in the one collapsed group of waiting messages (PendingMessagesCard.tsx).
        await ctx.click({ selector: ".cv-pending__toggle" });
        await ctx.waitFor(() => ctx.document.querySelector('[data-queued-message="q1"] .cv-disclosure__toggle'));
        await ctx.click({ selector: '[data-queued-message="q1"] .cv-disclosure__toggle' });
        await ctx.waitFor(() =>
          ctx.document.querySelector('[data-queued-message="q1"] .cv-disclosure__toggle[aria-expanded="true"]'),
        );
      },
    },
    "queued-from-agent-lane-report": {
      note: "Leo's lane report reference waiting behind a running turn: its received line in the transcript; opened, the From line, rendered Markdown table and links, whole.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          {
            id: "q-lane-report",
            prompt: QUEUED_LANE_REPORT,
            message: {
              name: "cx3-s71-jank",
              sessionId: "lane-jank",
              text: QUEUED_LANE_REPORT,
              raw: QUEUED_LANE_REPORT,
            },
          },
        ],
      }),
    },
    // Leo, 2026-10-21 ("this is what ChatGPT has"): each queued row shows Steer, the trash can and ⋯.
    "queued-actions": {
      note: "Play: the pointer over a queued prompt shows its actions as ChatGPT and Codex do: Steer (its ↪ glyph and its word), a trash can that deletes it, and ⋯; plain glyphs, a soft pill on hover only. Focus in the row shows them too.",
      snapshot: { ...steering(true), queue: waiting.slice(0, 2) },
      play: async (ctx) => {
        await ctx.hover({ selector: '.acpmux-queued[data-prompt-id="q1"] .acpmux-queued-text' });
      },
    },
    "queued-actions-menu": {
      note: "Play: ⋯ on a queued prompt opens the composer menus' glass menu: Edit message, Open in side chat (where the chat opens side chats) and Turn off queueing.",
      snapshot: { ...steering(true), queue: waiting.slice(0, 2) },
      play: async (ctx) => {
        await ctx.hover({ selector: '.acpmux-queued[data-prompt-id="q1"] .acpmux-queued-text' });
        await ctx.click({ selector: '.acpmux-queued[data-prompt-id="q1"] [data-menu="queued-more"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-queued-more [role="menuitem"]'));
      },
    },
    "queued-cancel-edit": {
      note: "Play: the x on an unread queued prompt withdraws it from the queue and restores its text in the composer; it is a real cancel-and-edit, so the queued row disappears.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "And update the README" },
        ],
      }),
      native: { "chat.queue.remove": { removed: true } },
      play: async (ctx) => {
        await ctx.hover({ selector: '.acpmux-queued[data-prompt-id="q1"] .acpmux-queued-text' });
        await ctx.click({ selector: '.acpmux-queued[data-prompt-id="q1"] [data-action="cancel-edit"]' });
        await ctx.waitFor(
          () =>
            !ctx.document.querySelector('.acpmux-queued[data-prompt-id="q1"]') &&
            ctx.document.querySelector(".acpmux-composer-prompt .acpmux-md-root")?.textContent?.trim() ===
              "Then add a test for the 429 path",
        );
      },
    },
    "queued-images": {
      note: "A prompt queued with two screenshots: small thumbnails under its text, each opening the image viewer.",
      snapshot: chat(working, { isWorking: true, queue: [pictured, { id: "q2", prompt: "And update the README" }] }),
    },
    "queued-images-edit": {
      note: "Play: Edit message (the ⋯ menu) on a queued prompt with images: each thumbnail shows its remove control; removing one and saving keeps the other.",
      snapshot: chat(working, { isWorking: true, queue: [pictured, { id: "q2", prompt: "And update the README" }] }),
      native: { "chat.queue.edit": { ok: true } },
      play: async (ctx) => {
        await ctx.click({ selector: '.acpmux-queued[data-prompt-id="q1"] [data-menu="queued-more"]' });
        await ctx.click({ role: "menuitem", name: /^Edit message/ });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued-image-remove").length === 2);
      },
    },
    "queued-paused": {
      note: "A turn failed with prompts queued: the note names the turn's error, and they wait under it, in order, until Resume. A prompt sent meanwhile runs now.",
      snapshot: (() => {
        const failed = steering(true);
        return {
          ...failed,
          isWorking: false,
          rows: [
            ...failed.rows,
            {
              id: "summary-failed",
              version: 1,
              at: 1,
              kind: "turnSummary",
              status: "failed",
              error: "429 Too Many Requests: the account is rate limited",
            },
          ],
          summary: { ...failed.summary!, status: "ready", queuePaused: true },
          queue: waiting,
        };
      })(),
    },
    "queued-keyboard": {
      note: "Play: ↑ from the empty prompt reaches the last queued prompt, ↑ again the one before; Return edits it in its row (Return saves, Esc cancels). On a row, ⌥↑/⌥↓ move it and Delete removes it; ⌘Return does nothing there (Steer is the row's button).",
      snapshot: { ...steering(true), queue: waiting },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-prompt" });
        await ctx.press("ArrowUp");
        await ctx.press("ArrowUp");
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-queued-edit"));
      },
    },
    "history-recall": {
      checks: SEND_ARRIVES,
      note: "Play: ↑ from the empty prompt brings back the chat's last prompt, ↑ again the one before, ↓ steps forward and past the newest empties the prompt, as in Codex and Claude Code. The older prompt has Markdown characters the field escapes. A prompt being typed is never replaced.",
      snapshot: chat([
        user("Fix arr[0] and the 2 * 3 case in fetch_helper_retry", 6),
        assistant("Added retries with exponential backoff.", 5),
        user("Then add a test for the 429 path", 3),
        assistant("Added the test.", 2),
      ]),
      play: async (ctx) => {
        const prompt = () =>
          ctx.document.querySelector(".acpmux-composer-prompt .acpmux-md-root")?.textContent?.trim() ?? "";
        await ctx.click({ selector: ".acpmux-composer-prompt" });
        await ctx.press("ArrowUp");
        await ctx.waitFor(() => prompt() === "Then add a test for the 429 path");
        await ctx.press("ArrowUp");
        await ctx.waitFor(() => prompt() === "Fix arr[0] and the 2 * 3 case in fetch_helper_retry");
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => prompt() === "Then add a test for the 429 path");
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => prompt() === "");
        await ctx.type("draft");
        await ctx.press("ArrowUp");
        await ctx.waitFor(() => prompt() === "draft");
      },
    },
    "history-recall-older-page": {
      note: "Play: recall C, then an older page arrives while the field still shows it; ↑ continues with B instead of jumping to A.",
      snapshot: chat(historyPageRows),
      play: async (ctx) => {
        const prompt = () =>
          ctx.document.querySelector(".acpmux-composer-prompt .acpmux-md-root")?.textContent?.trim() ?? "";
        await ctx.click({ selector: ".acpmux-composer-prompt" });
        await ctx.press("ArrowUp");
        await ctx.waitFor(() => prompt() === "C: add the 429 test");
        // Model the transcript page arriving after the user has started browsing. Row ids for B and
        // C are kept from the mounted snapshot; only the older A turn is prepended.
        await new Promise((resolve) => setTimeout(resolve, 120));
        const bridge = (
          ctx.document.defaultView as unknown as {
            cmuxAcpmuxBridge?: { receive(snapshot: AcpmuxSnapshot): void };
          }
        ).cmuxAcpmuxBridge;
        if (!bridge) throw new Error("gallery pane bridge is unavailable");
        bridge.receive(chat(historyPageOlderRows));
        await ctx.press("ArrowUp");
        await ctx.waitFor(() => prompt() === "B: update the retry helper");
      },
    },
    "queued-steering": {
      note: "A prompt sent now (its Steer button) to an agent that cannot steer waits first under Steering and runs next; the turn runs on. The queued prompts follow it, one muted line each.",
      snapshot: chat(working, {
        isWorking: true,
        queue: [{ id: "q0", prompt: "Stop and fix the space thing first", next: true }, ...waiting],
      }),
    },
    "steer-waiting-stack": {
      note: "Two steers the agent has not read, one after the other: each footer contains only Send now and remove until the steer is sent or read.",
      snapshot: waitingSteers(),
      play: async (ctx) => {
        await ctx.hover({ text: "Use the cache dir, not tmp" });
        const lines = [...ctx.document.querySelectorAll(".cv-user__pending")];
        if (lines.length !== 2) throw new Error(`expected two Send now marks, found ${lines.length}`);
        for (const line of lines) {
          if (line.querySelector(".cv-user__read")) throw new Error("a queue footer still has a read receipt");
          const actions = line.parentElement;
          if (!actions?.classList.contains("cv-user__actions")) throw new Error("Send now is not in the action row");
          if (actions.firstElementChild !== line) throw new Error("Send now does not lead the action row");
          if (!actions.previousElementSibling?.classList.contains("cv-user__bubble"))
            throw new Error("Send now action row is not under the bubble");
        }
      },
    },
    // Leo, 2026-10-24: "where's the, like, X button? All I see is the send now. There's no, like,
    // you know, sort of retract and send now."
    "steer-waiting-x": {
      note: "Play: hover a steer Claude has not read, in a Claude Code chat under its own family name (claude-sr2): Send now and the X (take it back to edit) are its complete action row.",
      snapshot: waitingSteerSr2(),
      play: async (ctx) => {
        await ctx.hover({ text: "Also keep the old flag working" });
        const pending = ctx.document.querySelector(".cv-user__pending");
        if (!pending?.querySelector(".cv-user__send-now")) throw new Error("no Send now on the waiting steer");
        if (!pending.querySelector(".cv-user__take-back")) throw new Error("no X on the waiting steer");
      },
    },
    // Leo, 2026-10-24: "after i clicked send now and it worked it should just disappear" and "with
    // the animation as well".
    "steer-send-now-leaves": {
      note: "Play: Send now on a steer Claude has not read: acpmux accepts delivery, and Send now and the X are replaced by normal hover actions while the steer still waits for Claude to read it. The action row keeps its line: the bubble, the row and the transcript do not move.",
      snapshot: waitingSteerSr2(),
      native: { "chat.queue.edit": { ok: true } },
      play: async (ctx) => {
        await ctx.hover({ text: "Also keep the old flag working" });
        const steer = ctx.find({ text: "Also keep the old flag working" }).closest(".cv-user");
        const actions = steer?.querySelector<HTMLElement>(".cv-user__actions");
        const before = actions?.getBoundingClientRect();
        await ctx.click({ selector: ".cv-user__send-now" });
        await ctx.waitFor(() => !ctx.document.querySelector(".cv-user__pending"));
        const after = actions?.getBoundingClientRect();
        if (!before || !after || before.top !== after.top || before.height !== after.height)
          throw new Error("the steer's action row moved when Send now left");
      },
    },
    "steer-marks": {
      note: "Unread steers show only queue controls. Sent or read prompts show normal hover actions without checks or state dots.",
      snapshot: steerMarks(),
    },
    "steer-read-hover": {
      note: "Hover a read steer: only age, Copy, Retry and available message actions remain.",
      snapshot: steerMarks(),
      play: async (ctx) => {
        await ctx.hover({ text: "Use the cache dir, not tmp" });
        const steer = ctx.find({ text: "Use the cache dir, not tmp" }).closest(".cv-user");
        if (steer?.querySelector(".cv-user__pending, .cv-user__read, .cv-user__dot"))
          throw new Error("a read steer still has queue controls or state marks");
      },
    },
    "queued-long": {
      note: 'Many queued prompts fold: the next two show, then one "3 more queued" row. The cut-off one shows a tooltip on hover and opens whole on click.',
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          {
            id: "q2",
            prompt:
              "Once the retries land, go through every caller of the fetch helper and make sure none of them retries on its own as well, then check the upload path and the sync worker for the same pattern, write down which ones you changed and why, and summarize what changed",
          },
          { id: "q3", prompt: "And update the README" },
          { id: "q4", prompt: "Run the whole suite" },
          { id: "q5", prompt: "Open a PR" },
        ],
      }),
      play: async (ctx) => {
        // Target the queue row itself so the pointer enters the span that owns the truncation
        // check; a text target can resolve to the row or a parent in the gallery driver.
        await ctx.hover({ selector: '.acpmux-queued[data-prompt-id="q2"] .acpmux-queued-text' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-queued-text[title]"));
      },
    },
    "queued-long-open": {
      note: 'Play: "3 more queued" opens the whole queue in place, in order, and reads Show less; it closes back the same way.',
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "Check every caller of the fetch helper for its own retries" },
          { id: "q3", prompt: "And update the README" },
          { id: "q4", prompt: "Run the whole suite" },
          { id: "q5", prompt: "Open a PR" },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-queue-fold" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued").length === 5);
      },
    },
    "queued-long-open-glass": {
      note: 'Play: the opened long queue in the tray strip over a see-through window (layout pass, 2026-10-20). The band and its "Show less" line are one glass surface, the card\'s tone at its 60%, inset as the tray, and the last row shows whole.',
      snapshot: chat(working, {
        isWorking: true,
        queue: [
          { id: "q1", prompt: "Then add a test for the 429 path" },
          { id: "q2", prompt: "Check every caller of the fetch helper for its own retries" },
          { id: "q3", prompt: "And update the README" },
          { id: "q4", prompt: "Run the whole suite" },
          { id: "q5", prompt: "Open a PR" },
        ],
      }),
      play: async (ctx) => {
        const root = ctx.document.documentElement;
        root.setAttribute("data-top-strip", "tray");
        root.setAttribute("data-cmux-see-through", "");
        await ctx.click({ selector: ".acpmux-queue-fold" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued").length === 5);
      },
    },
    "queued-send-remove": {
      note: "Play: remove the first waiting prompt from its row, then Stop: the turn ends and the next prompt is sent. Neither moves the composer, the transcript or the rows below.",
      snapshot: chat(working, { isWorking: true, queue: waiting }),
      native: { "chat.queue.remove": { removed: true }, "chat.queue.edit": { ok: true } },
      afterCall: {
        // acpmux ends the turn and starts the next queued prompt (q2): its rows join the transcript.
        "chat.cancel": chat(
          [
            working[0]!,
            { ...working[1]!, version: 2, streaming: false },
            user("And update the README", 0),
            assistant("Looking at the README…", 0, { streaming: true }),
          ],
          { isWorking: true, queue: waiting.slice(2) },
        ),
      },
      play: async (ctx) => {
        await ctx.hover({ text: "Then add a test for the 429 path" });
        await ctx.click({ selector: '.acpmux-queued[data-prompt-id="q1"] [data-action="delete"]' });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued").length === 2);
        await ctx.click({ role: "button", name: "Stop" });
        await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-queued").length === 1);
      },
    },
    "codex-model": {
      note: "Another harness and model in the chips.",
      snapshot: chat(finished, { harness: "codex", model: "gpt-6-astra", title: "Codex chat" }),
    },
    // A Codex chat on a Cloud machine (remoteEditing.ts): a team machine's wire refuses it, the
    // person's own machine (`ownerCloud`) sends.
    "codex-cloud-team": {
      note: "A Codex chat on a team Cloud machine: no Send, and a note says this agent cannot be driven from here.",
      ready: { draft: "Add retries with backoff to the fetch helper" },
      snapshot: cloudCodex(),
    },
    "codex-cloud-own": {
      note: "A Codex chat on the person's own Cloud machine: the normal composer, with Send.",
      ready: { draft: "Add retries with backoff to the fetch helper" },
      snapshot: cloudCodex(true),
    },
    // The location row is a new chat's only (locationRow.ts): these show it before the first send.
    "tray-long-branch": {
      note: "A new chat's location row keeps a long branch readable without moving the composer.",
      ready: { newSession: true, cwd: CWD },
      snapshot: onBranch("feature/composer-location-tray"),
    },
    "docked-400": {
      note: "A new chat's location row at a 400px dock width.",
      ready: { newSession: true, cwd: CWD },
      snapshot: onBranch("feature/composer-location-tray"),
    },
    "wide-760": {
      note: "The composer card and a new chat's location row at the 760px wide proof width.",
      ready: { newSession: true, cwd: CWD },
      snapshot: onBranch("feature/composer-location-tray"),
    },
    "folder-menu": {
      note: "Play: open the footer's folder menu; it draws above the whole card, opaque, rows legible.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-context .acpmux-location-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-location-menu, [role='dialog']"));
      },
    },
    "add-menu": {
      note: "Play: open +; Attach files or images comes first and opens the file chooser, the Search section offers Search chats and Search pages, and the menu rises out of +.",
      snapshot: chat(finished, {
        commands: [{ name: "compact", description: "Clear conversation history but keep a summary in context" }],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-composer-plus [data-value="add.files"]'));
        // The Search section: Search chats and Search pages open the app's palette pages.
        for (const id of ["agentPane.searchChats", "history.search"])
          if (!ctx.document.querySelector(`.acpmux-composer-plus [data-value="${id}"]`))
            throw new Error(`the + menu lost ${id}`);
      },
    },
    // Leo, 2026-10-31: "our + button is ass" / "inside chat and in the composer it's ass". The chat
    // advertises 30 skills (synthetic names), Plan and Goal: + lists attach, then Plan, Goal, @, then one
    // Commands and skills… row, then the searches, each row one line, in a bounded panel; no skill is
    // a row (recent ones: gallery agent-pane.composer-plus).
    "add-menu-skills": {
      note: "Play: open + in a chat with 30 skills, Plan and Goal: attach rows, then Plan, Goal, Mention, then one Commands and skills… row (no skill rows), then Search; icon, title and a muted description on one line, in a bounded panel.",
      snapshot: ((base) => ({
        ...base,
        summary: {
          ...base.summary!,
          promptCapabilities: { image: true },
          modes: {
            currentModeId: "default",
            availableModes: [
              { id: "default", name: "Ask before edits" },
              { id: "plan", name: "Plan" },
            ],
          },
        },
      }))(
        chat(finished, {
          commands: [
            { name: "goal", description: "Set a goal for this chat", source: "agent" },
            { name: "compact", description: "Clear conversation history but keep a summary in context" },
            ...Array.from({ length: 30 }, (_, index) => ({
              name: `${["cloud", "deploy", "review", "search", "docs"][index % 5]}-skill-${index + 1}`,
              description: `Sample skill ${index + 1}: a long description that runs past the menu's right edge`,
              source: "skill" as const,
            })),
          ],
        }),
      ),
      native: { "composer.capture": null },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-composer-plus [data-value="add.files"]'));
        // test/composer-plus-menu-shape.browser.test.ts holds the shape: no skill rows, one-line rows,
        // a bounded panel. The play only opens it, so the same state draws the menu before the fix.
        const rows = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-composer-plus .acpmux-menu-item")];
        for (const id of ["add.files", "add.screenshot", "add.window", "add.mode.plan", "add.goal", "add.mention"])
          if (!rows.some((row) => row.dataset.value === id)) throw new Error(`the + menu lost ${id}`);
      },
    },
    // cx-ncc.71 (Codex parity): + > Attach Screenshot… and Attach Window… take a capture through the
    // host (macOS screencapture's own region or window pick) and attach it as an image chip.
    "attach-screenshot": {
      note: "Play: + > Attach Screenshot… asks the host for a region capture, attaches the image it returns and puts focus back in the prompt.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      checks: {
        anchorMovePx: {
          value: 78,
          reason:
            "The attached image's compact thumbnail row (a 64 px thumbnail 8 px under the top, the text 6 px under it; Leo, 2026-10-18) opens above the prompt, the same growth a pasted image makes.",
        },
        layoutShiftMax: { value: 0.07, reason: "The thumbnail row the capture adds above the prompt." },
      },
      native: {
        "composer.capture": {
          name: "Screenshot.png",
          mimeType: "image/png",
          data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
        },
      },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
        await ctx.click({ selector: '.acpmux-composer-plus [data-value="add.screenshot"]' });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-attachment-image img[src^='data:image/png']"));
        // Back in the prompt, to type about the capture (the + menu does not take focus back).
        await ctx.waitFor(() => ctx.document.activeElement?.closest(".acpmux-composer-prompt"));
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: { method: string; params?: unknown }[] })
          .cmuxGalleryLog;
        const asked = log.find(({ method }) => method === "composer.capture");
        if ((asked?.params as { mode?: string } | undefined)?.mode !== "screen")
          throw new Error(`capture asked ${JSON.stringify(asked)}`);
      },
    },
    "attach-window-cancelled": {
      note: "Play: + > Attach Window… that the person cancels attaches nothing, shows no error and puts focus back in the prompt.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      native: { "composer.capture": null },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
        await ctx.click({ selector: '.acpmux-composer-plus [data-value="add.window"]' });
        const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: { method: string; params?: unknown }[] })
          .cmuxGalleryLog;
        await ctx.waitFor(() =>
          log.some(
            ({ method, params }) => method === "composer.capture" && (params as { mode?: string })?.mode === "window",
          ),
        );
        await new Promise((resolve) => setTimeout(resolve, 200));
        if (ctx.document.querySelector(".acpmux-attachment-image, .acpmux-attachment-note"))
          throw new Error("a cancelled capture attached something or showed a note");
        if (!ctx.document.activeElement?.closest(".acpmux-composer-prompt"))
          throw new Error("a cancelled capture left focus off the prompt");
      },
    },
    "attach-screenshot-too-large": {
      note: "Play: + > Attach Screenshot… of a capture too large to attach shows the composer's note naming it, not nothing.",
      snapshot: ((base) => ({ ...base, summary: { ...base.summary!, promptCapabilities: { image: true } } }))(
        chat(finished),
      ),
      checks: {
        anchorMovePx: {
          value: 40,
          reason: "The note row opens above the prompt, as a pasted file that is too large does.",
        },
        layoutShiftMax: { value: 0.05, reason: "The note row the refused capture adds above the prompt." },
      },
      native: { "composer.capture": { tooLarge: true, name: "Screenshot 2026-10-11 14.32.05.png" } },
      play: async (ctx) => {
        await ctx.click({ selector: ".acpmux-composer-plus .acpmux-picker-button" });
        await ctx.click({ selector: '.acpmux-composer-plus [data-value="add.screenshot"]' });
        await ctx.waitFor(() =>
          ctx.document
            .querySelector(".acpmux-attachment-note")
            ?.textContent?.includes("Screenshot 2026-10-11 14.32.05.png"),
        );
        if (ctx.document.querySelector(".acpmux-attachment-image"))
          throw new Error("a refused capture attached an image");
      },
    },
    "context-breakdown": {
      note: "Play: rest the pointer on the context ring after a first message on Codex; the glass card shows the share and tokens used and the window as a bar.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-context",
          harness: "codex",
          model: "gpt-5.5",
          cwd: CWD,
          turnCount: 1,
          usage: { used: 25_300, size: 258_400 },
        },
      }),
      play: async (ctx) => {
        await ctx.hover({ selector: "button.acpmux-context-ring" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-context-card"));
      },
    },
    "slash-menu": {
      note: "Play: type / in the prompt; the agent's command menu opens.",
      snapshot: chat(finished, {
        commands: [
          { name: "compact", description: "Clear conversation history but keep a summary in context" },
          { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" },
          { name: "review", description: "Review a pull request" },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/");
        await ctx.waitFor(() => ctx.document.querySelector("[role='listbox'], [role='menu']"));
      },
    },
    // Leo 2026-10-22 (relayed by claude-sr2): "Match theirs: icon, plain name, a sentence saying what
    // selecting it does in the current state." Claude Code's `/fast` row as ChatGPT's Fast row.
    "slash-menu-fast-on": {
      note: "Play: type /fast in a Claude chat with Fast on; the row is the bolt, Fast, and what picking it does now: turn Fast off.",
      snapshot: fastChat("on"),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/fast");
        await ctx.waitFor(() => ctx.document.querySelector("#acpmux-slash-menu [role='option']"));
      },
    },
    "slash-menu-fast-off": {
      note: "Play: type / in a Claude chat with Fast off; the Fast row says picking it turns Fast on, among the other commands.",
      snapshot: fastChat("off"),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/");
        await ctx.waitFor(() => ctx.document.querySelector("#acpmux-slash-menu [role='option']"));
      },
    },
    "slash-menu-full": {
      note: "Play: type / with an agent's full command list; in a small window the list goes past the window's edge (cx-6k6cg).",
      snapshot: chat(finished, {
        commands: [
          { name: "add-dir", description: "Add a new working directory" },
          { name: "agents", description: "Manage agent configurations" },
          { name: "clear", description: "Clear conversation history and free up context" },
          { name: "compact", description: "Clear conversation history but keep a summary in context" },
          { name: "config", description: "Open the config panel" },
          { name: "cost", description: "Show the total cost and duration of the current session" },
          { name: "doctor", description: "Diagnose and verify your installation" },
          { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" },
          { name: "memory", description: "Edit memory files" },
          { name: "permissions", description: "Manage allow and deny tool permission rules" },
          { name: "review", description: "Review a pull request" },
          { name: "status", description: "Show the version, model, account and connectivity" },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/");
        await ctx.waitFor(() => ctx.document.querySelector("#acpmux-slash-menu [role='option']"));
      },
    },
    "slash-menu-keyboard": {
      note: "Play: Ctrl-J/Ctrl-K and arrows move the slash-command highlight, Enter picks it, and focus stays in the prompt.",
      snapshot: chat(finished, {
        commands: [
          { name: "compact", description: "Clear conversation history but keep a summary in context" },
          { name: "init", description: "Initialize a new CLAUDE.md file with codebase documentation" },
          { name: "review", description: "Review a pull request" },
        ],
      }),
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("/");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "true");
        await ctx.waitFor(() => {
          const active = ctx.find(prompt).getAttribute("aria-activedescendant");
          return Boolean(active && ctx.document.getElementById(active));
        });
        const before = ctx.find(prompt).getAttribute("aria-activedescendant");
        await ctx.press("Control+j");
        await ctx.waitFor(() => {
          const active = ctx.find(prompt).getAttribute("aria-activedescendant");
          const option = active ? ctx.document.getElementById(active) : null;
          return Boolean(active && active !== before && option?.getAttribute("aria-selected") === "true");
        });
        await ctx.press("Control+k");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-activedescendant") === before);
        const active = ctx.find(prompt).getAttribute("aria-activedescendant");
        const selected = active ? ctx.document.getElementById(active)?.querySelector(".acpmux-slash-name") : null;
        const command = selected?.textContent?.trim();
        if (!command) throw new Error("slash command highlight has no command label");
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "false");
        if (ctx.document.activeElement !== ctx.find(prompt)) throw new Error("slash command pick lost prompt focus");
        if (!ctx.find(prompt).textContent?.includes(`${command} `))
          throw new Error("slash command pick did not update prompt");
      },
    },
    "slash-menu-skills-and-input": {
      note: "Play: the shared slash picker combines harness commands, skills and prompts; Shift-Enter keeps editing and Enter sends.",
      snapshot: chat(finished, {
        commands: [
          { name: "review", description: "Review the current changes", source: "agent" },
          { name: "$cmux-browser", description: "Use cmux browser controls", source: "skill" },
          { name: "daily-plan", description: "Plan the next work block", source: "prompt" },
        ],
      }),
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("/");
        // cmux's own commands (at least /import) share the menu, so find the fixture rows by name.
        const row = (name: string) =>
          [...ctx.document.querySelectorAll("#acpmux-slash-menu [role='option']")].find(
            (option) => option.querySelector(".acpmux-slash-name")?.textContent === `/${name}`,
          );
        const label = (name: string) => row(name)?.querySelector(".acpmux-slash-source")?.textContent ?? "";
        await ctx.waitFor(() => !!row("review") && !!row("$cmux-browser") && !!row("daily-plan"));
        if (label("$cmux-browser") !== "Skill") throw new Error("the skill row has no Skill label");
        if (label("daily-plan") !== "Prompt") throw new Error("the prompt row has no Prompt label");
        if (label("review") !== "") throw new Error("a harness command is labeled");
        await ctx.press("Escape");
        await ctx.press("Backspace");
        await ctx.waitFor(() => (ctx.find(prompt).textContent ?? "").trim() === "");
        await ctx.type("first line");
        await ctx.press("Shift+Enter");
        await ctx.type("second line");
        if (!ctx.find(prompt).textContent?.includes("first line"))
          throw new Error("Shift-Enter did not keep the draft");
        await ctx.press("Enter");
        await ctx.waitFor(() => (ctx.find(prompt).textContent ?? "").trim() === "");
      },
    },
    "search-files-key": {
      note: "Play: Search Files… (from the command palette in an agent chat, cx-ncc.69) opens the chat folder's file search with the keyboard in its field.",
      snapshot: chat(finished),
      play: async (ctx) => {
        // The prompt has the keyboard when the key comes in, as in a chat.
        await ctx.focus({ selector: "[contenteditable='true']" });
        const page = ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: { command?(name: string): void } };
        page.cmuxAcpmuxBridge?.command?.("searchFiles");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-file-search") !== null);
        await ctx.waitFor(() => ctx.document.activeElement === ctx.document.querySelector(".acpmux-file-search input"));
      },
    },
    "mention-picker": {
      checks: SEND_ARRIVES,
      note: "Play: type @rea in the prompt; Ctrl-J/Ctrl-K move the file highlight, and Return writes @README.md into the prompt.",
      snapshot: chat(finished),
      native: {
        "file.search": {
          root: CWD,
          results: [
            { path: "README.md", matches: [0, 1, 2] },
            { path: "src/reader.ts", matches: [4, 5, 6] },
          ],
        },
      },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("Fix @rea");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "true");
        await ctx.waitFor(() =>
          Array.from(ctx.document.querySelectorAll(".acpmux-mention-row")).some((row) =>
            row.textContent?.includes("README.md"),
          ),
        );
        // The rows replace "Searching…" and the list grows up from the composer. waitFor answers
        // that DOM change before it paints, so without these frames the growth was measured as
        // Ctrl-J's layout shift. The list has opened at once with no entrance animation since #24980.
        const frame = () => new Promise((resolve) => ctx.document.defaultView!.requestAnimationFrame(resolve));
        await frame();
        await frame();
        const before = ctx.find(prompt).getAttribute("aria-activedescendant");
        await ctx.press("Control+j");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-activedescendant") !== before);
        await ctx.press("Control+k");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-activedescendant") === before);
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "false");
        if (!ctx.find(prompt).textContent?.includes("Fix @README.md"))
          throw new Error(`mention pick did not write the path: ${ctx.find(prompt).textContent}`);
        if (ctx.document.activeElement !== ctx.find(prompt)) throw new Error("mention pick lost prompt focus");
      },
    },
    "mention-escaped-path": {
      checks: SEND_ARRIVES,
      note: "Play: pick a path markdown escapes (src/__init__.py), then keep typing; the picker stays closed after the space it wrote.",
      snapshot: chat(finished),
      native: { "file.search": { root: CWD, results: [{ path: "src/__init__.py", matches: [6, 7, 8] }] } },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("Read @ini");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mention-row[role=option]") !== null);
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "false");
        await ctx.type("now");
        await new Promise((resolve) => setTimeout(resolve, 300));
        if (!ctx.find(prompt).textContent?.includes("Read @src/__init__.py now"))
          throw new Error(`mention pick did not write the path: ${ctx.find(prompt).textContent}`);
        if (
          ctx.document.querySelector(".acpmux-mention-row") ||
          ctx.find(prompt).getAttribute("aria-expanded") === "true"
        )
          throw new Error("the picker reopened after the picked path's space");
      },
    },
    "mention-mid-word": {
      checks: SEND_ARRIVES,
      note: "Play: an @ inside a word (an email address) opens no file picker.",
      snapshot: chat(finished),
      native: { "file.search": { root: CWD, results: [{ path: "README.md" }] } },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("mail me@rea");
        await new Promise((resolve) => setTimeout(resolve, 300));
        if (ctx.document.querySelector(".acpmux-mention-row")) throw new Error("an @ inside a word opened the picker");
      },
    },
    "mention-mixed": {
      checks: SEND_ARRIVES,
      note: "Play: type @proje; other chats list first with their project muted, then folders, then the chat folder's files, matched letters bold.",
      snapshot: mentionChat(),
      native: { "file.search": MENTION_FILES },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("hey @proje");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mention-row[data-mention-kind='file']") !== null);
        const kinds = Array.from(
          ctx.document.querySelectorAll<HTMLElement>(".acpmux-mention-row"),
          (row) => row.dataset.mentionKind,
        );
        if (kinds.join(",") !== "session,folder,file,file,file,file,file,file")
          throw new Error(`the picker listed ${kinds.join(",")}`);
      },
    },
    "mention-session-pick": {
      note: "Play: type @coord and press Return; the chat's title and id replace the @word, which an agent looks up with cmux.",
      snapshot: mentionChat(),
      native: { "file.search": { root: CWD, results: [] } },
      checks: {
        anchorMovePx: {
          value: 24,
          reason:
            "A chat's title and full id wrap the prompt to a second line; the composer grows one line, as for typed text.",
        },
        layoutShiftMax: { value: 0.01, reason: "The same one-line growth of the prompt." },
      },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("Read @coord");
        await ctx.waitFor(
          () => ctx.document.querySelector(".acpmux-mention-row[data-mention-kind='session']") !== null,
        );
        // A chat is the pick once the word's files are in (none here), not while they are on their way.
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-activedescendant") === "acpmux-mention-0");
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "false");
        const written = ctx.find(prompt).textContent ?? "";
        if (
          !written.includes(
            'Read cmux session "Resume: projects-70 coordinator (0cfd5322)" (0cfd5322-a913-4e01-b71c-aaf0edfb4de8)',
          )
        )
          throw new Error(`the chat pick wrote ${written}`);
      },
    },
    "mention-file-over-prompt-chat": {
      checks: SEND_ARRIVES,
      note: "Play: type @app beside a chat named for a long prompt; the prompt's letters do not list the chat, and Return writes the file.",
      snapshot: (() => {
        const base = chat(finished);
        return {
          ...base,
          sessions: [
            ...base.sessions,
            session({
              sessionId: "5e6f7a8b-9c0d-4e1f-8a2b-3c4d5e6f7a8b",
              title:
                "Can you add a parser for the plist files and make sure the tests pass on every platform we support, then update the app docs",
              updatedAt: minutesAgo(5),
            }),
          ],
        };
      })(),
      native: { "file.search": { root: CWD, results: [{ path: "src/app.ts", matches: [4, 5, 6] }] } },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("Open @app");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mention-row[data-mention-kind='file']") !== null);
        if (ctx.document.querySelector(".acpmux-mention-row[data-mention-kind='session']"))
          throw new Error("a chat matched @app by its prompt's letters");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-activedescendant") === "acpmux-mention-0");
        await ctx.press("Enter");
        await ctx.waitFor(() => ctx.find(prompt).getAttribute("aria-expanded") === "false");
        if (!ctx.find(prompt).textContent?.includes("Open @src/app.ts"))
          throw new Error(`the pick wrote ${ctx.find(prompt).textContent}`);
      },
    },
    "mention-recent-chats": {
      checks: SEND_ARRIVES,
      note: "Play: a bare @ lists the most recent other chats before a word is typed.",
      snapshot: mentionChat(),
      native: { "file.search": MENTION_FILES },
      play: async (ctx) => {
        const prompt = { selector: "[contenteditable='true']" } as const;
        await ctx.focus(prompt);
        await ctx.type("@");
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-mention-row") !== null);
        const first = ctx.document.querySelector(".acpmux-mention-row .acpmux-slash-name")?.textContent;
        if (first !== "Fix the dock") throw new Error(`the newest other chat is not first: ${first}`);
      },
    },
    "slash-fork": {
      note: "Play: type /fork; the cmux-owned fork command appears with the harness commands.",
      snapshot: chat([...finished.slice(0, -1), summary(9, { status: "completed", seq: 12 })], {
        commands: [
          { name: "compact", description: "Clear conversation history but keep a summary in context" },
          { name: "review", description: "Review a pull request" },
        ],
      }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/fork");
        await ctx.waitFor(() =>
          Array.from(ctx.document.querySelectorAll(".acpmux-slash-name")).some((node) => node.textContent === "/fork"),
        );
      },
    },
    "slash-menu-cmux-descriptions": {
      note: "Play: type /; import starts a new chat with the transcript as its first prompt, and fork opens a new chat.",
      snapshot: chat([...finished.slice(0, -1), summary(9, { status: "completed", seq: 12 })], { commands: [] }),
      play: async (ctx) => {
        await ctx.click({ selector: "[contenteditable='true']" });
        await ctx.type("/");
        const row = (name: string) =>
          [...ctx.document.querySelectorAll("#acpmux-slash-menu [role='option']")].find(
            (option) => option.querySelector(".acpmux-slash-name")?.textContent === `/${name}`,
          );
        await ctx.waitFor(() => !!row("import") && !!row("fork"));
        if (
          row("import")?.querySelector(".acpmux-slash-description")?.textContent !==
          "Start a new chat with this transcript as its first prompt"
        )
          throw new Error("/import description does not explain the transcript's first prompt");
        if (!row("fork")?.querySelector(".acpmux-slash-description")?.textContent?.includes("new chat"))
          throw new Error("/fork description does not describe its new chat");
      },
    },
    "reasoning-claude": {
      note: "Play: the model button reads Medium with no Fast word; its menu ends on a checked Fast mode row, and its effort levels (inline in the current row, or the Effort submenu) are the ones Opus 5.5 offers (Low, Medium, High, Max), with no Fast.",
      snapshot: withSummary(chat(finished, { title: "Claude reasoning" }), {
        configOptions: [
          {
            id: "effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: "medium",
            options: [
              { value: "default", name: "Default" },
              { value: "low", name: "Low" },
              { value: "medium", name: "Medium" },
              { value: "high", name: "High" },
              { value: "xhigh", name: "Extra High" },
              { value: "max", name: "Max" },
            ],
          },
          CLAUDE_ULTRACODE_OFF,
          {
            id: "fast-mode",
            name: "Fast mode",
            category: "model_config",
            currentValue: "on",
            options: [
              { value: "off", name: "Off" },
              { value: "on", name: "On" },
            ],
          },
        ],
      }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(MODEL_DETAIL)?.textContent?.trim() === "Medium");
        if (ctx.document.querySelector(".acpmux-fast")) throw new Error("the composer must draw no speed bolt");
        await openModelMenu(ctx);
        const fast = ctx.document.querySelector(".acpmux-quick-menu .acpmux-quick-fast");
        if (fast?.getAttribute("aria-checked") !== "true")
          throw new Error("Fast mode must be a checked row of the menu");
        // The menu is open: a second press on the model button would close it.
        const levels = await openEffortSubmenu(ctx);
        // A submenu row names its level in its label; an inline segment in its aria-label ("Opus 5.5 · Low").
        const names = [...levels.querySelectorAll('[role="menuitemradio"]')].map(
          (node) =>
            node.querySelector(".acpmux-menu-label")?.textContent?.trim() ??
            node.getAttribute("aria-label")?.split(" · ").pop(),
        );
        // The fixture's Opus 5.5 offers Low, Medium, High and Max (no Extra High, so no Ultracode).
        const expected = ["Low", "Medium", "High", "Max"];
        if (names.join("|") !== expected.join("|")) throw new Error(`Effort lists ${names.join(", ")}`);
        if (levels.textContent?.includes("Fast")) throw new Error("Fast mode must live in one place, not in Effort");
      },
    },
    "reasoning-claude-default": {
      note: "Play: a chat on Claude Code's own level (default) on Opus 5.5 [1m]: the model button names the level it resolves to, Medium; the Effort submenu checks Medium and lists no Ultrathink.",
      snapshot: withSummary(chat(finished, { title: "Claude default reasoning" }), {
        model: "claude-opus-5-5[1m]",
        configOptions: [
          {
            id: "effort",
            name: "Reasoning",
            category: "thought_level",
            currentValue: "default",
            // An older acpmux still lists Ultrathink, a prompt keyword: the menu drops it.
            options: ["default", "low", "medium", "high", "xhigh", "max", "ultrathink"].map((value) => ({ value })),
          },
          CLAUDE_ULTRACODE_OFF,
        ],
      }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(MODEL_DETAIL)?.textContent?.trim() === "Medium");
        const levels = await openEffortMenu(ctx);
        await ctx.waitFor(() =>
          levels.querySelector('[role="menuitemradio"][aria-checked="true"]')?.textContent?.includes("Medium"),
        );
        if (levels.textContent?.includes("Ultrathink")) throw new Error("Effort lists Ultrathink");
      },
    },
    "reasoning-codex": {
      note: "Play: Codex keeps Fast mode in the model button's menu as one toggle row; the composer has no separate lightning control.",
      snapshot: withSummary(chat(finished, { harness: "codex", model: "gpt-6-astra", title: "Codex reasoning" }), {
        configOptions: [
          {
            id: "reasoning_effort",
            category: "thought_level",
            currentValue: "medium",
            options: ["low", "medium", "high", "xhigh", "max", "ultra"].map((value) => ({ value })),
          },
          {
            id: "fast-mode",
            category: "model_config",
            currentValue: "off",
            options: [
              { value: "off", name: "Off", description: "Default speed, normal usage" },
              { value: "on", name: "On", description: "1.5x speed, increased usage" },
            ],
          },
        ],
      }),
      play: async (ctx) => {
        if (ctx.document.querySelector(".acpmux-fast")) throw new Error("the composer must draw no speed bolt");
        await openModelMenu(ctx);
        const fast = ctx.document.querySelector<HTMLElement>(".acpmux-quick-menu .acpmux-quick-fast");
        if (!fast) throw new Error("Codex's model menu must expose Fast mode");
        if (fast.getAttribute("aria-checked") !== "false") throw new Error("Fast mode must start off");
        await ctx.click({ selector: ".acpmux-quick-menu .acpmux-quick-fast" });
        // The agent-pane snapshot is static; the live ComposerPickers fixture checks the
        // resulting Fast mode state. This play verifies the row is present and clickable.
      },
    },
    "model-menu-keyboard": {
      note: "Play: open the model button's menu, then More models (the full picker), and move its highlight with the keyboard.",
      checks: {
        layoutShiftMax: {
          value: 0.03,
          reason:
            "Opening the Older models fold inserts rows inside the fixed-height popup; the transcript and composer anchors must remain fixed.",
        },
      },
      snapshot: chat(finished, {
        harness: "claude",
        model: "claude-opus-5-5",
        title: "Model picker interaction",
      }),
      play: async (ctx) => {
        // A started chat's menu has no rail, so More models opens the full picker (Leo 2026-10-20).
        await openModelMenu(ctx);
        await ctx.click({ role: "menuitem", name: /^More models/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-model .acpmux-mp"));
        const search = ctx.find({ selector: ".acpmux-mp input[role=combobox]" });
        await ctx.waitFor(() => ctx.document.activeElement === search);
        const previous = search.getAttribute("aria-activedescendant");
        await ctx.press("ArrowDown");
        await ctx.waitFor(() => {
          const current = search.getAttribute("aria-activedescendant");
          return current !== previous && Boolean(current && ctx.document.getElementById(current));
        });
        // Past the visible rows the list follows the highlight (Lawrence 2026-10-09: it did not scroll).
        for (let step = 0; step < 14; step++) await ctx.press("ArrowDown");
        await ctx.waitFor(() => {
          const row = ctx.document.getElementById(search.getAttribute("aria-activedescendant") ?? "");
          const list = row?.closest(".acpmux-mp-models")?.parentElement;
          if (!row || !list) return false;
          const r = row.getBoundingClientRect();
          const v = list.getBoundingClientRect();
          return r.top >= v.top - 1 && r.bottom <= v.bottom + 1;
        });
      },
    },
    "picker-toggle": {
      note: "Play: open the permission picker, then press its trigger again; the menu closes and does not reopen on the same WebKit click.",
      snapshot: withSummary(chat(finished, { title: "Picker toggle" }), {
        sessionId: "gallery-picker-toggle",
        harness: "claude",
        model: "claude-opus-5-5",
        cwd: CWD,
        turnCount: 1,
        modes: composerControls.modes,
      }),
      play: async (ctx) => {
        const trigger = '[aria-label="Mode"]';
        await ctx.click({ selector: trigger });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
        await ctx.click({ selector: trigger });
        await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
      },
    },
    "reasoning-menu": {
      note: "Play: open the model button's effort levels (inline in the current row, or its Effort submenu); they list only the model's levels and check the current one.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-reasoning",
          harness: "codex",
          model: "gpt-5.5",
          cwd: CWD,
          turnCount: 1,
          configOptions: [
            {
              id: "reasoning_effort",
              name: "Reasoning",
              category: "thought_level",
              currentValue: "high",
              options: [
                { value: "low", name: "Low" },
                { value: "medium", name: "Medium" },
                { value: "high", name: "High" },
                { value: "xhigh", name: "Extra high" },
              ],
            },
          ],
        },
      }),
      play: async (ctx) => {
        const levels = await openEffortMenu(ctx);
        await ctx.waitFor(() =>
          levels.querySelector('[role="menuitemradio"][aria-checked="true"]')?.textContent?.includes("High"),
        );
      },
    },
    "reasoning-none": {
      note: "A model whose only level is the agent's default: the model button names the model alone and its menu has no Effort row, never Default / Default.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-reasoning-none",
          harness: "claude",
          model: "claude-opus-5-5",
          cwd: CWD,
          turnCount: 1,
          configOptions: [
            {
              id: "effort",
              name: "Effort",
              category: "thought_level",
              currentValue: "default",
              options: [{ value: "default", name: "Default" }],
            },
          ],
        },
      }),
    },
    "model-menu-starred": {
      note: "Play: open the model button's menu before the first send: its harness rail lists each harness, and a tab shows that harness's models in place.",
      checks: {
        layoutShiftMax: {
          value: 0.055,
          reason:
            "Filtering the model catalog reflows rows inside the fixed-height popup; the transcript and composer anchors must remain fixed.",
        },
      },
      // A chat before its first send: a started chat's model menu has no harness rail, so no
      // Starred tab (75bc9406caf7, #22226).
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
      play: async (ctx) => {
        await openModelMenu(ctx);
        // The rail's tabs draw a mark alone; each names its harness.
        await ctx.click({ selector: '.acpmux-quick-rail-tab[aria-label="Codex"]' });
        await ctx.waitFor(
          () =>
            ctx.find({ selector: '.acpmux-quick-rail-tab[aria-label="Codex"]' }).getAttribute("aria-pressed") ===
              "true" && ctx.document.querySelector('.acpmux-quick-body [role="menuitemradio"]') !== null,
        );
      },
    },
    "model-switching": {
      note: "A switch from Claude Code to Codex is starting: the chip draws the Codex mark with its name, never one harness's mark beside another's name.",
      snapshot: chat(finished, {
        harness: "claude",
        model: "claude-opus-5-5",
        title: "Switching harness",
        switching: { harness: "codex", name: "Codex", phase: "starting" },
      }),
    },
    "access-menu": {
      note: "A Claude chat's mode menu is Claude Code's own: Mode, then Auto (Recommended), Manual, Accept edits, Plan and Bypass permissions with their descriptions and keys 1 to 5, tight rows, the accent check on the chosen one. The button is the mode's symbol and its name, no pill at rest.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-access",
          harness: "claude",
          family: "claude",
          model: "claude-opus-5-5",
          effort: "high",
          cwd: CWD,
          host: "This Mac",
          hostKind: "local",
          branch: "main",
          turnCount: 1,
          usage: { used: 48_000, size: 200_000 },
          promptCapabilities: { image: true },
          modes: {
            currentModeId: "bypassPermissions",
            // As acpmux reports a Claude chat (claude_stdio MODES).
            availableModes: [
              { id: "auto", name: "Auto", description: "Claude handles permission decisions" },
              { id: "default", name: "Manual", description: "Always ask before making changes" },
              { id: "acceptEdits", name: "Accept edits", description: "Automatically accept all file edits" },
              { id: "plan", name: "Plan", description: "Create a plan before making changes" },
              { id: "bypassPermissions", name: "Bypass permissions", description: "Accepts all permissions" },
            ],
          },
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Mode"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
      },
    },
    "access-menu-codex": {
      note: "A Codex chat's mode menu is Codex's own: How should actions be approved?, then Ask for approval (hand), Approve for me (terminal shield) and Full access (shield with !) with their descriptions. The button is the shield and Full access.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-access-codex",
          harness: "codex",
          family: "codex",
          model: "gpt-6-astra",
          cwd: CWD,
          host: "This Mac",
          hostKind: "local",
          branch: "main",
          turnCount: 1,
          usage: { used: 48_000, size: 200_000 },
          promptCapabilities: { image: true },
          modes: {
            currentModeId: "agent-full-access",
            // As the Codex bridge reports it (cmux-codex-acp config.rs MODES), plus Codex's auto review.
            availableModes: [
              { id: "ask", name: "Ask", description: "Asks before every command and every edit" },
              {
                id: "read-only",
                name: "Read Only",
                description: "Reads files; asks before any edit or command that needs more",
              },
              {
                id: "agent",
                name: "Agent",
                description: "Edits and runs commands in the workspace; asks to go outside it",
              },
              { id: "auto-review", name: "Auto review" },
              {
                id: "agent-full-access",
                name: "Agent (full access)",
                description: "Edits and runs anything without asking",
              },
            ],
          },
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Mode"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
      },
    },
    "popup-surface": {
      note: "Every composer popup uses the shared glass surface: anchored above its chip, keyboard focus only, and the highlight remains visible while moving through rows.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-popup-surface",
          harness: "claude",
          model: "claude-opus-5-5",
          effort: "high",
          cwd: CWD,
          host: "This Mac",
          hostKind: "local",
          branch: "main",
          turnCount: 1,
          ...composerControls,
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Mode"]' });
        await ctx.waitFor(() => ctx.document.querySelector('.ui-popup[role="menu"]'));
        const popup = ctx.document.querySelector<HTMLElement>('.ui-popup[role="menu"]');
        if (!popup) throw new Error("shared popup did not open");
        const style = ctx.document.defaultView!.getComputedStyle(popup);
        if (style.backdropFilter === "none" && style.getPropertyValue("-webkit-backdrop-filter") === "none")
          throw new Error("shared popup is missing glass material");
        if (!style.backgroundColor || style.backgroundColor === "rgba(0, 0, 0, 0)")
          throw new Error("shared popup is missing its themed surface fill");
        const box = ctx.find({ selector: ".acpmux-composer-box" });
        const boxStyle = ctx.document.defaultView!.getComputedStyle(box);
        if (!boxStyle.boxShadow || boxStyle.boxShadow === "none") throw new Error("composer surface has no soft edge");
        // The chat has a turn: no location strip at all (locationRow.ts), so nothing over the card.
        if (ctx.document.querySelector(".acpmux-composer-context"))
          throw new Error("a started chat still draws the location strip");
        if (ctx.document.querySelector(".acpmux-separator")) throw new Error("composer still has a stray divider");
        // The free space sits only between the left cluster and mic/Send (hq#1957 item 15).
        const actions = ctx.find({ selector: ".acpmux-composer-actions" });
        const bar = ctx.find({ selector: ".acpmux-composer-inner" });
        const leftItems = [...bar.children].filter((child) => child !== actions);
        const leftEnd = Math.max(...leftItems.map((child) => child.getBoundingClientRect().right));
        if (!(actions.getBoundingClientRect().left > leftEnd))
          throw new Error("composer controls lost the flexible gap between left and right groups");
        await ctx.press("ArrowDown");
        await ctx.press("Escape");
        await ctx.waitFor(() => !ctx.document.querySelector('.ui-popup[role="menu"]'));
        await openModelMenu(ctx);
        await ctx.waitFor(() => ctx.document.querySelector('.ui-popup[role="menu"] [role="menuitemradio"]'));
      },
    },
    disconnected: {
      note: "The daemon connection dropped.",
      snapshot: chat(finished, { connection: "disconnected" }),
    },
    // Leo 2026-10-29: "i literally can't stop you i clicked the stop button and it didnt do anything".
    "working-stop-reconnecting": {
      note: "Play: Stop while the pane reconnects to acpmux mid-turn (an acpmux restart): the app refuses the cancel, and the composer says Stopping… until the Stop goes out on the reconnect (stopThroughReconnect.ts).",
      snapshot: chat(working, { isWorking: true, connection: "disconnected" }),
      native: { "chat.cancel": { nativeError: { code: "native.not_connected" } } },
      play: async (ctx) => {
        await ctx.click({ role: "button", name: "Stop" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-cancel[data-stopping]"));
      },
    },
  },
});

/// A chat snapshot with extra summary fields (the agent's config options).
function withSummary(
  snapshot: ReturnType<typeof chat>,
  summary: Partial<NonNullable<ReturnType<typeof chat>["summary"]>>,
): ReturnType<typeof chat> {
  return { ...snapshot, summary: { ...snapshot.summary!, ...summary } };
}

/// A Codex chat on the Cloud machine `cloud-1`, over the app's remote wire; `ownerCloud` when the
/// signed-in person owns that machine.
function cloudCodex(ownerCloud?: true): ReturnType<typeof chat> {
  const snapshot = chat(finished, {
    harness: "codex",
    model: "gpt-6-astra",
    title: "Codex chat",
    sessions: [
      session({ sessionId: SESSION_ID, title: "Codex chat", harness: "codex", host: "cloud-1", hostKind: "cloud" }),
    ],
    origin: "remote",
    ownerCloud,
  });
  return withSummary(snapshot, { host: "cloud-1", peer: "cloud-1", hostKind: "cloud" });
}

/// Every footer button (+, the one model button with its effort, the mode; Fast mode on, which only
/// the model button's menu shows), for the quiet-chips and composer-state variants.
function quietChips(): ReturnType<typeof chat> {
  return withSummary(chat(finished, { title: "Quiet chips" }), {
    modes: {
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Default", description: "Ask before sensitive actions." },
        { id: "full-access", name: "Full access", description: "Run actions without asking." },
      ],
    },
    configOptions: [
      {
        id: "effort",
        name: "Reasoning",
        category: "thought_level",
        currentValue: "medium",
        options: [
          { value: "low", name: "Low" },
          { value: "medium", name: "Medium" },
          { value: "high", name: "High" },
        ],
      },
      {
        id: "fast-mode",
        name: "Fast mode",
        category: "model_config",
        currentValue: "on",
        options: [
          { value: "off", name: "Off" },
          { value: "on", name: "On" },
        ],
      },
    ],
  });
}
