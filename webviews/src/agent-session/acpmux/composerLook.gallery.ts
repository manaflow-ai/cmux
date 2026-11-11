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
import { GALLERY_NOW, minutesAgo } from "../../gallery/clock";
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { activity, assistant, chat, CWD, manySessions, noChat, tool, user } from "../../gallery/fixtures/acpmux";
import wallpaper from "../../gallery/fixtures/assets/liquid-glass-wallpaper.jpg?inline";
import { setComposerLook, type ComposerLook } from "./composerLook";
import type { TaskGoal } from "./goal";

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

const goalChat = (status: "running" | "stalled" | "paused" | "done", provider: "codex" | "claude" = "codex") => {
  const snapshot = chat(startedChat().rows, { harness: "codex", model: "gpt-6-astra" });
  return {
    ...snapshot,
    summary: {
      ...snapshot.summary!,
      harness: provider,
      goal: {
        objective: "Finish the timeout fix and verify the retry behavior",
        status,
        provider,
        startedAt: 1_700_000_000_000,
        updatedAt: status === "done" ? 1_700_000_012_000 : 1_700_000_006_000,
        ...(status === "done" ? { endedAt: 1_700_000_012_000 } : {}),
        detail: provider === "claude" ? "Loop: check, test, and refine until the goal is met" : undefined,
        steps:
          provider === "claude"
            ? [
                { label: "Inspect the failing request", status: "done" },
                { label: "Add the retry and run tests", status: status === "done" ? "done" : "running" },
              ]
            : undefined,
        tokenBudget: 50000,
        tokensUsed: 12400,
      },
    },
  };
};

