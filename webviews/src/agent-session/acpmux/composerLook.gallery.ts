// l10n-allow-file: gallery fixtures (sample chats and prompts), not shipped UI.
// The composer's two looks (composerLook.ts, composerLook.css; Leo 2026-10-22: "first dot claude,
// second dot codex. since it's just all looks anyways. first 2 dots minimal on the new tab page, and
// then when you're in a chat you can also switch the dots if you hover on that bottom area"). The
// same chat and the same New Tab page in Claude's look (the first dot, the default: the composer as
// it was) and Codex's (the second dot), and the dots on hover in a chat's bottom area. Both looks lay
// the buttons out as Claude's (Leo 2026-11-01: "the placement of the buttons are just really bad
// compared to our claude code version", then "we already have a good version"); Codex's keeps its
// folder tray. The `codex-*-alt-*` variants are the other Codex layouts drawn for the pick
// (gallery-only CSS over the shipped one), the replaced in-box row among them.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, CWD, manySessions, noChat, user } from "../../gallery/fixtures/acpmux";
import { setComposerLook, type ComposerLook } from "./composerLook";

/// A started Claude Code chat in a project: the transcript over the composer. It reports its modes,
/// as a running Claude Code session does, so the mode chip (the permission capsule) draws in both looks.
const startedChat = () => {
  const snapshot = chat([
    user("Add retries to the fetch helper, with a backoff.", 12),
    assistant(
      "Added `withRetry` to `fetchJson`: three tries with jittered backoff, and only for network errors and 5xx answers. The tests cover a 503 that recovers and a 404 that does not retry.",
      11,
    ),
  ]);
  snapshot.summary = {
    ...snapshot.summary!,
    modes: {
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Ask before edits", description: "Review changes before they run" },
        { id: "acceptEdits", name: "Edit automatically", description: "Make edits without asking" },
        { id: "plan", name: "Plan", description: "Plan before making changes" },
      ],
    },
  };
  return snapshot;
};

/// A new chat before its first send: the folder and computer strip heads the composer.
const newChat = () => noChat(manySessions(4), { summary: { sessionId: "", cwd: CWD, harness: "codex" } });

const goalChat = (status: "active" | "paused") => {
  const snapshot = chat(startedChat().rows, { harness: "codex", model: "gpt-6-astra" });
  return {
    ...snapshot,
    summary: {
      ...snapshot.summary!,
      harness: "codex",
      goal: {
        objective: "Finish the timeout fix and verify the retry behavior",
        status,
        tokenBudget: 50000,
        tokensUsed: 12400,
      },
    },
  };
};

const speedNewTab = () => {
  const snapshot = newChat();
  snapshot.summary = { ...snapshot.summary!, model: "gpt-6.1-sol" };
  snapshot.catalog = snapshot.catalog.map((entry) =>
    entry.id === "codex"
      ? {
          ...entry,
          models: [
            {
              id: "gpt-6.1-sol",
              name: "GPT-6.1 Sol",
              fast: true,
              serviceTiers: [
                { id: "priority", name: "Fast" },
                { id: "ultrafast", name: "Ultrafast" },
              ],
            },
          ],
        }
      : entry,
  );
  return snapshot;
};

const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: { layout: "b", kind: "agent", cwd: CWD, home: "/Users/you", lastAgent: "claude", ...fields },
  newSession: true,
});

/// The look the variant draws (the choice is the page's, kept in storage, so every variant sets its
/// own), and an alternate layout's gallery-only rules.
const ALT_ID = "composer-look-alt";
async function look(ctx: PlayContext, which: ComposerLook, altCSS?: string) {
  ctx.document.getElementById(ALT_ID)?.remove();
  if (altCSS) {
    const style = ctx.document.createElement("style");
    style.id = ALT_ID;
    style.textContent = altCSS;
    ctx.document.head.append(style);
  }
  // Shown, not remembered: the stage never changes the look of the gallery's other entries.
  setComposerLook(which, { remember: false });
  await ctx.waitFor(() =>
    which === "codex"
      ? ctx.document.querySelector('[data-composer-look="codex"]')
      : !ctx.document.querySelector('[data-composer-look="codex"]'),
  );
}

type ComposerGlassLevel = keyof typeof COMPOSER_GLASS_LEVELS;
const COMPOSER_GLASS_LEVELS = {
  quiet: { opacity: 78, blur: "blur(16px) saturate(1.18)" },
  balanced: { opacity: 70, blur: "blur(24px) saturate(1.25)" },
  clear: { opacity: 64, blur: "blur(28px) saturate(1.15)" },
} as const;

