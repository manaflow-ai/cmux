// The breakpoint of a chat the reader opens (Leo, 2026-11-12, ask-6194619454: "You put a breakpoint
// right at the moment that tick when you click into it, and then afterwards, that subsequent bit,
// then you can start playing animations ... you don't bother trying to replay the animations").
// Opening a chat (a click into it, another tab or workspace, a restart's first load) sets the
// breakpoint at that tick. What the chat held before it is history: it loads steady and never takes
// a live row's entrance, however it reaches the page (the first slice, the read behind it, a
// reconnect's replay). Only rows that happened after the tick enter.
// A row this page already drew for a chat never animates again either: not when the transcript
// remounts over it, not when a reconnect redraws it under a new frame, not as a cold open's fade.
// The page keeps that per chat (`ChatDrawn`), bounded to the chats most recently opened.

/// How many chats the page remembers drawn rows for. A chat past it draws as one opened cold.
export const DRAWN_CHATS_KEPT = 24;

/// The row ids each chat drew on this page, most recently opened last. O(1) per row.
export class ChatDrawn {
  readonly #chats = new Map<string, Set<string>>();
  readonly #kept: number;

  constructor(kept = DRAWN_CHATS_KEPT) {
    this.#kept = kept;
  }

  /// The drawn ids of chat `session`, made the most recently opened.
  open(session: string): Set<string> {
    let ids = this.#chats.get(session);
    if (ids) this.#chats.delete(session);
    else ids = new Set();
    this.#chats.set(session, ids);
    while (this.#chats.size > this.#kept) {
      const oldest = this.#chats.keys().next().value;
      if (oldest === undefined) break;
      this.#chats.delete(oldest);
    }
    return ids;
  }

  /// Whether chat `session` drew any row on this page.
  drewAny(session: string): boolean {
    return (this.#chats.get(session)?.size ?? 0) > 0;
  }
}

/// The page's one record (a transcript mounting again reads what the last one drew).
export const chatDrawn = new ChatDrawn();

/// Whether a row that arrived now happened after the chat was opened (`openedAt`, the open's
/// wall-clock tick), and so may take a live entrance. One the page already drew never gets here.
export function happenedAfterOpen(row: { at: number }, openedAt: number): boolean {
  return row.at >= openedAt;
}
