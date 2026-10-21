// A huge paste is a chip, as in Claude (Leo 2026-10-21): text of more than PASTE_CHIP_LINES lines
// or PASTE_CHIP_CHARS characters pasted into the composer becomes a "Pasted text" attachment (its
// first words and line count) instead of pages of prompt. A click puts it back in the prompt to
// edit; Paste as Plain Text keeps a raw paste. It goes to the agent as text: its own ACP text block
// after the prompt's, marked `_meta.cmux.pasted` so the transcript can tell it from what was typed.
import type { ComposerAttachment, PromptBlock } from "./attachments";

/// A paste of more lines than this is a chip.
export const PASTE_CHIP_LINES = 20;
/// A paste of more characters than this is a chip.
export const PASTE_CHIP_CHARS = 2000;
/// The longest a chip's label (its first words) runs before it is cut.
const LABEL_CHARS = 60;

/// The lines `text` has; a newline at its very end starts none.
export function lineCount(text: string): number {
  const body = text.replace(/(?:\r\n|\r|\n)$/, "");
  return body ? body.split(/\r\n|\r|\n/).length : 0;
}

/// Whether a paste of `text` is a chip rather than prompt text.
export function isLargePaste(text: string): boolean {
  return text.length > PASTE_CHIP_CHARS || lineCount(text) > PASTE_CHIP_LINES;
}

/// A chip's label: the paste's first words (of its first line with any), cut at a word near LABEL_CHARS.
export function pastedLabel(text: string): string {
  const first = text.split(/\r\n|\r|\n/).find((line) => line.trim()) ?? "";
  const words = first.trim().replace(/\s+/g, " ");
  if (words.length <= LABEL_CHARS) return words;
  const cut = words.slice(0, LABEL_CHARS);
  const space = cut.lastIndexOf(" ");
  return `${(space > LABEL_CHARS / 2 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

/// The chip a large paste of `text` makes.
export function pastedTextAttachment(text: string): ComposerAttachment {
  return {
    id: crypto.randomUUID(),
    kind: "pasted",
    name: pastedLabel(text),
    mimeType: "text/plain",
    size: text.length,
    text,
  };
}

/// What the agent gets for the pasted chips: one text block each, in order, after the prompt's
/// own text block. The wire shape of a paste lives here only.
export function pastedTextBlocks(attachments: readonly ComposerAttachment[]): PromptBlock[] {
  return attachments.flatMap((attachment): PromptBlock[] =>
    attachment.kind === "pasted" && attachment.text
      ? [{ type: "text", text: attachment.text, _meta: { cmux: { pasted: true } } }]
      : [],
  );
}
