import { AcpmuxDirectClient, type EventRecord } from "../direct";
import { conversationMarkdown } from "../header/copyRow";
import type { AcpmuxRow } from "../model";

/** Fold recorded history with the transcript's own reducer, without connecting or changing the page. */
export function recordedConversationMarkdown(sessionId: string, events: EventRecord[]): string {
  let rows: readonly AcpmuxRow[] = [];
  const replay = AcpmuxDirectClient.replay(sessionId, events, (snapshot) => {
    rows = snapshot.rows;
  });
  try {
    replay.seekReplay(events.at(-1)?.seq ?? 0);
    return conversationMarkdown(rows);
  } finally {
    replay.close();
  }
}
