// Waiting on you's reads (queueModel.ts): one `_acpmux/review_queue` when the page shows, again
// when what it lists changes in the pane's snapshot (`refreshKey`, historyPages.ts `queueKey`: this
// Mac's pending asks, and every listed chat's ask count, waiting state and pull request, another
// machine's included), and after an answer. Never on a timer, and never again only because
// the person switched away and back (shared-projections.md): History keeps the last answer and
// the key it was read at (`QueueCache`) while another tab shows, and a return with the same key
// shows it at once without a read. History tells the cache every key it sees meanwhile
// (`QueueCache.note`): a key that moved and came back (a peer chat's ask A, then running, then ask
// B, which the snapshot keys alike) still reads on the return. A read that answers after a newer one started, or after the
// page unmounted, is dropped.
import { useCallback, useEffect, useRef, useState } from "react";
import { isOlderDaemon, readQueue, type QueueReply } from "./queueModel";

export type QueueState =
  | { phase: "loading"; reply?: QueueReply }
  | { phase: "ready"; reply: QueueReply }
  /// acpmux (or the host relaying to it) does not know `_acpmux/review_queue` yet.
  | { phase: "older" }
  | { phase: "failed"; reply?: QueueReply };

/// Asks closer together than this read once, at the end of the burst.
const SETTLE_MS = 400;

/// What the page last showed and the `refreshKey` its last answer was read at, kept by History
/// (newtab/HistoryScreen.tsx) while another of its tabs shows.
export type QueueCache = {
  state(): QueueState | undefined;
  key(): string | undefined;
  keep(state: QueueState): void;
  /// The key a finished read was asked at; `undefined` while one is under way, so a page that
  /// leaves before it lands (an answer's refresh) reads again on its return.
  readAt(key: string | undefined): void;
  /// A key History saw, the page shown or not: one that differs from the last seen forgets the
  /// read's key, so a return reads again even if the key came back to it meanwhile.
  note(key: string): void;
  /// Counts the key moves `note` saw: a read asked before a move does not mark its answer
  /// current, even when the key has come back to what it was asked at.
  generation(): number;
  /// Reads the shown page again after an answer lands; with no page shown, the next one reads on
  /// arrival. An answer that lands after the page left and came back reaches the new page.
  refresh(): void;
  /// The shown page's read (`useQueue`); `undefined` when it leaves.
  attach(read: (() => void) | undefined): void;
};

export function createQueueCache(): QueueCache {
  let state: QueueState | undefined;
  let key: string | undefined;
  let seen: string | undefined;
  let moves = 0;
  let reader: (() => void) | undefined;
  return {
    state: () => state,
    key: () => key,
    keep: (next) => {
      state = next;
    },
    readAt: (next) => {
      key = next;
    },
    note: (next) => {
      if (seen !== undefined && next !== seen) {
        key = undefined;
        moves++;
      }
      seen = next;
    },
    generation: () => moves,
    refresh: () => {
      if (reader) reader();
      else key = undefined;
    },
    attach: (read) => {
      reader = read;
    },
  };
}

export function useQueue(load: () => Promise<unknown>, refreshKey: string, cache?: QueueCache) {
  const [state, setState] = useState<QueueState>(() => cache?.state() ?? { phase: "loading" });
  const request = useRef(0);
  const alive = useRef(true);
  const loadRef = useRef(load);
  loadRef.current = load;
  const keyRef = useRef(refreshKey);
  keyRef.current = refreshKey;
  useEffect(() => {
    cache?.keep(state);
  }, [cache, state]);

  const read = useCallback(() => {
    const id = ++request.current;
    const key = keyRef.current;
    const generation = cache?.generation();
    cache?.readAt(undefined);
    setState((previous) =>
      previous.phase === "ready"
        ? previous
        : { phase: "loading", ...("reply" in previous && previous.reply ? { reply: previous.reply } : {}) },
    );
    loadRef.current().then(
      (value) => {
        if (!alive.current || id !== request.current) return;
        cache?.readAt(cache.generation() === generation ? key : undefined);
        setState({ phase: "ready", reply: readQueue(value) });
      },
      (error: unknown) => {
        if (!alive.current || id !== request.current) return;
        if (isOlderDaemon(error)) setState({ phase: "older" });
        else
          setState((previous) => ({
            phase: "failed",
            ...("reply" in previous && previous.reply ? { reply: previous.reply } : {}),
          }));
      },
    );
  }, [cache]);

  useEffect(() => {
    alive.current = true;
    cache?.attach(read);
    return () => {
      alive.current = false;
      cache?.attach(undefined);
    };
  }, [cache, read]);

  // The first read at once, unless History kept an answer read at this key; a change of asks
  // after it settles first, so a burst reads once.
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      if (cache?.state()?.phase !== "ready" || cache.key() !== refreshKey) read();
      return;
    }
    const timer = setTimeout(read, SETTLE_MS);
    return () => clearTimeout(timer);
  }, [refreshKey, read, cache]);

  return { state, refresh: read };
}
