// A huge paste is a chip, as in Claude (Leo 2026-10-21): text of more than PASTE_CHIP_LINES lines
// or PASTE_CHIP_CHARS characters pasted into the composer becomes a "Pasted text" attachment (its
// first words and line count) instead of pages of prompt. A click puts it back in the prompt to
// edit; Paste as Plain Text keeps a raw paste. It goes to the agent as text: its own ACP text block
// after the prompt's, marked `_meta.cmux.pasted` so the transcript can tell it from what was typed.
import type { ComposerAttachment, PromptBlock } from "./attachments";
import { pasteLines, pasteName, type PasteRange } from "./conversation/promptCollapse";

/// A paste of more lines than this is a chip.
export const PASTE_CHIP_LINES = 20;
/// A paste of more characters than this is a chip.
export const PASTE_CHIP_CHARS = 2000;
/// A paste longer than this goes as a file, never as text in the prompt or a chip that holds it:
/// past it a prompt's text block is more than an agent's message carries (acpmux's 15 MiB) and the
/// field could not lay it out (Leo, 2026-10-25: "arbitarrily large file sizes the composer should
/// never ever freeze").
export const PASTE_FILE_CHARS = 1024 * 1024;

/// The text a task turns into bytes at a time while a huge paste becomes its file. Each slice is
/// one UTF-8 encode on the main thread: 4M characters took 11 ms in Chromium (48 ms with 4x CPU
/// throttle, the CI runner's typing p95 of 42-77 ms on a 100 MB paste), 1M takes 1 ms (4 ms).
const FILE_SLICE_CHARS = 1024 * 1024;
export const PASTED_TEXT_NAME = "Pasted text.txt";

/// A paste past PASTE_FILE_CHARS as the file it goes as (its copy is saved where the agent reads
/// it), made a slice per task so a 100 MB paste never holds the page while its bytes are made.
export async function pastedTextFile(text: string): Promise<File> {
  const parts: Blob[] = [];
  let at = 0;
  while (at < text.length) {
    // A slice never ends between the two halves of a character (a surrogate pair).
    let end = Math.min(text.length, at + FILE_SLICE_CHARS);
    const last = text.charCodeAt(end - 1);
    if (end < text.length && last >= 0xd800 && last <= 0xdbff) end -= 1;
    parts.push(new Blob([text.slice(at, end)]));
    at = end;
    if (at < text.length) await new Promise((resolve) => setTimeout(resolve, 0));
  }
  return new File(parts, PASTED_TEXT_NAME, { type: "text/plain" });
}

/// Whether a paste of `text` is a chip rather than prompt text. Its lines and name are counted as
/// the transcript's paste chip counts them (promptCollapse.ts), so the two chips read the same.
export function isLargePaste(text: string): boolean {
  return text.length > PASTE_CHIP_CHARS || pasteLines(text) > PASTE_CHIP_LINES;
}

/// The chip a large paste of `text` makes.
export function pastedTextAttachment(text: string): ComposerAttachment {
  return {
    id: crypto.randomUUID(),
    kind: "pasted",
    name: pasteName(text),
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

/// What a prompt's bubble and queue row show before acpmux's echo: its text `body` (the typed text
/// with text files) and each paste, joined as the echo joins a prompt's text blocks (a newline,
/// acpmux hub/session.rs `prompt_text`), with each paste's range in that text as the echo's
/// `user_message.pasted` names it. The bubble draws the same chips before and after the echo.
export function shownPrompt(
  body: string,
  attachments: readonly ComposerAttachment[],
): { text: string; pasted: PasteRange[] } {
  const pastes = attachments.flatMap((attachment) =>
    attachment.kind === "pasted" && attachment.text ? [attachment.text] : [],
  );
  let text = body;
  const pasted: PasteRange[] = [];
  for (const paste of pastes) {
    if (text) text += "\n";
    pasted.push({ start: text.length, end: text.length + paste.length });
    text += paste;
  }
  return { text, pasted };
}

/// The chips Retry and Edit send again with a prompt's text: that text is acpmux's echo, which
/// already holds each paste, so a pasted chip would send it twice.
export function resentAttachments(attachments: readonly ComposerAttachment[]): ComposerAttachment[] {
  return attachments.filter((attachment) => attachment.kind !== "pasted");
}
