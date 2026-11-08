// l10n-allow-file: gallery fixtures (sample prompts, a diff, code and tool output), not shipped UI.
// The Show more / Show less row under every block the transcript cuts (ExpandRow.tsx): an edit's
// diff in the edited-files card and in a tool row, a Shell block, a file read (code), a search's files, a call's
// output, and a long sent prompt, each collapsed, expanded and with the pointer on its row. Leo,
// 2026-11-07, on an edit's diff card: "why is it, like, just this hard line cut off here between
// the green and then the rest of the card situation?" and "what if the whole bottom row area were
// clickable in this, like, show more show less area? And I mean likewise for the other bits".
// The experiment's arms (expandRow.experiment.ts) compare the row continuing the block's surface
// (shipped), its label in the fade over the last lines, a tinted row under a hairline, and a centred
// label.
import { useLayoutEffect } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { DiffHunk, TurnFile } from "../diff";
import type { AcpmuxRow } from "../model";
import type { SearchResult } from "./fileResults";
import { setCardOpen } from "../turnChanges/openStore";
import { EditDiff } from "./EditDiff";
import { expandRowLook } from "./expandRow.experiment";
import { EditedFilesCard } from "./EditedFilesCard";
import { FileResultCard } from "./FileResultCard";
import { PromptText } from "./PromptText";
import { ShellBlock } from "./ShellBlock";
import { ToolOutput } from "./ToolOutputBody";

export type Block = "edited" | "diff" | "shell" | "read" | "search" | "output" | "prompt";
type Props = { block: Block };

const BRIEF = Array.from(
  { length: 23 },
  (_, index) =>
    [
      "You are the native-glass lane (cmux NEXT, macOS). Task: every menu, popover and floating control",
      "uses the same native glass material as the sidebar, instead of the flat dark plates.",
      "Start from the references, then list every surface that still draws its own plate.",
      "Open one PR per surface family; quote the ask in each.",
    ][index % 4]!,
);

function added(lines: readonly string[]): DiffHunk {
  return {
    lines: lines.map((text, index) => ({ type: "add" as const, text, newLine: index + 1 })),
  };
}

const NEW_TEXT = `${BRIEF.join("\n")}\n`;

const FILE: TurnFile = {
  path: "docs/glass-brief.md",
  displayPath: "docs/glass-brief.md",
  additions: 23,
  deletions: 0,
  created: true,
  edits: [{ toolId: "glass-brief", numbered: true, hunks: [added(BRIEF)] }],
};

const EDIT_ROW: AcpmuxRow = {
  id: "expand-row-edited",
  version: 1,
  at: Date.now() - 60_000,
  kind: "activity",
  ended: true,
  items: [
    {
      kind: "tool",
      text: "Edit docs/glass-brief.md",
      tool: {
        id: "glass-brief",
        title: "Edit docs/glass-brief.md",
        kind: "edit",
        status: "completed",
        diffs: [{ path: "docs/glass-brief.md", oldText: "", newText: NEW_TEXT }],
      },
    },
  ],
} as AcpmuxRow;

const OUTPUT = Array.from({ length: 20 }, (_, index) => `✓ retry policy case ${index + 1} (${2 + index} ms)`).join(
  "\n",
);

const READ = Array.from(
  { length: 18 },
  (_, index) => `export const step${index} = (attempt: number) => Math.min(30_000, 250 * 2 ** attempt);`,
).join("\n");

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
  // The edited-files card keeps its one file's diff open by row (openStore.ts); open it before paint.
  useLayoutEffect(() => {
    if (block === "edited") setCardOpen(`${EDIT_ROW.id}\u0000diff`, true);
  }, [block]);
  return (
    <div className="acpmux-shell" style={{ padding: 16, maxWidth: 640 }}>
      <div data-gallery-block={block} style={{ width: "100%" }}>
        {block === "edited" && <EditedFilesCard row={EDIT_ROW} />}
        {block === "diff" && <EditDiff file={FILE} />}
        {block === "shell" && <ShellBlock command="bun test test/retry.test.ts" output={OUTPUT} exitCode={0} />}
        {block === "read" && (
          <FileResultCard
            id="expand-row-read"
            reveal={0}
            card={{ kind: "read", read: { path: "src/net/retry.ts", start: 1, end: 18, code: READ } }}
          />
        )}
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
  edited: ".acpmux-edited .cv-edit-diff .cv-output-more",
  diff: ".cv-edit-diff .cv-output-more",
  shell: ".cv-shell .cv-output-more",
  read: ".cv-filepeek .cv-output-more",
  search: ".cv-filematches .cv-output-more",
  output: ".cv-tool-output-card .cv-output-more",
  prompt: ".cv-user__bubble .cv-user__more",
};

/// The block each row belongs to: its card, or the prompt's bubble.
export const CARD: Record<Block, string> = {
  edited: ".acpmux-edited",
  diff: ".cv-edit-diff",
  shell: ".cv-shell",
  read: ".cv-filepeek",
  search: ".cv-filematches",
  output: ".cv-tool-output-card",
  prompt: ".cv-user__bubble",
};

const BLOCKS = ["edited", "diff", "shell", "read", "search", "output", "prompt"] as const;

const ready =
  (block: Block): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(ROW[block]));
    // An edit's lines draw a frame or more after its card (EditDiff.tsx `useDiffPainted`).
    if (block === "edited" || block === "diff")
      await ctx.waitFor(() => ctx.document.querySelector(".cv-edit-diff__stack[data-painted]"));
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
        { note: `${block}: the pointer on its bottom row.`, props: { block }, play: hovered(block), ...height },
      ],
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
    "agent-session/acpmux/conversation/BlockParts.tsx",
    "agent-session/acpmux/conversation/EditDiff.tsx",
    "agent-session/acpmux/conversation/EditedFilesCard.tsx",
    "agent-session/acpmux/conversation/FileResultCard.tsx",
    "agent-session/acpmux/conversation/PromptText.tsx",
    "agent-session/acpmux/conversation/ShellBlock.tsx",
    "agent-session/acpmux/conversation/ToolOutputBody.tsx",
    "agent-session/acpmux/conversation/toolOutput.tsx",
  ],
  load: async () => Stage,
  styles: () =>
    Promise.all([
      import("../styles.css"),
      import("./conversation.css"),
      import("./FileResultCard.css"),
      import("../turnChanges/turnChanges.css"),
    ]),
  variants,
  experiment: {
    definition: expandRowLook,
    script: [
      { name: "Hover the row", run: hovered("edited") },
      { name: "Show all", run: expanded("edited") },
    ],
  },
});