/// A Claude Code /loop between its runs (acpmux reads it from ScheduleWakeup and CronCreate,
/// `claude_stdio/loops.rs`): the goal strip says when it checks back, or its schedule; its prompt
/// only on demand.
const loopChat = (goal: Omit<TaskGoal, "kind" | "status">) => {
  const snapshot = startedChat();
  return {
    ...snapshot,
    summary: { ...snapshot.summary!, goal: { kind: "loop" as const, status: "active" as const, ...goal } },
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

type MaterialStage = "plain" | "lens" | "reduce";
/// The shared glass material (glass.css, "GLASS MATERIAL"; Leo 2026-11-05 on the Dock beside our
/// composer: "the glass is a pretty big deal"), on a see-through window over the colorful wallpaper
/// fixture, as a window over art draws it: the picture and a light window wash behind a clear page,
/// and the same still sent to the glass lens. Plain is what ships; Lens is the opt-in Debug choice
/// that bends the picture at the rim; Reduce Transparency is the solid fallback. A capture's "before"
/// removes .ui-glass-material from the card (scripts/agent-pane/capture-composer-material.mjs).
async function materialStage(ctx: PlayContext, mode: MaterialStage) {
  await look(ctx, "claude");
  ctx.document.getElementById("composer-material-gallery")?.remove();
  const root = ctx.document.documentElement;
  root.setAttribute("data-cmux-see-through", "");
  root.setAttribute("data-glass", mode === "reduce" ? "plain" : mode);
  root.toggleAttribute("data-reduce-transparency", mode === "reduce");
  root.style.setProperty("--cmux-surface-background", "transparent");
  root.style.setProperty("--agent-page-bg", "transparent");
  const style = ctx.document.createElement("style");
  style.id = "composer-material-gallery";
  style.textContent = `
    html {
      background:
        linear-gradient(light-dark(rgb(255 255 255 / 0.16), rgb(0 0 0 / 0.18))),
        url("${wallpaper}") center / cover no-repeat fixed !important;
    }
    body, .acpmux-shell { background: transparent !important; }
  `;
  ctx.document.head.append(style);
  const host = ctx.document.defaultView as unknown as { cmuxTheme?: { backdrop?: (value: unknown) => void } };
  host.cmuxTheme?.backdrop?.({
    image: wallpaper,
    key: "gallery-composer-material",
    rect: { x: 0, y: 0, width: root.clientWidth, height: root.clientHeight },
    blur: 0,
    tint: "transparent",
  });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-box.ui-glass-material"));
}

/// The composer hat over the card, as Leo's image of 2026-11-05 shows it: three background commands
/// run, so the hat draws a card joined to the composer as one glass (bottomStack.css).
const HAT_COMMANDS = [
  "mkdir -p webviews/test/browser",
  "bun test test/composer-hat-material.test.ts",
  "git push -q origin HEAD:lane/composer-strip-glass",
];
const hatChat = () => {
  const snapshot = startedChat();
  const commands = activity(
    HAT_COMMANDS.map((command, index) =>
      tool(command, "execute", "completed", {
        inputSummary: JSON.stringify({ command, run_in_background: true }),
        startedAt: minutesAgo(15.35 - index),
      }),
    ),
    15.35,
  );
  return { ...snapshot, rows: [...snapshot.rows, commands], isWorking: true };
};
/// The joined stack in the glass material over the wallpaper: the pick lights the hat's top and drops
/// the card's top light at the join. The alternates are gallery-only CSS over it.
async function hatMaterialStage(ctx: PlayContext, css = "") {
  await materialStage(ctx, "plain");
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-dock > .acpmux-running-tray[data-card]"));
  ctx.document.getElementById("composer-hat-material-gallery")?.remove();
  if (!css) return;
  const style = ctx.document.createElement("style");
  style.id = "composer-hat-material-gallery";
  style.textContent = css;
  ctx.document.head.append(style);
}
const HAT_FLAT = `.acpmux-dock > .acpmux-running-tray[data-card] {
  box-shadow:
    inset 0 var(--cmux-hairline, 0.5px) 0 var(--acpmux-composer-edge, transparent),
    inset var(--cmux-hairline, 0.5px) 0 0 var(--acpmux-composer-edge, transparent),
    inset calc(-1 * var(--cmux-hairline, 0.5px)) 0 0 var(--acpmux-composer-edge, transparent) !important;
  --acpmux-tray-frost: var(--ds-glass-popover-blur) !important;
}`;
const CARD_LIT = `.acpmux-dock > .acpmux-running-tray[data-card] + .acpmux-composer > .acpmux-composer-box.ui-glass-material {
  --acpmux-composer-rim: var(--glass-material-rim) !important;
}`;
/// Before (base): the hat a flat hairline box, the card's bright top line across the stack's middle.
const HAT_BEFORE = HAT_FLAT + CARD_LIT;
/// Alternate: both lit, the hat's top and the card's top at the join.
const HAT_BOTH_LIT = CARD_LIT;
/// Alternate: the pick, and the hat casts the material's depth as well.
const HAT_DEPTH = `.acpmux-dock > .acpmux-running-tray[data-card] {
  box-shadow:
    inset 0 var(--cmux-hairline, 0.5px) 0 var(--acpmux-composer-edge, transparent),
    inset var(--cmux-hairline, 0.5px) 0 0 var(--acpmux-composer-edge, transparent),
    inset calc(-1 * var(--cmux-hairline, 0.5px)) 0 0 var(--acpmux-composer-edge, transparent),
    inset 0 var(--cmux-hairline, 0.5px) 0 0 var(--acpmux-tray-specular),
    inset 1px 1.5px 1px -1px var(--acpmux-tray-specular),
    inset 0 16px 20px -16px var(--acpmux-tray-sheen),
    var(--glass-material-depth) !important;
}`;

/// The composer's depth (Leo 2026-11-06, the hat over the composer: "Is there a way to make this less
/// glass, or maybe less shadow? ... Probably just a little bit more subtle."). The pick is the shipped
/// --glass-material-depth-composer; the others are gallery-only overrides of the card's shadow.
const depthCss = (depth: string) => `.acpmux-composer > .acpmux-composer-box.ui-glass-material {
  --acpmux-composer-shadow: ${depth} !important;
}`;
/// Before (base): the floating glass's full two-step depth.
const DEPTH_BEFORE = depthCss("var(--glass-material-depth)");
/// Alternate: only the near step, no soft spread under the card.
const DEPTH_NEAR_ONLY = depthCss(
  "0 1px 3px -1px light-dark(color-mix(in srgb, black 7%, transparent), color-mix(in srgb, black 20%, transparent))",
);
/// Alternate: no depth at all; the card is the hairline and its light.
const DEPTH_NONE = depthCss("0 0 transparent");

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
/// mic keeps the right edge through a turn); Codex's draws Send's ↑ on a disc after the mic, as Codex does.
/// The alternates are gallery-only CSS over it. Stop beside a second send control (the two-button
/// state this replaced) is never drawn.
const runningChat = () => {
  const snapshot = startedChat();
  return { ...snapshot, isWorking: true, summary: { ...snapshot.summary!, steering: true } };
};
const DRAFT = { draft: "Also cover the 503 path" };
const ALT_AFTER_MIC = `
.acpmux-composer-actions > :is(.acpmux-send, .acpmux-cancel) { order: 1; }`;
/// Codex's Send (composerLook.css, the pick: the accent disc after the mic). The alternates: ChatGPT's
/// disc in the text colour, and the plain ↑ glyph Codex's look drew before (#23763's no-disc rule).
const ALT_TEXT_DISC = `
.acpmux-composer[data-composer-look="codex"] .acpmux-send.acpmux-send-ready:not(.acpmux-cancel, :disabled) {
  background: var(--agent-text); color: var(--agent-page-bg, Canvas);
}`;
const ALT_PLAIN_GLYPH = `
.acpmux-composer[data-composer-look="codex"] .acpmux-send,
.acpmux-composer[data-composer-look="codex"] .acpmux-send.acpmux-send-ready:not(.acpmux-cancel, :disabled) {
  background: transparent; color: var(--agent-muted);
}`;

/// Codex's box height and the room under its row (Leo 2026-11-08: "we need to not have our thing be
/// so tall maybe but also put the context ring to the left of the model picker and also have more
/// padding on the bottom aka the composer simply doesn't have so little space at the bottom"). Each
/// arm sets the prompt's top, the prompt-to-row gap and the room under the row (composerLook.css
/// tokens), all on the 4 px grid; `codex-height-floor-16` (balanced, 16 px under the box) is what ships. Refs
/// codex/live/composer-codex-empty-input-controls and chatgpt/live/composer-empty-placeholder-plus-button.
const codexSpacing = (top: number, gap: number, bottom: number, floor?: number) => `
.acpmux-composer[data-composer-look="codex"] {
  --acpmux-codex-prompt-top: calc(${top}px * var(--cmux-interface-scale, 1));
  --acpmux-codex-prompt-gap: calc(${gap}px * var(--cmux-interface-scale, 1));
  --acpmux-codex-row-bottom: calc(${bottom}px * var(--cmux-interface-scale, 1));
}${
  floor === undefined
    ? ""
    : `
.acpmux-main[data-dock="float"] > .acpmux-dock > .acpmux-composer[data-composer-look="codex"]:has(> .acpmux-composer-box > .acpmux-chrome-area > .acpmux-composer-foot) { padding-bottom: ${floor}px; }`
}`;
/// Replaced: the ring after the model (its place before Leo's 2026-11-08 ask).
const ALT_RING_AFTER_MODEL = `
.acpmux-composer[data-composer-look="codex"] > .acpmux-composer-box > .acpmux-chrome-area > .acpmux-composer-foot .acpmux-context { order: 0; }`;
/// A one-line draft the grow check (test/composer-grow-no-thumb.test.ts) adds a line to.
const GROW_DRAFT = { draft: "Also cover the 503 path" };

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
    "agent-session/acpmux/TaskGoalStrip.tsx#TaskGoalStrip",
    "agent-session/acpmux/newtab/PageDots.tsx#PageDots",
    "agent-session/acpmux/newtab/StyleSwitch.tsx#DotSwitch",
  ],
  variants: {
    "goal-active": {
      note: "A running Codex goal heads the composer hat; its elapsed time and chevron stay in one row, and pause, edit and delete fade in over the cut objective on hover.",
      snapshot: goalChat("running"),
      play: (ctx) => look(ctx, "claude"),
    },
    "goal-paused": {
      note: "A paused goal remains visible when the conversation reopens.",
      snapshot: goalChat("paused"),
      play: (ctx) => look(ctx, "codex"),
    },
    "goal-stalled": {
      note: "A stalled Codex goal keeps its objective and elapsed time visible so the user can resume it without losing context.",
      snapshot: goalChat("stalled"),
      play: (ctx) => look(ctx, "codex"),
    },
    "goal-done": {
      note: "A completed goal keeps a short-lived receipt with its elapsed duration and no misleading resume control.",
      snapshot: goalChat("done"),
      play: (ctx) => look(ctx, "claude"),
    },
    "claude-loop-steps": {
      note: "Claude's /loop is projected into the same goal row; opening it in place shows its checklist for step-by-step plans.",
      snapshot: goalChat("running", "claude"),
      play: async (ctx) => {
        await look(ctx, "claude");
        await ctx.click({ selector: ".acpmux-goal-toggle" });
      },
    },
    "loop-wakeup": {
      note: "A self-paced Claude Code /loop (ScheduleWakeup), cmux#38051: one quiet chip in the composer's column, \"Checking back in 15 min.\". The agent's wake prompt (job ids, links, steps) is only in the tooltip and behind the chip's button. No controls: Claude stops a loop only from its own turn.",
      snapshot: loopChat({
        objective:
          "Check background job b2mqa7gwr (fleet build 38051-hide-looping-wake-prompt) and https://github.com/manaflow-ai/cmux/pull/38052. Steps: 1. read the job log 2. if green, run the second bun run check 3. post the receipt on the PR 4. schedule the next wakeup",
        reason: "watching the fleet build",
        nextRunAt: GALLERY_NOW + 15 * 60_000,
      }),
      play: (ctx) => look(ctx, "claude"),
    },
    "loop-wakeup-open": {
      note: "The same loop with its prompt opened on demand: it wraps inside the column and scrolls past six lines.",
      snapshot: loopChat({
        objective:
          "Check background job b2mqa7gwr (fleet build 38051-hide-looping-wake-prompt) and https://github.com/manaflow-ai/cmux/pull/38052. Steps: 1. read the job log 2. if green, run the second bun run check 3. post the receipt on the PR 4. schedule the next wakeup",
        reason: "watching the fleet build",
        nextRunAt: GALLERY_NOW + 15 * 60_000,
      }),
      play: async (ctx) => {
        await look(ctx, "claude");
        await ctx.click({ selector: ".acpmux-goal[data-kind=loop] .acpmux-goal-action" });
      },
    },
    "loop-cron": {
      note: 'An interval /loop (CronCreate): its schedule as Claude Code words it, "Repeats every 5 minutes".',
      snapshot: loopChat({ objective: "/babysit-prs", schedule: "every 5 minutes", nextRunAt: GALLERY_NOW + 90_000 }),
      play: (ctx) => look(ctx, "claude"),
    },
    "loop-autonomous": {
      note: "An autonomous /loop (no prompt of the person's), in Codex's look.",
      snapshot: loopChat({ objective: "", autonomous: true, nextRunAt: GALLERY_NOW + 25_000 }),
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
      note: "The second dot, Codex's look: ChatGPT's full-width prompt over one lower controls row, with + and the mode left and the context ring, the model, the mic, then Codex's round Send, right. Every mode, model and context control stays inside the box.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-chat-spacing-compact": {
      note: "Spacing A: 16px after the prompt. Compact, but the placeholder and lower controls are closer than ChatGPT's reference.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(16, 16, 8)),
    },
    "codex-chat-spacing-balanced": {
      note: "Spacing B (#34709's pick, replaced by codex-height-balanced): 24px after the prompt, 16px above it, + and the trailing actions 8px from the lower edges. Reference: chatgpt/live/composer-empty-placeholder-plus-button.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(16, 24, 8, 8)),
    },
    "codex-chat-spacing-airy": {
      note: "Spacing C: 32px after the prompt. More empty space than the reference without improving the control row's separation.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(16, 32, 8)),
    },
    "codex-height-before": {
      note: "Replaced: the empty box 98.75 px tall, the prompt 16 px under the top, 24 px to the row and the row 8 px over the bottom edge (#34709). Leo 2026-11-08: too tall, too little room at the bottom.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(16, 24, 8, 8)),
    },
    "codex-height-tight": {
      note: "Arm A: 12 px top, 12 px to the row, 12 px under it (86.75 px). Shortest, but the placeholder crowds the row it heads.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(12, 12, 12)),
    },
    "codex-height-balanced": {
      note: "Arm B: 12 px top, 16 px to the row, 12 px under it (90.75 px, 8 px shorter), the box 8 px over the pane's bottom as before. The row has as much room under it as the prompt over it, and the prompt still reads as its own line.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(12, 16, 12, 8)),
    },
    "codex-height-roomy": {
      note: "Arm C: 12 px top, 20 px to the row, 16 px under it (98.75 px, as tall as before). The most room under the row, but no shorter.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", codexSpacing(12, 20, 16)),
    },
    "codex-height-floor-16": {
      note: "Arm D (the pick, shipped): arm B with the box 16 px over the pane's bottom (was 8): the reference's box stands about twice as high over its window's edge as ours did.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-ring-alt-after-model": {
      note: 'Replaced: the ring after the model, before the mic. Leo 2026-11-08: "put the context ring to the left of the model picker".',
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex", ALT_RING_AFTER_MODEL),
    },
    "codex-grow-line": {
      note: "A one-line draft in Codex's look; Shift-Return adds a line and the field grows to fit it with no scrollbar thumb on the way (test/composer-grow-no-thumb.test.ts).",
      snapshot: startedChat(),
      ready: GROW_DRAFT,
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
    "composer-material-plain": {
      note: "The shared glass material (Plain, what ships) over the colorful wallpaper on a see-through window: the specular rim lit from above-left, the sheen under the top edge, the soft shadow, and a frost that keeps the colors vivid.",
      snapshot: startedChat(),
      play: (ctx) => materialStage(ctx, "plain"),
    },
    "composer-hat-material": {
      note: "The pick for Leo's image (2026-11-05, the hat over the composer): the hat and the card are one glass, lit once from above. The hat's top takes the card's specular line, corner band and sheen, its frost is the card's vivid one, and the card gives up its own top light at the join, keeping the hairline there and its return along the bottom.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx),
    },
    "composer-hat-material-before": {
      note: "Before (base): the hat a flat box with a hairline top and the popover frost, and the card's bright top line and sheen running across the middle of the stack, under the hat.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx, HAT_BEFORE),
    },
    "composer-hat-material-alt-both-lit": {
      note: "Alternate: the hat's top lit and the card keeps its own top light too, so a second bright line divides the one glass.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx, HAT_BOTH_LIT),
    },
    "composer-hat-material-alt-depth": {
      note: "Alternate: the pick, and the hat casts the material's depth too; through the clear card under it the shadow reads as a smudge at the join.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx, HAT_DEPTH),
    },
    "composer-depth": {
      note: "The pick for Leo's 2026-11-06 ask (\"less shadow ... a little bit more subtle\"): the card casts the material's two steps at about half the reach and half the dark (glass.css --glass-material-depth-composer), so it rests on the pane instead of floating off it. The rim stays as #37594 and #39400 left it.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx),
    },
    "composer-depth-before": {
      note: "Before (base): the floating glass's full depth under the docked card, 0 12px 32px at 55% black in a dark theme, a dark smear below the stack.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx, DEPTH_BEFORE),
    },
    "composer-depth-alt-near-only": {
      note: "Alternate: only the near step, a 1 px contact shadow; over art the card loses most of its lift from the wallpaper.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx, DEPTH_NEAR_ONLY),
    },
    "composer-depth-alt-none": {
      note: "Alternate: no depth; the card is its hairline and light alone, and over a bright wallpaper its bottom edge disappears.",
      snapshot: hatChat(),
      play: (ctx) => hatMaterialStage(ctx, DEPTH_NONE),
    },
    "composer-material-lens": {
      note: "The same card in the opt-in Lens (Debug choice glass.lens): the lens bends the wallpaper at the rim and draws its own specular light; the material adds the depth.",
      snapshot: startedChat(),
      play: (ctx) => materialStage(ctx, "lens"),
    },
    "composer-material-reduce-transparency": {
      note: "Reduce Transparency over the same wallpaper: the solid card with its hairline ring, no frost and no specular band.",
      snapshot: startedChat(),
      play: (ctx) => materialStage(ctx, "reduce"),
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
      note: "The pick, Codex's look: the one slot after the mic on its disc, Stop while the prompt is empty.",
      snapshot: runningChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "send-one-slot-codex-typed": {
      note: "The pick, Codex's look: Send (↑ on the accent disc) in the same slot once a prompt is typed.",
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
    "codex-send-accent-disc": {
      note: "Codex's Send (the pick): the ↑ on the accent disc after the mic, as Codex and ChatGPT draw it (Leo 2026-11-04: \"our codex style composer should look like codex's/chatgpt's\"). Ref codex/live/composer-codex-empty-input-controls.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-send-empty": {
      note: "Codex's Send with nothing to send: the soft disc and the dimmed ↑ stay after the mic, so the mic never steps.",
      snapshot: startedChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-send-stop": {
      note: "Codex's slot mid-turn with an empty prompt: Stop's square on the soft disc.",
      snapshot: runningChat(),
      play: (ctx) => look(ctx, "codex"),
    },
    "codex-send-alt-text-disc": {
      note: "Alternate (not shipped): ChatGPT's disc in the text colour. Not picked: Codex's own composer, the look's namesake, uses its accent.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "codex", ALT_TEXT_DISC),
    },
    "codex-send-alt-plain-glyph": {
      note: "Replaced: Codex's look drew Send as a plain glyph (no disc, #23763). Kept for comparison.",
      snapshot: startedChat(),
      ready: DRAFT,
      play: (ctx) => look(ctx, "codex", ALT_PLAIN_GLYPH),
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