/// A gallery-only wallpaper makes the material choice visible without shipping an art asset. The
/// same busy backdrop is used for each level, and the stage's light/dark theme changes its tones.
async function glassLevel(ctx: PlayContext, which: ComposerLook, level: ComposerGlassLevel) {
  await look(ctx, which);
  ctx.document.getElementById("composer-glass-gallery")?.remove();
  const root = ctx.document.documentElement;
  root.removeAttribute("data-cmux-see-through");
  const style = ctx.document.createElement("style");
  style.id = "composer-glass-gallery";
  const { opacity, blur } = COMPOSER_GLASS_LEVELS[level];
  style.textContent = `
    html, body { background: transparent !important; }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: var(--layer-base, 0);
      pointer-events: none;
      background:
        radial-gradient(circle at 18% 22%, light-dark(rgb(255 146 90 / 0.78), rgb(220 68 90 / 0.62)) 0 14%, transparent 42%),
        radial-gradient(circle at 82% 72%, light-dark(rgb(65 142 255 / 0.62), rgb(54 178 218 / 0.64)) 0 16%, transparent 44%),
        linear-gradient(135deg, light-dark(#e7edf3, #1b2432) 0%, light-dark(#f8eee5, #34203f) 52%, light-dark(#dce8f5, #102f40) 100%);
    }
    body::after {
      content: "";
      position: fixed;
      inset: 0;
      z-index: var(--layer-base, 0);
      pointer-events: none;
      opacity: 0.34;
      background: repeating-linear-gradient(118deg, transparent 0 22px, light-dark(rgb(255 255 255 / 0.72), rgb(255 255 255 / 0.22)) 23px 24px, transparent 25px 48px);
    }
    .acpmux-shell { position: relative; z-index: var(--layer-raised, 1); background: transparent !important; }
    :root:not([data-reduce-transparency]) .acpmux-composer > :is(.acpmux-composer-box, .acpmux-composer-strip) {
      --glass-tint: color-mix(in srgb, var(--acpmux-composer-solid) ${opacity}%, transparent);
      --glass-backdrop: ${blur};
    }
  `;
  ctx.document.head.append(style);
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box"));
}

/// Alternate B: the strip stays plain text over the box, as Claude's look draws it; only the row moves.
const ALT_PLAIN_STRIP = `
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-strip,
.nt-composer[data-composer-look="codex"] .nt-above .acpmux-composer-strip { all: revert-layer; }`;
/// Alternate C: the tray, and the row's controls as quiet text with no mode glyph (Codex's model text).
const ALT_TEXT_ROW = `
:is(.acpmux-composer, .nt-composer)[data-composer-look="codex"] .acpmux-access .acpmux-icon { display: none; }
:is(.acpmux-composer, .nt-composer)[data-composer-look="codex"] :is(.acpmux-model, .acpmux-effort) .acpmux-picker-button { color: var(--agent-soft); }`;

/// Replaced (cmux #28901's in-box row, last good commit 8b44a8a1dc2): + and the mode left, the ring,
/// the model, the mic and Send right, in one 52 px row inside the box under the prompt. Drawn here
/// with gallery-only CSS over today's DOM (the quiet row pulled up into the box's last row), close to
/// the replaced layout, not pixel-exact.
const ALT_IN_BOX_ROW = `
.acpmux-main .acpmux-dock > .acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box:has(> .acpmux-chrome-area > .acpmux-composer-inner):has(> .acpmux-composer-field-menu) { grid-template-rows: auto auto 52px; }
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box > .acpmux-composer-field-menu > * { grid-column: 1 / -1; }
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box .acpmux-md-field { padding-left: 16px; }
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box .acpmux-md-placeholder { left: 16px; }
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box .acpmux-composer-inner > .acpmux-composer-plus { grid-row: 3; align-self: center; margin: 0 0 0 12px; }
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box .acpmux-composer-inner > .acpmux-composer-actions { grid-row: 3; align-self: center; margin: 0 12px 0 0; }
.acpmux-composer[data-composer-look="codex"] > .acpmux-chrome-area > .acpmux-composer-foot {
  position: relative; z-index: calc(var(--layer-raised, 1) + 1); height: 52px; margin: -52px 0 0; padding-inline: 50px 84px;
}
.acpmux-composer[data-composer-look="codex"] > .acpmux-chrome-area > .acpmux-composer-foot .acpmux-access { margin-inline-start: 0; }`;

