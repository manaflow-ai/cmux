// l10n-allow-file: gallery fixtures (a sample chat and draft), not shipped UI.
// Where the composer's draft scrollbar sits (Leo 2026-10-22: "shouldn't the styling wrt composer vs
// the chat/window (these should be one and hte same) be more cohesive? well idk but the
// chatgpt(codex) has it on the outside while claude indeed has it on the inside"). The same long draft
// in Claude's look with the thumb:
//   - `lane`, shipped: in a lane between the draft and the mic and Send, down to the box's bottom
//     inset, as Claude desktop draws it (Leo 2026-11-22, his clip of Claude: "IT ACTUALLY GOES IN A
//     REASONABLE LOOKING PLACE, INSTEAD OF OUR THUMB THAT STOPS ATOP BUTTONS"; composerLocation.css);
//   - `edge`: down the box's own right edge, ending a block inset above the button row (shipped
//     before: its end sat on the buttons' tops);
//   - `edge-full`: down the box's right edge for its full height, beside the mic and Send;
//   - `outside`: just outside the box's right edge, in the column's gutter, as Codex desktop.
// The alternates are gallery-only CSS over the shipped rules. The thumb shows only while the draft
// scrolls (Leo 2026-11-22: "the thumb only appears when it's relevant"), so each variant
// draws it as it scrolls: the field carries the scrolling mark (scrollers.ts SCROLLING_ATTRIBUTE)
// until a real scroll's timer clears it.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { COMPOSER_MD_FIELD } from "./composerSelectors";
import { SCROLLING_ATTRIBUTE } from "../../scrollers";

const BOX = ".acpmux-composer-box[data-composer-grid]";
const FIELD = `${BOX} > .acpmux-composer-field-menu > .acpmux-md-field`;
const SCALE = "var(--cmux-interface-scale, 1)";
// The right edge: the prompt spans the actions' column too, its padding giving that column back.
const EDGE = `${FIELD} { grid-column: 2 / -1; margin-right: calc(2px * ${SCALE}); padding-right: calc(var(--acpmux-actions-width, 64px) + var(--acpmux-composer-lead-gap) + max(0px, calc(8px * ${SCALE} - var(--cmux-scroller-size, 8px)))); }
${FIELD} .acpmux-md-placeholder { right: calc(var(--acpmux-actions-width, 64px) + var(--acpmux-composer-lead-gap) + 8px * ${SCALE}); }`;
const ALT: Record<string, string> = {
  edge: `${EDGE}
${FIELD} { --cmux-minimal-scroller-inset-end: calc(var(--acpmux-prompt-control-top) + var(--acpmux-composer-control) + var(--acpmux-composer-block-inset)); }`,
  "edge-full": EDGE,
  outside: `${FIELD} { grid-column: 2 / -1; margin-right: -12px; padding-right: calc(var(--acpmux-actions-width, 64px) + 22px + max(0px, calc(8px * ${SCALE} - var(--cmux-scroller-size, 8px)))); }`,
};
const ALT_ID = "composer-scrollbar-alt";

/// Draws one placement: the shipped rules alone, or an alternate's over them.
const placement =
  (name: string): Play =>
  async (ctx) => {
    ctx.document.getElementById(ALT_ID)?.remove();
    const css = ALT[name];
    if (css) {
      const style = ctx.document.createElement("style");
      style.id = ALT_ID;
      style.textContent = css;
      ctx.document.head.append(style);
    }
    await ctx.waitFor(() => {
      const field = ctx.document.querySelector<HTMLElement>(COMPOSER_MD_FIELD);
      return field !== null && field.scrollHeight > field.clientHeight + 1;
    });
    ctx.document.querySelector(COMPOSER_MD_FIELD)!.setAttribute(SCROLLING_ATTRIBUTE, "");
  };

const draft = Array.from(
  { length: 18 },
  (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
).join("\n");
const snapshot = chat([
  user("Add retries to the fetch helper, with a backoff.", 12),
  assistant("Added `withRetry` to `fetchJson`: three tries with jittered backoff.", 11),
]);
const variant = (name: string, note: string) => ({
  composerLook: "claude" as const,
  note,
  ready: { draft },
  snapshot,
  play: placement(name),
});

export default agentPaneEntry({
  id: "agent-pane.composer-scrollbar",
  title: "Composer draft scrollbar placement",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/composerScrollLane.ts"],
  variants: {
    lane: variant("lane", "Shipped: in a lane between the draft and the mic and Send, to the box's bottom inset (Claude desktop)."),
    edge: variant("edge", "Down the box's right edge, stopping above Send (shipped before: it stopped on the buttons' tops)."),
    "edge-full": variant("edge-full", "Down the box's right edge for its full height, beside the mic and Send."),
    outside: variant("outside", "Just outside the box's right edge, in the column's gutter (Codex desktop)."),
  },
});
