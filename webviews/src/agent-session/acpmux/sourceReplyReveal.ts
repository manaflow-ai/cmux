import type { AcpmuxRow } from "./model";

/** Native Markdown source-use navigation names acpmux's raw segment, not a harness message id. */
export const SOURCE_REPLY_REVEAL = "source-reply:";
export interface SourceReplyReveal {
  replyId: string;
  seq?: number;
}

export function revealedSourceReply(value: string): SourceReplyReveal | undefined {
  if (!value.startsWith(SOURCE_REPLY_REVEAL)) return undefined;
  const encoded = value.slice(SOURCE_REPLY_REVEAL.length);
  if (encoded.length > 512) return undefined;
  const valid = (id: unknown): id is string =>
    typeof id === "string" && id.length > 0 && id.length <= 200 && !/[\u0000-\u001f\u007f]/.test(id);
  if (encoded.startsWith("{")) {
    try {
      const { replyId, seq } = JSON.parse(encoded);
      return valid(replyId) && Number.isSafeInteger(seq) && seq > 0 ? { replyId, seq } : undefined;
    } catch {
      return undefined;
    }
  }
  // Older hosts sent a bare segment; that form can reveal only a row already held.
  return valid(encoded) ? { replyId: encoded } : undefined;
}

/** Pick the exact stamped assistant row. A missing row never falls back to a later reply. */
export function sourceReplyRows(rows: readonly AcpmuxRow[], segment: string): readonly string[] {
  const id = `assistant-${segment}`;
  return rows.some((row) => row.kind === "assistant" && row.id === id) ? [id] : [];
}
