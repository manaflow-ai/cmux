// What ended stays in the composer hat for a while, then goes (Leo, 2026-11-07: "when you call
// background commands, tasks, sub-agents, whatever, like, they don't persist as, like, done ... it's
// probably better to let them expire after a while. But the key point: after a while. Okay, they,
// like, disappear instantly. So, like, if you have it expanded, then it just, like, it disappears,
// which is, like, bad."). A background command, a subagent or a chat the agent started that ended
// stays as a finished line, with its result and its time, for `TRAY_LINGER_MS` of time the person
// was not looking at the hat, then leaves (SubagentTray.tsx plays the leave).
//
// - Only what this view watched end lingers: an item it saw running, or one whose known end is
//   within the grace. Opening a chat never lists its old history as just finished.
// - While the hat is held (open, or the pointer or focus is on it), nothing expires: the grace counts
//   only time the hat was not held, so after the hat folds each line has the rest of its grace left,
//   never a sudden purge of everything that ended while the person read it.
// - An end this view watched (it saw the item running) counts its grace from when the end arrived,
//   not from its stamp: a completion delivered late (a reconnect, a slow registry read) never
//   expires at once, held or not. Its stamp still orders the lines and times them.
// - The clock is the session's (`offsetMs`, the snapshot's `clockOffsetMs`), the one the ends are
//   stamped on, so a peer whose clock runs behind or ahead keeps its grace.
// - At most one timer: `useTrayLinger` arms one for the next expiry, none while the hat is held or
//   nothing lingers, and clears it on unmount or when its inputs change.
//
// The state is pure (an injected clock); App.tsx feeds it the tray's running keys and the ended
// candidates (runningTray.ts `finishedTrayItems`, plus the ended background commands).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { trayItemKey, type TrayItem } from "./runningTray";

/// How long a finished line stays in the hat, counting only time the hat was not held: two minutes,
/// long enough to glance back at a result, short enough that the hat empties after a while.
export const TRAY_LINGER_MS = 120_000;

/// An ended item: its tray key and when it ended, when known (epoch ms).
export type LingerCandidate = { readonly key: string; readonly endedAt?: number };

export type Linger = {
  /// Keys this view saw running: when one ends, it lingers whatever its recorded end says.
  readonly seenLive: Set<string>;
  /// What lingers now: when its grace started (its end, or when a watched end arrived), the held
  /// total then, and its end for its order and time.
  readonly lingering: Map<string, { at: number; heldAt: number; end: number }>;
  /// Ended keys whose grace ran out, or that ended before this view watched: never shown again
  /// while they stay ended.
  readonly expired: Set<string>;
  /// The time the hat was held, up to `heldSince`.
  heldTotal: number;
  /// When the current hold began; undefined while not held.
  heldSince: number | undefined;
};

export const createLinger = (): Linger => ({
  seenLive: new Set(),
  lingering: new Map(),
  expired: new Set(),
  heldTotal: 0,
  heldSince: undefined,
});

/// The held time up to `now`.
const heldBy = (state: Linger, now: number) =>
  state.heldTotal + (state.heldSince === undefined ? 0 : Math.max(0, now - state.heldSince));

export type LingerStep = {
  /// What stays, by key, with when it ended (for its order and its time).
  kept: ReadonlyMap<string, number>;
  /// When the next one expires (the clock's ms), or undefined when nothing can expire: the hat is
  /// held or nothing lingers. This is the one timer's stop condition.
  next: number | undefined;
};

/// One pass at `now`: records what runs, starts the grace of what just ended, drops what ran out.
/// Idempotent for the same input and `now` (a render may run it twice).
export function stepLinger(
  state: Linger,
  input: {
    live: readonly string[];
    ended: readonly LingerCandidate[];
    hold: boolean;
    now: number;
    grace?: number;
  },
): LingerStep {
  const { live, ended, hold, now } = input;
  const grace = input.grace ?? TRAY_LINGER_MS;
  if (hold && state.heldSince === undefined) state.heldSince = now;
  else if (!hold && state.heldSince !== undefined) {
    state.heldTotal += Math.max(0, now - state.heldSince);
    state.heldSince = undefined;
  }
  const held = heldBy(state, now);
  const liveKeys = new Set(live);
  for (const key of liveKeys) {
    // It runs (again): a later end starts a fresh grace.
    state.seenLive.add(key);
    state.expired.delete(key);
    state.lingering.delete(key);
  }
  const kept = new Map<string, number>();
  let next: number | undefined;
  const endedKeys = new Set<string>();
  for (const { key, endedAt } of ended) {
    if (liveKeys.has(key) || endedKeys.has(key)) continue;
    endedKeys.add(key);
    if (state.expired.has(key)) continue;
    let record = state.lingering.get(key);
    if (!record) {
      const watched = state.seenLive.has(key) || (endedAt !== undefined && now - endedAt < grace);
      if (!watched) {
        state.expired.add(key);
        continue;
      }
      // An end stamped after now (another clock) counts from now. One this view saw running counts
      // from its arrival: the time before it arrived was not time the person could see it.
      const end = Math.min(endedAt ?? now, now);
      record = { at: state.seenLive.has(key) ? now : end, heldAt: held, end };
      state.lingering.set(key, record);
    }
    const unheld = now - record.at - (held - record.heldAt);
    if (unheld >= grace) {
      state.lingering.delete(key);
      state.expired.add(key);
      continue;
    }
    kept.set(key, record.end);
    if (!hold) next = Math.min(next ?? Number.POSITIVE_INFINITY, now + grace - unheld);
  }
  // Only keys still listed stay recorded, so another chat's or a cleared list's never pile up.
  for (const key of state.lingering.keys()) if (!endedKeys.has(key)) state.lingering.delete(key);
  for (const key of state.expired) if (!endedKeys.has(key)) state.expired.delete(key);
  for (const key of state.seenLive) if (!liveKeys.has(key) && !endedKeys.has(key)) state.seenLive.delete(key);
  return { kept, next };
}

