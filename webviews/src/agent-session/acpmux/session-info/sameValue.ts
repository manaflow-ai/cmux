// Session Info's lists keep their identity while what they hold is unchanged (Leo, 2026-11-03: "i don't
// want to see flickers of the session info or anything when there's random re-renders EVER"). Every
// snapshot acpmux sends is new objects, so the lists Session Info derives from it (what the chat made,
// its links, its agents, its usage) are new on every streamed token even when they hold the same
// things; `useSameValue` hands back the last one while it is equal, so the memoized sections skip the
// update. The comparison stops at the first difference and costs nothing for values that are the same
// object, which the rows acpmux did not change are.
import { useRef } from "react";

/// Whether `a` and `b` hold the same data: the same primitive or function, or arrays, Sets, Maps and
/// plain objects whose members are the same data. A class instance other than those is compared by
/// identity.
export function sameValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index++) if (!sameValue(a[index], b[index])) return false;
    return true;
  }
  if (a instanceof Set) {
    if (!(b instanceof Set) || a.size !== b.size) return false;
    for (const item of a) if (!b.has(item)) return false;
    return true;
  }
  if (a instanceof Map) {
    if (!(b instanceof Map) || a.size !== b.size) return false;
    for (const [key, value] of a) if (!b.has(key) || !sameValue(value, b.get(key))) return false;
    return true;
  }
  const proto = Object.getPrototypeOf(a) as unknown;
  if ((proto !== Object.prototype && proto !== null) || Object.getPrototypeOf(b) !== proto) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
    if (!sameValue((a as Record<string, unknown>)[key], (b as Record<string, unknown>)[key])) return false;
  }
  return true;
}

/// `value`, or the last value this hook returned while that one is the same data (sameValue).
export function useSameValue<T>(value: T): T {
  const last = useRef(value);
  if (!sameValue(last.current, value)) last.current = value;
  return last.current;
}
