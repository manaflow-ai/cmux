// l10n-allow-file: gallery fixtures (sample prompts, a file search and tool output), not shipped UI.
// The Show more / Show less row under every block the transcript cuts (ExpandRow.tsx): a Shell
// block and a call's output long enough that only their last 400 lines are drawn (Show all output),
// a search's files, and a long sent prompt, each collapsed, expanded and with the pointer on its
// row. An edit's diff and a file read have no row: past eight lines they scroll in their box (Leo,
// 2026-11-12: "this is a really useless show all 9 lines"). Leo, 2026-11-07, on an edit's diff
// card: "why is it, like, just this hard line cut off here between the green and then the rest of
// the card situation?" and "what if the whole bottom row area were clickable in this, like, show
// more show less area? And I mean likewise for the other bits".
// The experiment's arms (expandRow.experiment.ts) compare the row continuing the block's surface
// (shipped), its label in the fade over the last lines, a tinted row under a hairline, and a centred
// label. The `*-hover-*` variants compare what the pointer lights (Leo, 2026-11-11: "the whole line
// should not be highlighted. Just the text."): the shipped tint behind the words, the words' ink
// alone, the words underlined, and the whole row's band as before (`band`).
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { SearchResult } from "./fileResults";
import { expandRowLook } from "./expandRow.experiment";
import { FileResultCard } from "./FileResultCard";
import { PromptText } from "./PromptText";
import { ShellBlock } from "./ShellBlock";
import { ToolOutput } from "./ToolOutputBody";

export type Block = "shell" | "search" | "output" | "prompt";
type Props = { block: Block };

/// A test run past the 400 lines a Shell block or a call's output draws of its end
/// (toolOutputModel.ts `outputTail`): its box scrolls through that end, and Show all output under it
/// draws the rest. A shorter output has no row; it scrolls in its box.
const OUTPUT = Array.from({ length: 450 }, (_, index) => `✓ retry policy case ${index + 1} (${2 + index} ms)`).join(
  "\n",
);

/// A text search over more rows than its card shows closed (FileResultCard.tsx SEARCH_PREVIEW_ROWS).
const SEARCH: SearchResult = {
  files: Array.from({ length: 6 }, (_, file) => ({
    path: `src/net/policy${file}.ts`,
    shown: `src/net/policy${file}.ts`,
    open: `/work/app/src/net/policy${file}.ts`,
    matches: Array.from({ length: 4 }, (_, match) => ({
      line: 10 * match + file + 1,
      text: `export const retry${match} = withBackoff(fetch, { tries: ${match + 2} });`,
    })),
  })),
  matches: 24,
  truncated: false,
};

const PROMPT = Array.from(
  { length: 16 },
  (_, index) => `Line ${index + 1}: keep the transcript's cards one surface, and let the whole bottom row toggle.`,
).join("\n");

function Stage({ block }: Props) {
  return (
    <div className="acpmux-shell" style={{ padding: 16, maxWidth: 640 }}>
      <div data-gallery-block={block} style={{ width: "100%" }}>
        {block === "shell" && <ShellBlock command="bun test test/retry.test.ts" output={OUTPUT} exitCode={0} />}
        {block === "search" && (
          <FileResultCard id="expand-row-search" reveal={0} card={{ kind: "search", tool: "search", result: SEARCH }} />
        )}
        {block === "output" && <ToolOutput result={{ text: OUTPUT, lang: "text" }} />}
        {block === "prompt" && (
          <div className="cv-user">
            <div className="cv-user__body">
              <div className="ui-glass cv-user__bubble selectable">
                <PromptText rowId="expand-row-prompt" text={PROMPT} show={(text) => text} />
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/// The row under each block (its Show more / Show less button).
export const ROW: Record<Block, string> = {
  shell: ".cv-shell .cv-output-more",
  search: ".cv-filematches .cv-output-more",
  output: ".cv-tool-output-card .cv-output-more",
  prompt: ".cv-user__bubble .cv-user__more",
};

/// The block each row belongs to: its card, or the prompt's bubble.
export const CARD: Record<Block, string> = {
  shell: ".cv-shell",
  search: ".cv-filematches",
  output: ".cv-tool-output-card",
  prompt: ".cv-user__bubble",
};

export const BLOCKS: readonly Block[] = ["shell", "search", "output", "prompt"];

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
    const height = block === "prompt" ? { height: PROMPT_STAGE_HEIGHT } : {};
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
  covers: [
    "agent-session/acpmux/conversation/FileResultCard.tsx",
    "agent-session/acpmux/conversation/PromptText.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/conversation/ToolOutputBody.tsx",
    "agent-session/acpmux/conversation/toolOutput.tsx",
  ],
  load: async () => Stage,
  styles: () => Promise.all([import("../styles.css"), import("./conversation.css"), import("./FileResultCard.css")]),
  variants,
  experiment: {
    definition: expandRowLook,
    script: [
      { name: "Hover the row", run: hovered("shell") },
      { name: "Show all output", run: expanded("shell") },
    ],
  },
});
