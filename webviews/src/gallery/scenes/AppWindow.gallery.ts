// l10n-allow-file: gallery fixtures (sample chats, prompts and replies), not shipped UI.
// The app, whole: the real agent pane (acpmux/main.tsx, AcpmuxApp) at the size it has in a real
// cmux window (the default window frame, window.ts), in the states a person reaches by using it.
// Leo, 2026-10-30: "we should have a faithful all-levle representation of the app through that
// stuff" and "WE DONT NEED FUCKIGN SCREENSHOTS JUST LET ME TRY THE SHIT OUT". Each variant is a
// live pane: every menu and panel is opened by the play steps a person's clicks would make, and
// stays usable after. Nothing native (sidebar, tab strip, title bar) is drawn; window mode sizes
// the pane from the app's own metrics.
import { agentPaneEntry } from "../format";
import type { PlayContext } from "../play";
import {
  activity,
  assistant,
  chat,
  CONTEXT_BREAKDOWN,
  CWD,
  fleetPeers,
  manySessions,
  noChat,
  summary,
  thought,
  tool,
  user,
} from "../fixtures/acpmux";

/// The New Tab page as the app opens it: the host's `ready` answer names the tab a New Tab page,
/// with no template stored yet (the app's unset key, Minimal), and the person's recent chats.
const newTabReady = {
  newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude" },
  newSession: true,
};

const edit = (path: string, oldText: string | undefined, newText: string) =>
  tool(`Edit ${path}`, "edit", "completed", { diffs: [{ path: `${CWD}/${path}`, oldText, newText }] });

const RETRY_PLAN = `The fetch helper gives up on the first failure. I'll add a small retry with exponential backoff:

1. \`retry()\` in \`src/net/retry.ts\`, three tries, 200 ms doubling, only for 429 and 5xx.
2. \`fetchWithRetry\` wraps the existing helper, so its three callers change one import each.
3. A test for the 429 path and one for a request that never recovers.`;

const RETRY_DONE = `Done. \`fetchWithRetry\` now retries 429 and 5xx responses three times with exponential backoff:

\`\`\`ts
export async function retry<T>(run: () => Promise<T>, tries = 3, delayMs = 200): Promise<T> {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      if (attempt >= tries || !isRetryable(error)) throw error;
      await sleep(delayMs * 2 ** (attempt - 1));
    }
  }
}
\`\`\`

All 48 tests pass, including the two new ones. The webhook relay keeps its own timeout, so I left it on the plain helper.`;

/// A coding chat as a person has it after a few turns: prompts, the agent's reads, edits and test
/// run, its replies with a code block, and a follow-up.
const transcript = chat(
  [
    user("The fetch helper gives up on the first 429. Can you add retries with backoff?", 24),
    activity(
      [
        thought("The helper is in src/net/fetch.ts; I should see who calls it before changing its shape."),
        tool("Read src/net/fetch.ts", "read", "completed", { locations: [{ path: `${CWD}/src/net/fetch.ts` }] }),
        tool("Search for fetchWithRetry in src", "search", "completed"),
        tool("Read src/api/client.ts", "read", "completed", { locations: [{ path: `${CWD}/src/api/client.ts` }] }),
      ],
      23,
    ),
    assistant(RETRY_PLAN, 22),
    summary(22, { durationMs: 38_000, toolCount: 3 }),
    user("Sounds good, go ahead.", 20),
    activity(
      [
        edit("src/net/retry.ts", undefined, "export async function retry() {}\n"),
        edit("src/net/fetch.ts", "export const tries = 1;\n", "export const tries = 3;\nexport const backoff = 200;\n"),
        edit("test/retry.test.ts", undefined, "test('retries a 429', () => {});\n"),
        tool("bun test", "execute", "completed", { command: "bun test" }),
      ],
      18,
    ),
    assistant(RETRY_DONE, 15),
    summary(15, { durationMs: 212_000, toolCount: 4 }),
    user("Does the upload path use it too?", 4),
    assistant(
      "Yes: `upload.ts` calls `fetchWithRetry` for each chunk, so a 503 mid-upload now retries that chunk instead of failing the whole file.",
      3,
    ),
    summary(3, { durationMs: 9_000 }),
  ],
  {
    title: "Add retries to the fetch helper",
    branch: "feat/fetch-retries",
    sessions: manySessions(8),
    ...fleetPeers(),
  },
);
// The session's effort option as Claude Code reports it (`configOptions`), so the model button names
// the level and its menu offers the levels, as a live chat's does.
transcript.summary = {
  ...transcript.summary!,
  configOptions: [
    {
      id: "effort",
      name: "Effort",
      category: "thought_level",
      currentValue: "high",
      options: [
        { value: "low", name: "Low" },
        { value: "medium", name: "Medium" },
        { value: "high", name: "High" },
        { value: "max", name: "Max" },
      ],
    },
  ],
};
// Its context as Claude Code reports it, so Session Info's Context row has a breakdown.
const transcriptWithContext = {
  ...transcript,
  summary: {
    ...transcript.summary!,
    usage: { used: 171_400, size: 400_000 },
    contextBreakdown: CONTEXT_BREAKDOWN,
  },
};

