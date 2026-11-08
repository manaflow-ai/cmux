// Waiting on you's reads (queueModel.ts): one `_acpmux/review_queue` when the page shows, again
// when the asks acpmux reports change (`refreshKey`: the pane's pending asks, so a new or answered
// ask anywhere reads it again), when the page comes back to the front, and after an answer. Never
// on a timer. A read that answers after a newer one started, or after the page unmounted, is
// dropped.
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

export function useQueue(load: () => Promise<unknown>, refreshKey: string) {
  const [state, setState] = useState<QueueState>({ phase: "loading" });
  const request = useRef(0);
  const alive = useRef(true);
  const loadRef = useRef(load);
  loadRef.current = load;

  const read = useCallback(() => {
    const id = ++request.current;
    setState((previous) =>
      previous.phase === "ready" ? previous : { phase: "loading", ...("reply" in previous && previous.reply ? { reply: previous.reply } : {}) },
    );
    loadRef.current().then(
      (value) => {
        if (alive.current && id === request.current) setState({ phase: "ready", reply: readQueue(value) });
      },
      (error: unknown) => {
        if (!alive.current || id !== request.current) return;
        if (isOlderDaemon(error)) setState({ phase: "older" });
        else setState((previous) => ({ phase: "failed", ...("reply" in previous && previous.reply ? { reply: previous.reply } : {}) }));
      },
    );
  }, []);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  // The first read at once; a change of asks after it settles first, so a burst reads once.
  const first = useRef(true);
  useEffect(() => {
    if (first.current) {
      first.current = false;
      read();
      return;
    }
    const timer = setTimeout(read, SETTLE_MS);
    return () => clearTimeout(timer);
  }, [refreshKey, read]);

  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") read();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [read]);

  return { state, refresh: read };
}
