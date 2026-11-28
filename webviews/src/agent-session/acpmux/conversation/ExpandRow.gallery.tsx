// l10n-allow-file: gallery fixtures (sample prompts), not shipped UI.
// The Show more / Show less row under a long sent prompt (ExpandRow.tsx), collapsed, expanded and
// with the pointer on its row. Leo, 2026-11-07: "what if the whole bottom row area were clickable
// in this, like, show more show less area?" Output and code cards have no such row any more: they
// scroll inside their own box (outputScrollBox.css; Leo, 2026-11-12: "this is a really useless show
// all 9 lines. i think [another chat app] just lets you scroll, straight up?"), compared in
// `agent-pane.output-scroll-box`. The experiment's arms (expandRow.experiment.ts) compare the row
// continuing the block's surface (shipped), its label in the fade over the last lines, a tinted row
// under a hairline, and a centred label. The `*-hover-*` variants compare what the pointer lights
// (Leo, 2026-11-11: "the whole line should not be highlighted. Just the text."): the shipped tint
// behind the words, the words' ink alone, the words underlined, and the whole row's band as before.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import { expandRowLook } from "./expandRow.experiment";
import { PromptText } from "./PromptText";

export type Block = "prompt";
type Props = { block: Block };

const PROMPT = Array.from(
  { length: 16 },
  (_, index) => `Line ${index + 1}: keep the transcript's cards one surface, and let the whole bottom row toggle.`,
).join("\n");

function Stage(_: Props) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, maxWidth: 640 }}>
      <div data-gallery-block="prompt" style={{ width: "100%" }}>
        <div className="cv-user">
          <div className="cv-user__body">
            <div className="ui-glass cv-user__bubble selectable">
              <PromptText rowId="expand-row-prompt" text={PROMPT} show={(text) => text} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

/// The row under each block (its Show more / Show less button).
export const ROW: Record<Block, string> = { prompt: ".cv-user__bubble .cv-user__more" };

/// The block each row belongs to: the prompt's bubble.
export const CARD: Record<Block, string> = { prompt: ".cv-user__bubble" };

const BLOCKS = ["prompt"] as const;

const ready =
  (block: Block): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(ROW[block]));
  };
const expanded =
  (block: Block): Play =>
  async (ctx) => {
    await ready(block)(ctx);
    await ctx.click({ selector: ROW[block] });
    await ctx.waitFor(() => ctx.document.querySelector(`${ROW[block]}[aria-expanded="true"]`));
    await ctx.hover({ selector: `[data-gallery-block]` });
  };
const hovered =
  (block: Block): Play =>
  async (ctx) => {
    await ready(block)(ctx);
    await ctx.hover({ selector: ROW[block] });
  };

/// What the pointer lights, besides the shipped tint behind the words (conversation.css
/// `:root[data-expand-row-hover]`).
export const HOVER_ARMS = ["band", "ink", "underline"] as const;

/// The pointer on the row's middle (away from its words, at its left), with the hover look `arm`.
const hoveredAs =
  (block: Block, arm: (typeof HOVER_ARMS)[number]): Play =>
  async (ctx) => {
    ctx.document.documentElement.dataset.expandRowHover = arm;
    await hovered(block)(ctx);
  };

// A sent prompt folds at twenty lines (promptCollapse.ts COLLAPSED_PROMPT_LINES), so its Show more
// row sits about 500px down: its stage is tall enough to show the row and take a click on it.
const PROMPT_STAGE_HEIGHT = 640;

const variants = Object.fromEntries(
  BLOCKS.flatMap((block) => {
    const height = { height: PROMPT_STAGE_HEIGHT };
    return [
      [block, { note: `${block}: collapsed.`, props: { block }, play: ready(block), ...height }],
      [
        `${block}-expanded`,
        { note: `${block}: expanded with Show less.`, props: { block }, play: expanded(block), ...height },
      ],
      [
        `${block}-hover`,
        {
          note: `${block}: the pointer on the middle of its bottom row, away from the words: only the words light, on a small tint (shipped; Leo, 2026-11-11: "Just the text.").`,
          props: { block },
          play: hovered(block),
          ...height,
        },
      ],
      ...HOVER_ARMS.map((arm) => [
        `${block}-hover-${arm}`,
        {
          note: {
            band: `${block}: before. The pointer on the row's middle lights the row's whole width (Leo, 2026-11-11: "the whole line should not be highlighted").`,
            ink: `${block}: the pointer on the row's middle brightens the words alone, with no tint.`,
            underline: `${block}: the pointer on the row's middle underlines the words.`,
          }[arm],
          props: { block },
          play: hoveredAs(block, arm),
          ...height,
        },
      ]),
    ];
  }),
);

export default componentEntry<Props>({
  id: "agent-pane.expand-row",
  title: "Show more / Show less rows",
  area: "Agent pane",
  pane: true,
  height: 420,
  covers: ["agent-session/acpmux/conversation/PromptText.tsx"],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css")]),
  variants,
  experiment: {
    definition: expandRowLook,
    script: [
      { name: "Hover the row", run: hovered("prompt") },
      { name: "Show more", run: expanded("prompt") },
    ],
  },
});