const sameKept = (a: ReadonlyMap<string, number>, b: ReadonlyMap<string, number>) => {
  if (a.size !== b.size) return false;
  for (const [key, at] of a) if (b.get(key) !== at) return false;
  return true;
};

const NO_KEPT: ReadonlyMap<string, number> = new Map();

export type LingerOptions = {
  /// The grace, in ms; TRAY_LINGER_MS by default (a gallery stage shortens it).
  grace?: number;
  /// This computer's clock minus the session's; 0 for a local chat.
  offsetMs?: number;
  /// This computer's clock (tests inject one).
  clock?: () => number;
};

/// The linger for one chat's hat: what stays, by key. A new map only when what stays changes. One
/// timeout at most, for the next expiry; none while held or with nothing lingering; cleared on
/// unmount, on a chat switch and whenever the inputs change. `offsetMs` is this computer's clock
/// minus the session's (the snapshot's `clockOffsetMs`): the linger reads the session's time, as the
/// ends are stamped on it.
export function useTrayLinger(
  chat: string | undefined,
  live: readonly string[],
  ended: readonly LingerCandidate[],
  hold: boolean,
  { grace = TRAY_LINGER_MS, offsetMs = 0, clock: localClock = Date.now }: LingerOptions = {},
): ReadonlyMap<string, number> {
  const clock = useCallback(() => localClock() - offsetMs, [localClock, offsetMs]);
  const state = useRef<{ chat: string | undefined; linger: Linger; kept: ReadonlyMap<string, number> }>(undefined);
  const [tick, setTick] = useState(0);
  const step = useMemo(() => {
    let own = state.current;
    if (!own || own.chat !== chat) {
      own = { chat, linger: createLinger(), kept: NO_KEPT };
      state.current = own;
    }
    const result = stepLinger(own.linger, { live, ended, hold, now: clock(), grace });
    if (!sameKept(result.kept, own.kept)) own.kept = result.kept;
    return { kept: own.kept, next: result.next };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `tick` re-runs the pass when the next expiry is due
  }, [chat, live, ended, hold, grace, clock, tick]);
  useEffect(() => {
    if (step.next === undefined) return undefined;
    const timer = setTimeout(() => setTick((current) => current + 1), Math.max(0, step.next - clock()));
    return () => clearTimeout(timer);
  }, [step, clock]);
  return step.kept;
}

/// When an item ended, if known.
export const trayItemEnd = (item: TrayItem): number | undefined =>
  item.kind === "agent" ? item.agent.endedAt : item.kind === "command" ? item.command.endedAt : undefined;

/// The ended items that stay, latest end first. A subagent and the nested ones under it move as one
/// group, kept while any of them is, at its latest end. A command whose end only this view saw takes
/// that time as its end, so its line can say how long it ran.
export function lingeringTrayItems(ended: readonly TrayItem[], kept: ReadonlyMap<string, number>): TrayItem[] {
  if (kept.size === 0) return [];
  const groups: { at: number; index: number; items: TrayItem[] }[] = [];
  let current: { at: number; index: number; items: TrayItem[] } | undefined;
  for (const item of ended) {
    if (!(item.kind === "agent" && item.depth > 0 && current)) {
      current = { at: Number.NEGATIVE_INFINITY, index: groups.length, items: [] };
      groups.push(current);
    }
    const at = kept.get(trayItemKey(item));
    if (at !== undefined) current.at = Math.max(current.at, at);
    current.items.push(
      item.kind === "command" && at !== undefined && item.command.endedAt === undefined
        ? { ...item, command: { ...item.command, endedAt: at } }
        : item,
    );
  }
  return groups
    .filter((group) => group.at !== Number.NEGATIVE_INFINITY)
    .sort((a, b) => b.at - a.at || a.index - b.index)
    .flatMap((group) => group.items);
}
