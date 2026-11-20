import type { AcpmuxRow } from "./model";

/** Native Markdown source-use navigation names acpmux's raw segment, not a harness message id. */
export const SOURCE_REPLY_REVEAL = "source-reply:";
export function revealedSourceReply(value: string): string | undefined {
  if (!value.startsWith(SOURCE_REPLY_REVEAL)) return undefined;
  const segment = value.slice(SOURCE_REPLY_REVEAL.length);
  return segment.length > 0 && segment.length <= 200 && !/[\u0000-\u001f\u007f]/.test(segment) ? segment : undefined;
}

/** Pick the exact stamped assistant row. A missing row never falls back to a later reply. */
export function sourceReplyRows(rows: readonly AcpmuxRow[], segment: string): readonly string[] {
  const id = `assistant-${segment}`;
  return rows.some((row) => row.kind === "assistant" && row.id === id) ? [id] : [];
}
