// The session list's indexes (the hover cards' and the sub-session cards' stores) are background work:
// they read every listed chat, and the list changes whenever any agent on the Mac does something. Leo,
// 2026-11-22: "i think visually there's sometimes still more to be desired maybe esp at heavy load. aka
// right now for some reason. all things slow down, and i think the interactive/visible parts of cmux are
// not prioritized enough, potentially." On his Mac at load 95 (about 3,000 listed chats, agents busy), a
// shown chat page's renderer spent a third of its JavaScript time rebuilding these indexes in layout
// effects, which run before the frame paints, so the focused chat's frames waited on chats nobody looked
// at (frame interval p95 75 ms, 52 frames over 50 ms in 10 s).
//
// So the first list a store gets goes in at once (the cards' first frame has it), and every later one
// goes to the page's idle lane (schedule/lanes.ts) no sooner than GAP_MS after the last rebuild: after
// input and frame work, coalesced to the newest list, never while the page is hidden. A list that waited `STALE_MS` while the page is shown goes in
// then anyway, so a card's state is never more than that behind under a stream that keeps the frame
// lane busy.
import { useLayoutEffect, useState } from "react";
import { pageLanes, type Lanes } from "./schedule";
import type { AcpmuxSessionEntry } from "./sessionList";

/// How long a shown page's index may lag the list it was given, at most.
export const STALE_MS = 750;
/// The least time between two rebuilds: a list that changes 60 times a second costs at most 4.
export const GAP_MS = 250;

type ListStore = { set(sessions: readonly AcpmuxSessionEntry[]): void };
type Timers = { set(cb: () => void, ms: number): unknown; clear(id: unknown): void; now(): number };

let nextKey = 0;

/// A feed of one store: `give(list)` hands it a list, at once the first time; later lists wait until
/// `GAP_MS` after the last rebuild, then go to the idle lane, coalesced to the newest.
export function listStoreFeed(
  store: ListStore,
  lanes: () => Lanes = pageLanes,
  timers: Timers = {
    set: (cb, ms) => setTimeout(cb, ms),
    clear: (id) => clearTimeout(id as ReturnType<typeof setTimeout>),
    now: () => performance.now(),
  },
) {
  const key = `list-store-${(nextKey += 1)}`;
  let fed = false;
  let last = 0;
  let pending: readonly AcpmuxSessionEntry[] | undefined;
  let gap: unknown;
  let stale: unknown;
  const clear = () => {
    if (gap !== undefined) timers.clear(gap);
    if (stale !== undefined) timers.clear(stale);
    gap = stale = undefined;
  };
  const run = () => {
    const sessions = pending;
    clear();
    pending = undefined;
    if (!sessions) return;
    last = timers.now();
    store.set(sessions);
  };
  const queue = () => {
    gap = undefined;
    const lane = lanes();
    lane.idle(key, run);
    // Hidden, the lane holds it until the page shows; shown, it waits at most STALE_MS more.
    stale ??= timers.set(() => {
      stale = undefined;
      if (globalThis.document?.visibilityState !== "hidden") lane.flush(key);
    }, STALE_MS);
  };
  return {
    give(sessions: readonly AcpmuxSessionEntry[]): void {
      if (!fed) {
        // Until a store has a list, its cards draw nothing: the first one is on the frame.
        if (sessions.length > 0) fed = true;
        last = timers.now();
        store.set(sessions);
        return;
      }
      const waiting = pending !== undefined;
      pending = sessions;
      if (waiting) return;
      const wait = last + GAP_MS - timers.now();
      if (wait > 0) gap = timers.set(queue, wait);
      else queue();
    },
    dispose(): void {
      clear();
      pending = undefined;
    },
  };
}

/// Feeds `store` each `sessions` the page renders, off the frame path after the first (``listStoreFeed``).
export function useListStoreFeed(store: ListStore, sessions: readonly AcpmuxSessionEntry[]): void {
  const [feed] = useState(() => listStoreFeed(store));
  useLayoutEffect(() => {
    feed.give(sessions);
  }, [feed, sessions]);
  useLayoutEffect(() => () => feed.dispose(), [feed]);
}
