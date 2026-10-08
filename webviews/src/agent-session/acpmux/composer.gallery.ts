// l10n-allow-file: gallery fixtures (sample drafts and chats), not shipped UI.
// The composer's states (Composer.tsx, ComposerPickers.tsx, ComposerContext.tsx: the prompt,
// the mode and model chips, the location row, Send and Stop), through the pane's own inputs: the
// `ready` answer's draft and new-chat fields, and the snapshot.
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, CWD, noChat, session, summary, user } from "../../gallery/fixtures/acpmux";

const finished = [
  user("Add retries with backoff to the fetch helper", 10),
  assistant("Done: GETs retry, POSTs only with a policy.", 9),
  summary(9, { status: "completed" }),
];

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
      { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
    ],
  },
};

export default agentPaneEntry({
  id: "agent-pane.composer",
  title: "Composer",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 760 },
  // The transcript must not move while a play step opens a menu over it.
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
    "agent-session/acpmux/ComposerPickers.tsx#ComposerPickers",
    "agent-session/acpmux/ComposerContext.tsx#ComposerContext",
    "agent-session/acpmux/composer/PromptEditor.tsx",
    "agent-session/acpmux/MarkdownField.tsx",
    "agent-session/acpmux/EffortPicker.tsx",
    "agent-session/acpmux/EmptyState.tsx",
  ],
  variants: {
    "new-chat": {
      note: "A new chat: empty prompt; the card's footer row holds the folder and computer, under a hairline.",
      ready: { newSession: true, cwd: CWD },
      snapshot: noChat([session({ sessionId: "older", title: "An older chat" })], {
        summary: { sessionId: "", cwd: CWD, harness: "claude", model: "claude-opus-5-5", effort: "high" },
      }),
    },
    idle: {
      note: "After a turn: Send, the mode and model chips.",
      snapshot: chat(finished),
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
      snapshot: chat([user("Add retries", 1), assistant("Reading the helper…", 0.5, { streaming: true })], {
        isWorking: true,
      }),
    },
    "codex-model": {
      note: "Another harness and model in the chips.",
      snapshot: chat(finished, { harness: "codex", model: "gpt-6-astra", title: "Codex chat" }),
    },
    "tray-long-branch": {
      note: "The footer row keeps a long branch readable without moving the composer.",
      snapshot: chat(finished, { branch: "feature/composer-location-tray" }),
    },
    "docked-400": {
      note: "The card's footer row at a 400px dock width.",
      snapshot: chat(finished, { branch: "feature/composer-location-tray" }),
    },
    "wide-760": {
      note: "The composer card and its footer row at the 760px wide proof width.",
      snapshot: chat(finished, { branch: "feature/composer-location-tray" }),
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
    "access-menu": {
      note: "The footer keeps permission mode behind a quiet lock; the menu explains each choice and checks the active one.",
      snapshot: chat(finished, {
        summary: {
          sessionId: "gallery-access",
          harness: "claude",
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
            currentModeId: "ask",
            availableModes: [
              { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
              { id: "edit", name: "Auto-accept edits", description: "Apply file edits without asking" },
              { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
              { id: "bypassPermissions", name: "Full access", description: "Run actions without approval" },
            ],
          },
        },
      }),
      play: async (ctx) => {
        await ctx.click({ selector: '[aria-label="Mode"]' });
        await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitemradio"]'));
      },
    },
    disconnected: {
      note: "The daemon connection dropped.",
      snapshot: chat(finished, { connection: "disconnected" }),
    },
  },
});
