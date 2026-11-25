import { useInsertionEffect, useState } from "react";

/// One value per key: `compute` runs on the first render and again only when `key` changes, as a
/// `useMemo` with `[key]` for its dependencies would. A `useMemo` that reads more than its
/// dependencies keeps the React Compiler from compiling the component that calls it.
///
/// Only a committed render keeps its value, as with `useMemo`: a render writes nothing, and the value
/// it returned is kept once it commits (an insertion effect). A render React throws away (a deferred
/// or transition render) leaves no trace, so the next render with its key computes again.
export function useHeldPer<T>(key: string, compute: () => T): T {
  const [held] = useState(() => new HeldPer<T>());
  const value = held.has(key) ? held.value() : compute();
  useInsertionEffect(() => {
    held.keep(key, value);
  });
  return value;
}

class HeldPer<T> {
  private entry: { key: string; value: T } | undefined;

  has(key: string): boolean {
    return this.entry !== undefined && this.entry.key === key;
  }

  value(): T {
    return this.entry!.value;
  }

  keep(key: string, value: T): void {
    this.entry = { key, value };
  }
}
