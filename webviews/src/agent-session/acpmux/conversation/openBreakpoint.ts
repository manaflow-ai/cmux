// The breakpoint of a chat the reader opens (Leo, 2026-11-12, ask-6194619454: "You put a breakpoint
// right at the moment that tick when you click into it, and then afterwards, that subsequent bit,
// then you can start playing animations ... you don't bother trying to replay the animations").
// Opening a chat (a click into it, another tab or workspace, a restart's first load) sets the
// breakpoint at that tick. What the chat held before it is history: it loads steady and never takes
// a live row's entrance, however it reaches the page (the first slice, the read behind it, a
// reconnect's replay). Only rows that happened after the tick enter.
// A row this page already drew for a chat never animates again either: not when the transcript
// remounts over it, not when a reconnect redraws it under a new frame, not as a cold open's fade.
// The page keeps that per chat (`ChatDrawn`), bounded in chats and in rows per chat.
import type { AcpmuxRow } from "../model";

/// How many chats the page remembers drawn rows for. A chat past it draws as one opened cold.
export const DRAWN_CHATS_KEPT = 24;
/// How many rows one chat remembers, the newest drawn kept. A row forgotten is history drawn long
/// ago: it is older than any open since, so it still takes no entrance (`happenedAfterOpen`).
export const DRAWN_ROWS_KEPT = 4000;

/// The rows one chat drew on this page, newest last. O(1) per row.
export class ChatRows {
  readonly #keys = new Set<string>();
  readonly #kept: number;

  constructor(kept = DRAWN_ROWS_KEPT) {
    this.#kept = kept;
  }

  get size(): number {
    return this.#keys.size;
  }

  has(key: string): boolean {
    return this.#keys.has(key);
  }

  /// Row `key` drew now: kept as the newest, and the oldest go past the bound.
  add(key: string): void {
    this.#keys.delete(key);
    this.#keys.add(key);
    while (this.#keys.size > this.#kept) {
      const oldest = this.#keys.values().next().value;
      if (oldest === undefined) break;
      this.#keys.delete(oldest);
    }
  }
}

/// The rows each chat drew on this page, most recently opened last.
export class ChatDrawn {
  readonly #chats = new Map<string, ChatRows>();
  readonly #kept: number;
  readonly #rowsKept: number;

  constructor(kept = DRAWN_CHATS_KEPT, rowsKept = DRAWN_ROWS_KEPT) {
    this.#kept = kept;
    this.#rowsKept = rowsKept;
  }

  /// The drawn rows of chat `session`, made the most recently opened.
  open(session: string): ChatRows {
    let rows = this.#chats.get(session);
    if (rows) this.#chats.delete(session);
    else rows = new ChatRows(this.#rowsKept);
    this.#chats.set(session, rows);
    while (this.#chats.size > this.#kept) {
      const oldest = this.#chats.keys().next().value;
      if (oldest === undefined) break;
      this.#chats.delete(oldest);
    }
    return rows;
  }

  /// Whether chat `session` drew any row on this page.
  drewAny(session: string): boolean {
    return (this.#chats.get(session)?.size ?? 0) > 0;
  }
}

/// The page's one record (a transcript mounting again reads what the last one drew).
export const chatDrawn = new ChatDrawn();

/// What a drawn row is remembered by: its id, and for the running turn's live line, which keeps one
/// id from turn to turn (turns.ts LIVE_THINKING), its turn's time too, so the next turn's line is new.
export const drawnKey = (row: Pick<AcpmuxRow, "id" | "at" | "below">): string =>
  row.below ? `${row.id}@${row.at}` : row.id;

/// Whether a row that arrived now happened after the chat was opened (`openedAt`, the open's
/// wall-clock tick), and so may take a live entrance. One the page already drew never gets here.
export function happenedAfterOpen(row: { at: number }, openedAt: number): boolean {
  return row.at >= openedAt;
}
