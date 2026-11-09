// What ended stays in the composer hat for a while, then goes (Leo, 2026-11-07: "when you call
// background commands, tasks, sub-agents, whatever, like, they don't persist as, like, done ... it's
// probably better to let them expire after a while. But the key point: after a while. Okay, they,
// like, disappear instantly. So, like, if you have it expanded, then it just, like, it disappears,
// which is, like, bad."). A background command, a subagent or a chat the agent started that ended
// stays as a finished line, with its result and its time, for `TRAY_LINGER_MS` of time the person
// could see the hat and was not looking at it, then leaves (SubagentTray.tsx plays the leave). And
// never right after a look (Leo, 2026-11-08: "i also feel like the hat auto removing/auto hiding stuff
// that's super done is maybe a bit jarring? we can maybe increase the ttl just a tad/not remove it for
// a bit if the user recently looked at it").
//
// - Only what this view watched end lingers: an item it saw running, or one whose known end is
//   within the grace. Opening a chat never lists its old history as just finished.
// - While the hat is held (open, or the pointer or focus is on it), nothing expires: the grace counts
//   only time the hat was not held, so after the hat folds each line has the rest of its grace left,
//   never a sudden purge of everything that ended while the person read it.
// - A look buys a cooldown: when a hold ends, every line still there stays at least
//   `TRAY_LOOK_COOLDOWN_MS` more, so moving the pointer off the hat (or folding it) never takes a line
//   the person just read with it.
// - The grace counts only time the hat could be seen (`seen`: on screen, in a page that shows, in a
//   focused window; SubagentTray.tsx `onSeen`): what ended while the person was in another window or
//   app, or the hat was tucked, waits for them.
// - Lines that run out close together leave together (`TRAY_LEAVE_TOGETHER_MS`): when one is due,
//   every other due within that window goes with it, so the hat changes once instead of ticking down
//   line by line, and the last ones take the hat with them in one fold.
// - An end this view watched (it saw the item running) counts its grace from when the end arrived,
//   not from its stamp: a completion delivered late (a reconnect, a slow registry read) never
//   expires at once, held or not. Its stamp still orders the lines and times them.
// - The clock is the session's (`offsetMs`, the snapshot's `clockOffsetMs`), the one the ends are
//   stamped on, so a peer whose clock runs behind or ahead keeps its grace.
// - At most one timer: `useTrayLinger` arms one for the next expiry, none while the hat is held or
//   out of sight or nothing lingers, and clears it on unmount or when its inputs change.
//
// The state is pure (an injected clock); App.tsx feeds it the tray's running keys and the ended
// candidates (runningTray.ts `finishedTrayItems`, plus the ended background commands).
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { trayItemKey, type TrayItem } from "./runningTray";

/// How long a finished line stays in the hat, counting only time the hat could be seen and was not
/// held: three minutes (two before Leo's 2026-11-08 ask), long enough to glance back at a result,
/// short enough that the hat empties after a while.
export const TRAY_LINGER_MS = 180_000;
/// After a look ends (the pointer or keyboard focus leaves, or the hat folds), nothing goes for at
/// least this long.
export const TRAY_LOOK_COOLDOWN_MS = 30_000;
/// Lines due within this long of the first one due leave with it, in one change.
export const TRAY_LEAVE_TOGETHER_MS = 20_000;

/// An ended item: its tray key and when it ended, when known (epoch ms).
export type LingerCandidate = { readonly key: string; readonly endedAt?: number };

export type Linger = {
  /// Keys this view saw running: when one ends, it lingers whatever its recorded end says.
  readonly seenLive: Set<string>;
  /// What lingers now: when it is due, on the linger's own clock (`activeAt`: time neither held nor
  /// out of sight), and its end for its order and time.
  readonly lingering: Map<string, { due: number; end: number }>;
  /// Ended keys whose grace ran out, or that ended before this view watched: never shown again
  /// while they stay ended.
  readonly expired: Set<string>;
  /// The time the clock was paused (held, or out of sight), up to `pausedSince`.
  pausedTotal: number;
  /// When the current pause began; undefined while the clock runs.
  pausedSince: number | undefined;
  /// Whether the last pass was held, so the end of a hold (a look) is seen once.
  holding: boolean;
};

export const createLinger = (): Linger => ({
  seenLive: new Set(),
  lingering: new Map(),
  expired: new Set(),
  pausedTotal: 0,
  pausedSince: undefined,
  holding: false,
});

