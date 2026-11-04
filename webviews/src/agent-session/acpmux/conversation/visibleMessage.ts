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

/// Whether an agent's words say nothing: empty, blank or a lone period. Claude often answers another
/// agent's message with "." alone, which drew as a stray dot on its own line under the received line
/// (Leo, 2026-11-02, on that capture: "these are all so stupid looking"). Only an agent's words:
/// a person's own "." prompt is what they sent and still draws, and so does an agent's "." answering
/// it (`answersPerson`, turns.ts; Leo, 2026-11-03: "well there are cases (rare) that you would want
/// to see it...").
export function isBareAgentText(text: string | undefined): boolean {
  return isVisiblyEmptyText(text) || text!.trim() === ".";
}

/// Whether a message row has no drawn content. Attachments, incoming cards, status metadata and
/// author chips remain visible even when their text field is empty. An agent's reply or another
/// agent's received message that says nothing but "." draws nothing too (`isBareAgentText`).
export function isVisiblyEmptyMessage(row: AcpmuxRow): boolean {
  if (row.kind !== "assistant" && row.kind !== "user") return false;
  if (row.incoming?.kind === "hidden") return true;
  if (
    row.kind === "user" &&
    row.incoming?.kind === "message" &&
    !row.incoming.message.fromPerson &&
    // A tool's notice always has its title to show, whatever its body.
    !row.incoming.message.notice &&
    isBareAgentText(row.incoming.message.text)
  )
    return (
      !row.images?.length &&
      !row.failed &&
      !row.delivery &&
      !row.pending &&
      !row.queued &&
      !row.queuedMessage &&
      !row.retryable &&
      !row.error &&
      !row.pasted?.length &&
      !row.retryAttachments?.length
    );
  const empty = row.kind === "assistant" && !row.answersPerson ? isBareAgentText : isVisiblyEmptyText;
  if (!empty(row.text)) return false;
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
