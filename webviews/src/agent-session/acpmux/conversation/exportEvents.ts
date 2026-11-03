import type { EventRecord } from "../direct";

export type ConversationExportSource = {
  detail(): Promise<{ lastSeq: number }>;
  page(params: { sessionId: string; afterSeq: number; beforeSeq: number; limit: number; kinds: string[] }): Promise<{
    events: EventRecord[];
    hasMore: boolean;
  }>;
};

/** The daemon replaces an oversized event with this marker rather than returning a partial JSON value. */
export function isOmittedConversationEvent(event: EventRecord): boolean {
  const omitted = event.msg?._meta?.acpmux?.omitted;
  return omitted !== undefined && omitted !== null;
}

/** Reads one complete recorded conversation at the sequence held when export starts. */
export async function recordedConversationEvents(
  sessionId: string,
  source: ConversationExportSource,
  isCurrent: () => boolean,
): Promise<EventRecord[]> {
  const check = () => {
    if (!isCurrent()) throw new Error("conversation_export_stale");
  };
  check();
  const { lastSeq } = await source.detail();
  check();
  if (!Number.isSafeInteger(lastSeq) || lastSeq < 0 || lastSeq === Number.MAX_SAFE_INTEGER)
    throw new Error("conversation_export_invalid_history");
  const pages: EventRecord[][] = [];
  // Pin the upper sequence once: a running conversation must not make this read chase its tail.
  for (let beforeSeq = lastSeq + 1; lastSeq > 0;) {
    check();
    // beforeSeq selects the newest page *before* that sequence, even with afterSeq present.
    const page = await source.page({ sessionId, afterSeq: 0, beforeSeq, limit: 2000, kinds: ["transcript"] });
    check();
    let previous = 0;
    for (const event of page.events) {
      if (
        !Number.isSafeInteger(event.seq) ||
        event.seq <= previous ||
        event.seq >= beforeSeq ||
        event.sessionId !== sessionId ||
        isOmittedConversationEvent(event)
      )
        throw new Error("conversation_export_invalid_history");
      previous = event.seq;
    }
    pages.push(page.events);
    if (!page.hasMore) break;
    // A page with more history must advance. Never copy a partial chat as if it were complete.
    if (!page.events.length) throw new Error("conversation_export_incomplete_history");
    beforeSeq = page.events[0].seq;
  }
  return pages.reverse().flat();
}