/// The send control's designs (Leo 2026-10-31: "THE F***ING TWO SEND BUTTONS", then "THIS IS THE
/// BUTTON FOR CLAUDE BUT / WE CAN THINK ABOUT WHAT'S BEST"). The pick, one control in both looks: a
/// slot that is Stop while a turn runs and the prompt is empty, and Send (steer or queue, as Return
/// does) from the first letter. Claude's look draws it before the mic with Claude desktop's ↵ (the
/// mic keeps the right edge through a turn); Codex's draws Send's ↑ after the mic, as Codex does.
/// The alternates are gallery-only CSS over it. Stop beside a second send control (the two-button
/// state this replaced) is never drawn.
const runningChat = () => {
  const snapshot = startedChat();
  return { ...snapshot, isWorking: true, summary: { ...snapshot.summary!, steering: true } };
};
const DRAFT = { draft: "Also cover the 503 path" };
const ALT_AFTER_MIC = `
.acpmux-composer-actions > :is(.acpmux-send, .acpmux-cancel) { order: 1; }`;
const ALT_FILLED_DISC = `
.acpmux-composer-actions > .acpmux-send.acpmux-send-ready:not(.acpmux-cancel) {
  border-radius: 999px; background: var(--agent-text); color: var(--agent-bg, Canvas);
}`;

const chatHeight = 360;

