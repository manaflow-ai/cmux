// l10n-allow-file: gallery fixtures (a sample chat and draft), not shipped UI.
// Where the composer's draft scrollbar sits (Leo 2026-10-22: "shouldn't the styling wrt composer vs
// the chat/window (these should be one and hte same) be more cohesive? well idk but the
// chatgpt(codex) has it on the outside while claude indeed has it on the inside"). The same long draft
// in Claude's look with the thumb:
//   - `edge`, shipped: down the box's own right edge, stopping above Send, as Claude desktop draws it
//     and as the chat's runs down the pane's (composerLocation.css);
//   - `edge-full`: down the box's right edge for its full height, beside the mic and Send;
//   - `lane`: in a lane between the draft and the mic and Send (the placement before);
//   - `outside`: just outside the box's right edge, in the column's gutter, as Codex desktop.
// The alternates are gallery-only CSS over the shipped rules.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";

const BOX = ".acpmux-composer-box:has(> .acpmux-chrome-area > .acpmux-composer-inner)";
const FIELD = `${BOX} > .acpmux-composer-field-menu > .acpmux-md-field`;
const SCALE = "var(--cmux-interface-scale, 1)";
const ALT: Record<string, string> = {
  "edge-full": `${FIELD} { --cmux-minimal-scroller-inset-end: var(--cmux-minimal-scroller-inset, 0px); }`,
  lane: `${FIELD} { grid-column: 2; padding-right: max(0px, calc(8px * ${SCALE} - var(--cmux-scroller-size, 8px))); --cmux-minimal-scroller-inset-end: var(--cmux-minimal-scroller-inset, 0px); }
${FIELD} .acpmux-md-placeholder { right: calc(8px * ${SCALE}); }`,
  outside: `${FIELD} { margin-right: -12px; padding-right: calc(var(--acpmux-actions-width, 64px) + 22px + max(0px, calc(8px * ${SCALE} - var(--cmux-scroller-size, 8px)))); --cmux-minimal-scroller-inset-end: var(--cmux-minimal-scroller-inset, 0px); }`,
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
      const field = ctx.document.querySelector<HTMLElement>(".acpmux-composer-box .acpmux-md-field");
      return field !== null && field.scrollHeight > field.clientHeight + 1;
    });
  };

const draft = Array.from(
  { length: 18 },
  (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs.`,
).join("\n");
const snapshot = chat([
  user("Add retries to the fetch helper, with a backoff.", 12),
  assistant("Added `withRetry` to `fetchJson`: three tries with jittered backoff.", 11),
]);
const variant = (name: string, note: string) => ({ note, ready: { draft }, snapshot, play: placement(name) });

export default agentPaneEntry({
  id: "agent-pane.composer-scrollbar",
  title: "Composer draft scrollbar placement",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 400, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/composerScrollLane.ts"],
  variants: {
    edge: variant("edge", "Shipped: down the box's right edge, stopping above Send (Claude desktop)."),
    "edge-full": variant("edge-full", "Down the box's right edge for its full height, beside the mic and Send."),
    lane: variant("lane", "In a lane between the draft and the mic and Send (the placement before)."),
    outside: variant("outside", "Just outside the box's right edge, in the column's gutter (Codex desktop)."),
  },
});