/// The linger's clock at `now`: the time that was neither held nor out of sight.
const activeAt = (state: Linger, now: number) =>
  now - state.pausedTotal - (state.pausedSince === undefined ? 0 : Math.max(0, now - state.pausedSince));

export type LingerStep = {
  /// What stays, by key, with when it ended (for its order and its time).
  kept: ReadonlyMap<string, number>;
  /// When the next one expires (the clock's ms), or undefined when nothing can expire: the hat is
  /// held or out of sight, or nothing lingers. This is the one timer's stop condition.
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
    /// The hat could be seen (SubagentTray.tsx `onSeen`); true when unknown.
    seen?: boolean;
    grace?: number;
    cooldown?: number;
    together?: number;
  },
): LingerStep {
  const { live, ended, hold, now } = input;
  const grace = input.grace ?? TRAY_LINGER_MS;
  const cooldown = input.cooldown ?? TRAY_LOOK_COOLDOWN_MS;
  const together = input.together ?? TRAY_LEAVE_TOGETHER_MS;
  const paused = hold || input.seen === false;
  if (paused && state.pausedSince === undefined) state.pausedSince = now;
  else if (!paused && state.pausedSince !== undefined) {
    state.pausedTotal += Math.max(0, now - state.pausedSince);
    state.pausedSince = undefined;
  }
  // A hold that ended in this pass: a look, which every line still there outlasts by the cooldown.
  const looked = state.holding && !hold;
  state.holding = hold;
  const active = activeAt(state, now);
  const liveKeys = new Set(live);
  for (const key of liveKeys) {
    // It runs (again): a later end starts a fresh grace.
    state.seenLive.add(key);
    state.expired.delete(key);
    state.lingering.delete(key);
  }
  const endedKeys = new Set<string>();
  const shown: { key: string; record: { due: number; end: number } }[] = [];
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
      record = { due: active + grace - (state.seenLive.has(key) ? 0 : now - end), end };
      state.lingering.set(key, record);
    }
    if (looked) record.due = Math.max(record.due, active + cooldown);
    shown.push({ key, record });
  }
  // When one is due, every line due within `together` of now leaves with it.
  const dueNow = shown.some(({ record }) => record.due <= active);
  const kept = new Map<string, number>();
  let next: number | undefined;
  for (const { key, record } of shown) {
    if (record.due <= active || (dueNow && record.due - active <= together)) {
      state.lingering.delete(key);
      state.expired.add(key);
      continue;
    }
    kept.set(key, record.end);
    if (!paused) next = Math.min(next ?? Number.POSITIVE_INFINITY, now + record.due - active);
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
  /// The look's cooldown, in ms; TRAY_LOOK_COOLDOWN_MS by default.
  cooldown?: number;
  /// The leave-together window, in ms; TRAY_LEAVE_TOGETHER_MS by default.
  together?: number;
  /// The hat could be seen (SubagentTray.tsx `onSeen`); true when unset.
  seen?: boolean;
  /// This computer's clock minus the session's; 0 for a local chat.
  offsetMs?: number;
  /// This computer's clock (tests inject one).
  clock?: () => number;
};

/// The linger for one chat's hat: what stays, by key. A new map only when what stays changes. One
/// timeout at most, for the next expiry; none while held, out of sight or with nothing lingering; cleared on
/// unmount, on a chat switch and whenever the inputs change. `offsetMs` is this computer's clock
/// minus the session's (the snapshot's `clockOffsetMs`): the linger reads the session's time, as the
/// ends are stamped on it.
export function useTrayLinger(
  chat: string | undefined,
  live: readonly string[],
  ended: readonly LingerCandidate[],
  hold: boolean,
  {
    grace = TRAY_LINGER_MS,
    cooldown = TRAY_LOOK_COOLDOWN_MS,
    together = TRAY_LEAVE_TOGETHER_MS,
    seen = true,
    offsetMs = 0,
    clock: localClock = Date.now,
  }: LingerOptions = {},
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
    const result = stepLinger(own.linger, { live, ended, hold, seen, now: clock(), grace, cooldown, together });
    if (!sameKept(result.kept, own.kept)) own.kept = result.kept;
    return { kept: own.kept, next: result.next };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- `tick` re-runs the pass when the next expiry is due
  }, [chat, live, ended, hold, seen, grace, cooldown, together, clock, tick]);
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