export default agentPaneEntry({
  id: "agent-pane.composer-look",
  title: "Composer looks (Claude, Codex)",
  area: "Agent pane",
  height: chatHeight,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: [
    "agent-session/acpmux/composerLook.ts",
    "agent-session/acpmux/composerFooterShared.css",
    "agent-session/acpmux/LookSwitch.tsx#LookSwitch",
    "agent-session/acpmux/newtab/PageDots.tsx#PageDots",
    "agent-session/acpmux/newtab/StyleSwitch.tsx#DotSwitch",
  ],
  variants: {
    "goal-active": {
      note: "A persisted Codex goal between turns; Pause and Clear use the same /goal command path.",
      snapshot: goalChat("active"),
      play: (ctx) => look(ctx, "claude"),
    },
    "goal-paused": {
      note: "A paused goal remains visible when the conversation reopens.",
      snapshot: goalChat("paused"),
      play: (ctx) => look(ctx, "codex"),
    },
    "newtab-codex-speed": {
      note: "Fast and Ultrafast are available before the first prompt, from the model's advertised tiers.",
      height: 520,
      ready: newTab(),
      snapshot: speedNewTab(),
      play: (ctx) => look(ctx, "codex"),
    },
    "claude-chat": {
      note: "The first dot, Claude's look (the default): the composer as it was, the mode, model and effort in the quiet row under the box.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "claude"),
    },
    "permission-pill-claude": {
      note: "Claude's permission capsule hovered: the shared 8px inset, 28px height and full radius match Codex.",
      snapshot: startedChat(),
      play: async (ctx) => {
        await look(ctx, "claude");
        await ctx.hover({ selector: ".acpmux-access-trigger" });
      },
    },
    "permission-pill-codex": {
      note: "Codex's permission capsule hovered: the same dimensions, 16px after the + glyph.",
      snapshot: startedChat(),
      play: async (ctx) => {
        await look(ctx, "codex");
        await ctx.hover({ selector: ".acpmux-access-trigger" });
      },
    },
    "claude-chat-dots": {
      note: "Claude's look with the pointer in the quiet row's empty middle: the two dots show there, Claude marked.",
      snapshot: startedChat(),
      play: async (ctx) => {
        await look(ctx, "claude");
        await ctx.hover({ selector: ".acpmux-composer-foot" });
      },
    },
    "codex-chat": {
      note: "The second dot, Codex's look (the pick): Claude's button layout, + left of the prompt, the mic right of it, the mode, model, effort and ring in the quiet row under the box.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-chat-alt-in-box-row": {
      note: "Replaced (cmux #28901, last good commit 8b44a8a1dc2): Codex's own 52 px row in the box under the prompt. Replaced on Leo's \"we already have a good version\" (2026-11-01). Gallery-only CSS, close to the old layout.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", ALT_IN_BOX_ROW),
    },
    "codex-chat-alt-send-after-mic": {
      note: "Alternate (not shipped): the pick with Codex's send slot after the mic. Not picked: the mic would step left whenever a turn starts or a prompt is typed, and Leo's good version keeps it at the edge.",
      snapshot: runningChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "codex", ALT_AFTER_MIC),
    },
    "codex-chat-dots": {
      note: "Codex's look with the pointer in the quiet row's empty middle: the two dots show there, Codex marked.",
      snapshot: startedChat(),
      play: async (ctx) => {
        await look(ctx, "codex");
        await ctx.hover({ selector: ".acpmux-composer-foot" });
      },
    },
    "composer-glass-quiet-claude": {
      note: "Glass level A: the previous 78% tint and a 16px blur, shown over a busy backdrop for comparison.",
      snapshot: startedChat(),
      play: (ctx) => glassLevel(ctx, "claude", "quiet"),
    },
    "composer-glass-balanced-claude": {
      note: "Glass level B (recommended): a 70% tint and 24px blur keep the background present while preserving AA text contrast.",
      snapshot: startedChat(),
      play: (ctx) => glassLevel(ctx, "claude", "balanced"),
    },
    "composer-glass-clear-claude": {
      note: "Glass level C: a clearer 64% tint and 28px blur; included for comparison, but the bright-underlay contrast is too close for the default.",
      snapshot: startedChat(),
      play: (ctx) => glassLevel(ctx, "claude", "clear"),
    },
    "composer-glass-balanced-codex": {
      note: "The recommended 70% tint and 24px blur in Codex's look, over the same busy backdrop.",
      snapshot: startedChat(),
      play: (ctx) => glassLevel(ctx, "codex", "balanced"),
    },
    "codex-new-chat": {
      note: "Codex's look on a new chat (the pick): the folder and computer strip a tray tucked under the box's top edge, as Codex's.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-new-chat-alt-plain-strip": {
      note: "Alternate B (not shipped): Codex's row, but the strip stays plain text over the box as in Claude's look.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: (ctx) => look(ctx, "codex", ALT_PLAIN_STRIP),
    },
    "codex-new-chat-alt-text-row": {
      note: "Alternate C (not shipped): the tray, and the row as quiet text with no mode glyph.",
      ready: { newSession: true, cwd: CWD },
      snapshot: newChat(),
      play: (ctx) => look(ctx, "codex", ALT_TEXT_ROW),
    },
    "send-one-slot-claude-running": {
      note: "The pick, Claude's look: a turn running with an empty prompt, the one send slot before the mic is Stop; the mic keeps the right edge.",
      snapshot: runningChat(),
      play: (ctx) => look(ctx, "claude"),
    },
    "send-one-slot-claude-typed": {
      note: "The pick, Claude's look: the first letter turns Stop's slot into Send, Claude desktop's ↵, which steers the turn as Return does (⌘Return queues). One send control, never two.",
      snapshot: runningChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "claude"),
    },
    "send-one-slot-codex-running": {
      note: "The pick, Codex's look: the same one slot before the mic as Claude's, Stop while the prompt is empty.",
      snapshot: runningChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "send-one-slot-codex-typed": {
      note: "The pick, Codex's look: Send (↵) in the same slot once a prompt is typed.",
      snapshot: runningChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "codex"),
    },
    "send-alt-after-mic-claude": {
      note: "Alternate (not shipped): Claude's look with the slot after the mic, as Codex's. Not picked: the mic would step left each time a turn starts or a prompt is typed.",
      snapshot: runningChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "claude", ALT_AFTER_MIC),
    },
    "send-alt-filled-disc": {
      note: "Alternate (not shipped): Codex's filled disc after the mic. Not picked: the composer draws plain glyphs, no discs (Leo 2026-10-21), and the slot stays before the mic.",
      snapshot: runningChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "codex", ALT_FILLED_DISC),
    },
    "newtab-claude": {
      note: "New Tab, the first dot (Claude Minimal, the default): the Minimal page as it was, with the three dots under it.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "claude"),
    },
    "newtab-codex": {
      note: "New Tab, the third dot (Codex Minimal): the same page with Codex's composer, the third dot marked.",
      height: 520,
      ready: newTab(),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "codex"),
    },
    "newtab-classic-codex": {
      note: "Classic New Tab with Codex's look: the page stays Classic (its dot marked among the styles), its box's row in the same order as Claude's look.",
      height: 520,
      ready: newTab({ template: "classic" }),
      snapshot: noChat(manySessions(4)),
      play: (ctx) => look(ctx, "codex"),
    },
    "newtab-cards-codex": {
      note: "Cards New Tab with Codex's look: the project strip is Codex's tray over the box, the model in the quiet row under it as Claude's look, the chat cards under it.",
      height: 560,
      ready: newTab({ template: "cards" }),
      snapshot: noChat(manySessions(6)),
      play: (ctx) => look(ctx, "codex"),
    },
  },
});