/// The app offers Session Info (Debug Settings `agent.inspector`, on by default).
const native = { "pane.tabState": { inspector: true } };

const MODEL_BUTTON = { selector: ".acpmux-model .acpmux-picker-button" };

/// Clicks the composer's one model button (model and effort) and waits for its menu's models.
async function openModelMenu(ctx: PlayContext) {
  await ctx.waitFor(() => ctx.document.querySelector(MODEL_BUTTON.selector));
  await ctx.click(MODEL_BUTTON);
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-quick-menu [role="menuitemradio"]'));
}

/// With the model menu open, opens the current model's effort levels: the side dropdown beside
/// the running row when it has one, else the Effort submenu (a submenu row opens from the keyboard;
/// Base UI's trigger ignores a mouse press while it opens on hover).
async function openEffortLevels(ctx: PlayContext) {
  const SIDE = ".acpmux-quick-model-effort[data-running] .acpmux-quick-effort-trigger";
  const effortRow = () =>
    [...ctx.document.querySelectorAll<HTMLElement>('.acpmux-quick-menu [role="menuitem"]')].find((item) =>
      item.textContent?.trim().startsWith("Effort"),
    );
  await ctx.waitFor(() => ctx.document.querySelector(SIDE) ?? effortRow());
  if (ctx.document.querySelector(SIDE)) {
    await ctx.focus({ selector: SIDE });
    await ctx.press("ArrowRight");
    await ctx.waitFor(() => ctx.document.querySelector(".acpmux-quick-effort-menu"));
    return;
  }
  await ctx.focus({ role: "menuitem", name: /^Effort/ });
  await ctx.press("Enter");
  await ctx.waitFor(() =>
    [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu")].some(
      (menu) => !menu.querySelector(".acpmux-quick-sub") && menu.querySelector('[role="menuitemradio"]') !== null,
    ),
  );
}

/// Session Info open beside the chat: it opens by default for a first chat; if this pane has it
/// closed, the header's toggle opens it, as a person would.
async function showSessionInfo(ctx: PlayContext) {
  const shown = () => ctx.document.querySelector(".acpmux-session-info[data-presence=shown]");
  await ctx.waitFor(() => shown() ?? ctx.document.querySelector('[aria-label="Session Info"]'), { capMs: 5000 });
  if (!shown()) await ctx.click({ role: "button", name: "Session Info" });
  await ctx.waitFor(shown, { capMs: 5000 });
}

/// A new chat (no turn yet) keeps the location row under the composer; its computer control opens
/// the machine picker over the person's machines.
const newChat = noChat(manySessions(8), {
  ...fleetPeers(),
  summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
});

export default agentPaneEntry({
  id: "app.window",
  title: "App window scenes",
  area: "Agent pane",
  keywords: ["whole app", "window", "scene", "try it"],
  covers: [
    "agent-session/acpmux/App.tsx#AcpmuxApp",
    "agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen",
    "agent-session/acpmux/session-info/SessionInfo.tsx#SessionInfo",
    "agent-session/acpmux/session-info/SessionInfo.tsx#SessionInfoPanel",
    "agent-session/acpmux/QuickModelMenu.tsx#QuickModelMenu",
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/EnvironmentPicker.tsx#EnvironmentPicker",
  ],
  checks: {
    layoutShiftMax: {
      value: 0.05,
      reason:
        "These are whole-app scenes for trying the app, not layout gates; each surface's own entry holds its strict layout checks.",
    },
  },
  variants: {
    "new-tab": {
      note: "A new tab, the full page as the app opens it: the New Tab page with its composer and recent chats.",
      ready: newTabReady,
      snapshot: noChat(manySessions(12), { listedSessions: true, ...fleetPeers() }),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".nt-field"));
      },
    },
    "chat-session-info": {
      note: "A chat after a few turns (reads, edits, a test run, a code block) with Session Info open beside it.",
      snapshot: transcriptWithContext,
      native,
      play: showSessionInfo,
    },
    "composer-model-picker": {
      note: "Play: click the composer's model button; its menu lists the harness's models, Effort, More models and Fast mode.",
      snapshot: transcript,
      native,
      play: openModelMenu,
    },
    "composer-effort-menu": {
      note: "Play: open the model menu, then the current model's effort levels (Low, Medium, High, Max), High checked.",
      snapshot: transcript,
      native,
      play: async (ctx) => {
        await openModelMenu(ctx);
        await openEffortLevels(ctx);
      },
    },
    "environment-picker": {
      note: "Play: in a new chat, click the computer control under the composer; the picker lists this Mac, the person's machines and Cloud.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-context"));
        await ctx.click({ role: "button", name: /^(Computer|Environment)/ });
        await ctx.waitFor(() =>
          ctx.document.querySelector(
            '.acpmux-location-menu [role="option"], [role="menu"] [role="menuitemradio"], .acpmux-env-popover [role="option"]',
          ),
        );
      },
    },
  },
});
