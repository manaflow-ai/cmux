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

/// Whether a message row has no drawn content. Attachments, incoming cards, status metadata and
/// author chips remain visible even when their text field is empty.
export function isVisiblyEmptyMessage(row: AcpmuxRow): boolean {
  if (row.kind !== "assistant" && row.kind !== "user") return false;
  if (row.incoming?.kind === "hidden") return true;
  if (!isVisiblyEmptyText(row.text)) return false;
  const inlineVisible = row.inlineParts?.some(
    (part) => part.kind !== "text" || !isVisiblyEmptyText("text" in part ? part.text : undefined),
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
