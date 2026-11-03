import type { AcpmuxRow } from "../model";

/// Characters that carry no visible glyph in transcript message text. Markdown still receives
/// every other source character; this is only the complete-message fast path.
const ZERO_WIDTH_MESSAGE_CHARS = new Set(["\u200B", "\u200C", "\u200D", "\uFEFF", "\u2060"]);

export function isVisiblyEmptyText(text: string | undefined): boolean {
  if (text === undefined || text.length === 0) return true;
  for (const character of text) {
    if (character.trim() !== "" && !ZERO_WIDTH_MESSAGE_CHARS.has(character)) return false;
  }
  return true;
}

/// Whether an agent's reply says nothing: only punctuation and white space (".", "·", "…"), the mark
/// an agent sends to end a turn it had nothing to say in (Leo, 2026-11-02, on a column of lone "·"
/// replies: "why do you still do these"). Only replies: a person's "?" is a message. A reply longer
/// than a mark is read as text without a look, so a streamed token never costs more than 64 steps.
const PUNCTUATION = /\p{P}/u;
export function isPunctuationOnlyText(text: string | undefined): boolean {
  if (text === undefined || text.length === 0) return true;
  if (text.length > 64) return false;
  for (const character of text) {
    if (character.trim() === "" || ZERO_WIDTH_MESSAGE_CHARS.has(character)) continue;
    if (!PUNCTUATION.test(character)) return false;
  }
  return true;
}

/// Whether a message row has no drawn content. An agent's reply of only punctuation draws nothing
/// either (`isPunctuationOnlyText`). Attachments, incoming cards, status metadata and
/// author chips remain visible even when their text field is empty.
export function isVisiblyEmptyMessage(row: AcpmuxRow): boolean {
  if (row.kind !== "assistant" && row.kind !== "user") return false;
  if (row.incoming?.kind === "hidden") return true;
  if (!(row.kind === "assistant" ? isPunctuationOnlyText(row.text) : isVisiblyEmptyText(row.text))) return false;
  const inlineVisible = row.inlineParts?.some(
    (part) =>
      part.kind !== "text" ||
      !(row.kind === "assistant" ? isPunctuationOnlyText : isVisiblyEmptyText)("text" in part ? part.text : undefined),
  );
  return (
    // Empty prompts can still carry recovery or delivery affordances. Keep the row so
    // DeliveryFailure, PromptActions and queue/steer controls remain reachable.
    !row.failed &&
    !row.delivery &&
    !row.pending &&
    !row.queued &&
    !row.queuedMessage &&
    !row.steer &&
    !row.retryable &&
    !row.resumable &&
    !row.continuable &&
    !row.error &&
    !row.received &&
    !row.images?.length &&
    !inlineVisible &&
    !row.pasted?.length &&
    !row.retryAttachments?.length &&
    !row.incoming &&
    !row.status &&
    !row.author
  );
}
