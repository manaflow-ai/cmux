// One changed file's diff card (EditDiff.tsx, EditDiffLoading.tsx, EditDiffHunks.tsx), its box in one place.
// The card draws with the custom properties `EDIT_DIFF_VARS` puts on it (conversation.css `.cv-edit-diff*` and
// Pierre's rows read them, never a length of their own), and the transcript's row estimate (model.ts
// `editDiffHeight`) reckons with `editDiffBox`: the same numbers, from the same inputs. Those are the chat's
// text size (`--cv-font-size`) and code (`--cv-codeblock-size`, `--cv-codeblock-line-height`), which
// chatDisplay.ts sets, else the page's code type (`--cmux-diff-font-size` / `--cmux-diff-line-height`, the type
// scale's detail size and body line at the Interface Size), and the spacing tokens. So at any chat text size,
// code size or Interface Size the card is estimated at the height it draws (Leo, 2026-11-17: rows under an
// opened edits group shifted as he scrolled).
import typeScale from "../../../../../schemas/type-scale/type-scale.json";
import { SPACING } from "../../../ui/designTokens.generated";

const step = (name: string) => typeScale.steps.find((entry) => entry.name === name)!;
const space = (name: string) => SPACING.find((entry) => entry.name === name)!;

/// The chat text size the card's head is drawn for (conversation.css `:root` `--cv-font-size`).
const TEXT = 14;
/// The head (and an expand row at the card's bottom), at that text size; it scales with the text.
const HEAD = 32;
/// The note an edit with no line changes shows, at that text size, and its padding token.
const EMPTY_TEXT = 12;
const EMPTY_PAD = space("2");
/// A line of the note at `line-height: normal`, as a share of its font size.
const NORMAL_LINE = 1.17;
/// The room above and below the card.
const ABOVE = space("1");
const BELOW = space("2");
/// Pierre's line-info separator before a hunk that skips lines of the file, and the placeholder's.
const SEPARATOR = 24;
/// The lane kept under unwrapped rows for their sideways scrollbar: bottom padding in every engine, scrollbar or not.
export const EDIT_DIFF_LANE = 6;
/// The page's code rows when the chat sets no code size of its own: the type scale's detail size on its body
/// line (styles.css `--cmux-diff-font-size` / `--cmux-diff-line-height`), at the Interface Size.
const PAGE_CODE = step("detail").size;
const PAGE_CODE_LINE = step("body").lineHeight;

/// The card's lengths as custom properties on its root (EditDiff.tsx).
export const EDIT_DIFF_VARS = {
  "--cv-edit-diff-head": `calc(var(--cv-font-size) * ${HEAD} / ${TEXT})`,
  "--cv-edit-diff-above": `var(${ABOVE.variable})`,
  "--cv-edit-diff-below": `var(${BELOW.variable})`,
  "--cv-edit-diff-row": `var(--cv-codeblock-line-height, var(--cmux-diff-line-height, ${PAGE_CODE_LINE}px))`,
  "--cv-edit-diff-separator": `${SEPARATOR}px`,
  "--cv-edit-diff-lane": `${EDIT_DIFF_LANE}px`,
  "--cv-edit-diff-empty-pad": `var(${EMPTY_PAD.variable})`,
  "--cv-edit-diff-empty-size": `calc(var(--cv-font-size) * ${EMPTY_TEXT} / ${TEXT})`,
} as const;

export interface EditDiffBox {
  /// The room above and below the card.
  margins: number;
  head: number;
  /// One code row.
  row: number;
  separator: number;
  /// An edit with no line changes: its note.
  empty: number;
  /// The code's size (a monospace cell is about 0.6 of it).
  code: number;
}

/// The card's lengths at the chat's drawn text size `fontSize`, the code size and line the chat sets (null where
/// it sets none: chatDisplay.ts `chatCodeBlock`) and the Interface Size `scale`.
export function editDiffBox(fontSize: number, code: { size: number; line: number } | null, scale: number): EditDiffBox {
  return {
    margins: ABOVE.px + BELOW.px,
    head: (fontSize * HEAD) / TEXT,
    row: code?.line ?? PAGE_CODE_LINE * scale,
    separator: SEPARATOR,
    empty: 2 * EMPTY_PAD.px + Math.round(((fontSize * EMPTY_TEXT) / TEXT) * NORMAL_LINE),
    code: code?.size ?? PAGE_CODE * scale,
  };
}
