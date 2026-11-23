// A mark the pane sets on a click and its owner clears by changing what it shows: an answered ask
// whose buttons wait until acpmux or the app takes the ask away, a Retry whose "Retrying…" waits
// until the retried attempt reaches the transcript. The owner's change usually lands within a
// second. When it never lands (the link dropped, the agent exited, the owner took the answer and
// never said so), the mark used to stay forever: a card dimmed and deaf to clicks, a "Retrying…"
// under a turn nothing retried (Leo, 2026-11-11: "This is bullshit state. We cannot have bullshit
// state."). Every such mark is held here instead, and lets go past its deadline: the ask is still
// shown, so it takes an answer again, which is what is true.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

/// How long an answered ask waits for its owner to take it away before it takes clicks again.
export const ANSWER_HOLD_MS = 10_000;

/// How long a Retry's "Retrying…" waits for the retried attempt to show: a Cloud machine that wakes
/// first can take that long before its attempt reaches the chat.
export const RETRY_HOLD_MS = 30_000;

type Mark<T> = { value: T };

/// One held value: `set(value)` holds it for `ms`, `set(undefined)` lets go at once. Past `ms`
/// with no newer `set` it lets go on its own and calls `onRelease` with the value it held (a
/// component's same-frame guard, a ref, lets go with it).
export function useAnswerHold<T>(
  ms: number = ANSWER_HOLD_MS,
  onRelease?: (value: T) => void,
): [T | undefined, (next: T | undefined | ((current: T | undefined) => T | undefined)) => void] {
  // Each set is a new mark object, so a newer set of any value starts its own deadline.
  const [mark, setMark] = useState<Mark<T>>();
  const release = useRef(onRelease);
  useEffect(() => {
    release.current = onRelease;
  }, [onRelease]);
  useEffect(() => {
    if (!mark) return;
    const timer = setTimeout(() => {
      setMark((current) => (current === mark ? undefined : current));
      release.current?.(mark.value);
    }, ms);
    return () => clearTimeout(timer);
  }, [mark, ms]);
  const set = useCallback((next: T | undefined | ((current: T | undefined) => T | undefined)) => {
    setMark((current) => {
      const value = typeof next === "function" ? (next as (c: T | undefined) => T | undefined)(current?.value) : next;
      if (value === undefined) return undefined;
      if (current && Object.is(current.value, value)) return current;
      return { value };
    });
  }, []);
  return [mark?.value, set];
}

/// Many held ids at once (a list of asks answered from one panel): each lets go `ms` after it was
/// added unless `remove` let it go first.
export function useAnswerHoldSet(ms: number = ANSWER_HOLD_MS): {
  held: ReadonlySet<string>;
  add(id: string): void;
  remove(id: string): void;
} {
  // Each id with when it was added: a later add does not move an earlier id's deadline.
  const [held, setHeld] = useState<ReadonlyMap<string, number>>(() => new Map());
  useEffect(() => {
    if (held.size === 0) return;
    const now = Date.now();
    const timers = [...held].map(([id, at]) =>
      setTimeout(
        () => {
          setHeld((current) => {
            if (current.get(id) !== at) return current;
            const next = new Map(current);
            next.delete(id);
            return next;
          });
        },
        Math.max(0, at + ms - now),
      ),
    );
    return () => timers.forEach(clearTimeout);
  }, [held, ms]);
  const add = useCallback((id: string) => {
    setHeld((current) => new Map(current).set(id, Date.now()));
  }, []);
  const remove = useCallback((id: string) => {
    setHeld((current) => {
      if (!current.has(id)) return current;
      const next = new Map(current);
      next.delete(id);
      return next;
    });
  }, []);
  const ids = useMemo(() => new Set(held.keys()), [held]);
  return { held: ids, add, remove };
}
