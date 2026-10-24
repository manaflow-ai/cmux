import type { EventRecord } from "../direct";

export type ConversationExportSource = {
  detail(): Promise<{ lastSeq: number }>;
  page(params: { sessionId: string; afterSeq: number; beforeSeq: number; limit: number; kinds: string[] }): Promise<{
    events: EventRecord[];
    hasMore: boolean;
  }>;
};

/** Reads one complete recorded conversation at the sequence held when export starts. */
export async function recordedConversationEvents(
  _sessionId: string,
  _source: ConversationExportSource,
  _isCurrent: () => boolean,
): Promise<EventRecord[]> {
  return [];
}
