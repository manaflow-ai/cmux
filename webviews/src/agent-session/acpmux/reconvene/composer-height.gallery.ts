// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `composer-height`: the chat composer at rest is too tall. Leo, 2026-11-08: "we need
// to not have our thing be so tall". Shipped since: #38402 (the Codex look's shorter row), the
// composer hat (#39818, #40084).
// Spec: leo-workspace design/composer.md "Tokens and spacing", "Bottom stack" and "In a short pane";
// design/grid.md 5.1 (box 48 = 10 + 28 + 10, quiet row 28 one 4 px foot gap under it).
// Measured from the shipped CSS, Claude's look (the default) in the floating dock: box 48
// (--grid-composer-box: 10 block inset + 28 control + 10), foot gap 4 (--grid-gap-foot), quiet row 28
// (--grid-composer-quiet-row-height), 8 under the row (composerLocation.css .acpmux-composer-foot
// margin-bottom; the composer's own 16 px padding is 0 there): 88 px from the box's top to the pane's
// bottom edge for an empty composer.
// Refs: claude/live/composer-model-effort-footer-row (the quiet row under the box: mode left, model,
// effort and ring right), chatgpt/live/composer-empty-placeholder-plus-button (an empty box with only +
// and the prompt), cursor/live/transcript-reasoning-expanded (a one-row follow-up box with the model
// picker inside its trailing edge, before the mic and Stop).
// Every variant draws an idle empty composer under a short chat (`<arm>`) and the same with a
// two-line draft (`<arm>-draft`).
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { arms, showArm, type Arm } from "./arm";

const snapshot = () => {
  const made = chat([
    user("Add retries to the fetch helper, with a backoff.", 4),
    assistant(
      "Added `withRetry` to `fetchJson`: three tries with a jittered backoff, only for network errors and 5xx answers.",
      3,
    ),
    summary(3, { status: "completed", durationMs: 38_000, toolCount: 2 }),
  ]);
  made.summary = {
    ...made.summary!,
    modes: {
      currentModeId: "default",
      availableModes: [
        { id: "default", name: "Ask before edits", description: "Review changes before they run" },
        { id: "acceptEdits", name: "Edit automatically", description: "Make edits without asking" },
      ],
    },
  };
  return made;
};
const DRAFT = "Also cover the 503 path in the tests,\nand keep the 404 test as it is.";

const DOCK = '.acpmux-main[data-dock="float"] > .acpmux-dock > .acpmux-composer';
const BOX = ".acpmux-composer-box[data-composer-grid]";
const FOOT = ".acpmux-composer-foot";
/// An empty prompt: its placeholder shows (MarkdownField hides it once there is a draft).
const EMPTY = ":has(.acpmux-md-placeholder:not([hidden]))";

export const ARMS: Record<string, Arm> = arms({
  /// The box's block inset 10 -> 8 (box 44), the quiet row 28 -> 24 with 24 px chips, 8 -> 4 under
  /// it: 76 px at rest. Same controls, same places.
  tight: {
    css: `
:is(.acpmux-dock, .acpmux-composer) { --acpmux-composer-block-inset: calc(8px * var(--cmux-interface-scale, 1)); }
.acpmux-composer { --grid-composer-quiet-row-height: calc(24px * var(--cmux-interface-scale, 1)); }
.acpmux-composer ${FOOT} { margin-bottom: 4px; }
.acpmux-composer ${FOOT} .acpmux-picker-button { height: 24px; }`,
    ready: FOOT,
  },
  /// An empty, unfocused composer is the box alone (+, the prompt, the mic) with 8 px under it: 56 px.
  /// Focus or a draft brings the quiet row back.
  "one-row": {
    css: `
.acpmux-composer:not(:focus-within)${EMPTY} ${FOOT} { display: none; }
${DOCK}:not(:focus-within)${EMPTY} { padding-bottom: 8px !important; }`,
    ready: ".acpmux-composer-box",
  },
  /// No quiet row: the mode, model, effort and ring stand in the box's last line, before the mic and
  /// Send; the prompt's text stops short of them. 48 + 8 = 56 px at rest.
  "bar-inside": {
    css: `
.acpmux-composer ${FOOT} {
  position: relative;
  z-index: calc(var(--layer-raised, 1) + 1);
  margin: calc(-1 * (var(--grid-composer-control) + var(--acpmux-composer-block-inset))) 0 var(--acpmux-composer-block-inset);
  padding-inline: 0 calc(var(--acpmux-actions-width, 64px) + var(--acpmux-composer-inset) + 4px);
  pointer-events: none;
}
.acpmux-composer ${FOOT} > * { pointer-events: auto; }
.acpmux-composer ${FOOT} .acpmux-access { order: 0; margin-inline: 0; }
${DOCK} { padding-bottom: 8px !important; }
.acpmux-composer ${BOX} > .acpmux-composer-field-menu > .acpmux-md-field {
  padding-right: calc(var(--acpmux-actions-width, 64px) + 40%) !important;
}
.acpmux-composer ${BOX} > .acpmux-composer-field-menu > .acpmux-md-field .acpmux-md-placeholder {
  right: calc(var(--acpmux-actions-width, 64px) + 40%);
}`,
    ready: FOOT,
  },
});

