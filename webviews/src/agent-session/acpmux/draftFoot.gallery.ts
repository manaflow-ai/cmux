// l10n-allow-file: gallery fixtures (a sample chat and draft), not shipped UI.
// The foot of a long draft scrolled up inside the composer (draftFoot.experiment.ts, markdownField.css).
// Leo, 2026-11-22, of a long draft scrolled up, paraphrased: too much solid and blur at the bottom of
// the box; figure out how to show more there; keep some blur, but get rid of that bottom band. One
// variant per arm: the same 30-line draft in Claude's look, scrolled a third of the way down, so draft
// runs on past both the box's top and bottom edges. View light and dark, and over a picture
// (?background=dark), where the composer's glass shows what the fade lets through.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import { COMPOSER_MD_FIELD } from "./composerSelectors";
import { draftFoot, type DraftFootArm } from "./draftFoot.experiment";

const draft = Array.from(
  { length: 30 },
  (_, index) => `Line ${index + 1}: keep the retry rules and the tests in sync with the docs and the changelog.`,
).join("\n");
const snapshot = chat([
  user("Add retries to the fetch helper, with a backoff.", 12),
  assistant("Added `withRetry` to `fetchJson`: three tries with jittered backoff.", 11),
]);

/** Scrolls the draft a third of the way down, so it runs past the box's top and bottom edges. */
const scrollUp: Play = async (ctx) => {
  await ctx.waitFor(() => {
    const field = ctx.document.querySelector<HTMLElement>(COMPOSER_MD_FIELD);
    return field !== null && field.scrollHeight > field.clientHeight + 40;
  });
  const field = ctx.document.querySelector<HTMLElement>(COMPOSER_MD_FIELD)!;
  await ctx.scroll({ selector: COMPOSER_MD_FIELD }, Math.round((field.scrollHeight - field.clientHeight) / 3));
  await ctx.waitFor(() => ctx.document.querySelector(COMPOSER_MD_FIELD)?.hasAttribute("data-fade-bottom"));
};

const variant = (arm: DraftFootArm, note: string) => ({
  composerLook: "claude" as const,
  note,
  ready: { draft },
  snapshot,
  play: scrollUp,
  experiments: { [draftFoot.id]: arm },
});

export default agentPaneEntry({
  id: "agent-pane.draft-foot",
  title: "The foot of a long draft scrolled up in the composer",
  area: "Agent pane",
  height: 640,
  widths: { narrow: 400, normal: 760, wide: 1100 },
  covers: ["agent-session/acpmux/draftFoot.experiment.ts", "agent-session/acpmux/markdownField.css"],
  keywords: ["composer", "draft", "fade", "mask", "blur", "bottom", "scroll"],
  checks: {
    anchorMovePx: { value: 0, reason: "An alpha mask changes no box: the composer and its controls hold still." },
  },
  experiment: { definition: draftFoot, script: [{ name: "Scroll the draft up", run: scrollUp }] },
  variants: {
    ghost: variant(
      "ghost",
      "Selected (ships): the draft runs to the box's bottom edge, fading only to a third of its ink over 18 px.",
    ),
    shipped: variant(
      "shipped",
      "Before, Leo's still: the draft fades to nothing over the bottom 18 px, a blank strip over the rim.",
    ),
    short: variant("short", "The draft fades to nothing over the bottom 8 px, inside the field's bottom padding."),
    clip: variant("clip", "No fade at the foot: the box's bottom edge cuts the draft at full ink."),
  },
});
