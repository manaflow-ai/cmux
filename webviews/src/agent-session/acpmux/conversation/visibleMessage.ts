import type { AcpmuxRow } from "../model";

/// Characters that carry no visible glyph in transcript message text. Markdown still receives
/// every other source character; this is only the complete-message fast path.
const INVISIBLE_MESSAGE_TEXT = /^[\s\u200B\u200C\u200D\uFEFF\u2060]*$/u;

export function isVisiblyEmptyText(text: string | undefined): boolean {
  return text === undefined || INVISIBLE_MESSAGE_TEXT.test(text);
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