/// The composer at rest: drawn, and not focused (the pane focuses it on open; one-row keys on focus).
async function atRest(ctx: PlayContext, draft: boolean) {
  await ctx.waitFor(() =>
    ctx.document.querySelector(draft ? ".acpmux-md-placeholder[hidden]" : ".acpmux-md-placeholder:not([hidden])"),
  );
  (ctx.document.activeElement as HTMLElement | null)?.blur?.();
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-composer:focus-within"));
}

const variant = (arm: keyof typeof ARMS | "now", draft: boolean, note: string): AgentPaneVariant => ({
  note,
  ...(draft ? { ready: { draft: DRAFT } } : {}),
  snapshot: snapshot(),
  play: async (ctx) => {
    await atRest(ctx, draft);
    await showArm(ctx, arm === "now" ? { css: "" } : ARMS[arm]!);
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-composer-height",
  title: "Reconvene: the composer's resting height",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 420, normal: 760 },
  anchors: [{ selector: ".acpmux-composer-box" }],
  covers: [
    "agent-session/acpmux/ComposerBox.tsx",
    "agent-session/acpmux/ComposerFoot.tsx",
    "agent-session/acpmux/composerLocation.css",
  ],
  keywords: ["reconvene", "composer", "height", "quiet row", "tall"],
  variants: {
    now: variant(
      "now",
      false,
      "Shipped: 88 px at rest, the 48 px box (10 + 28 + 10), a 4 px gap, the 28 px quiet row (mode, model, effort, ring) and 8 px under it.",
    ),
    "now-draft": variant(
      "now",
      true,
      "Shipped with a two-line draft: the box grows by one line (20 px), the row stays under it.",
    ),
    tight: variant(
      "tight",
      false,
      "76 px: the box's block inset 8 (box 44) and a 24 px quiet row with 4 px under it. Every control stays where it is; the text sits closer to the box's edges and the chips' pills are shorter.",
    ),
    "tight-draft": variant("tight", true, "Tight with a two-line draft."),
    "one-row": variant(
      "one-row",
      false,
      "56 px when empty and unfocused: the box alone; the pickers come back on focus or with a draft. Shortest at rest, but the dock changes height when focus arrives, and the mode and model are out of sight until then.",
    ),
    "one-row-draft": variant("one-row", true, "One row with a draft: the quiet row is back, as shipped."),
    "bar-inside": variant(
      "bar-inside",
      false,
      "56 px: no quiet row; the mode, model and ring sit in the box's last line before the mic. One surface, always the same height; the prompt's line is shorter, and a narrow pane leans on the fit steps.",
    ),
    "bar-inside-draft": variant(
      "bar-inside",
      true,
      "Bar inside with a two-line draft: the pickers stay on the last line, the text stops short of them.",
    ),
  },
});
