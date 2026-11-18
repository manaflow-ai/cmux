import { useState } from "react";

/// One value per key: `compute` runs on the first render and again only when `key` changes, as a
/// `useMemo` with `[key]` for its dependencies would. A `useMemo` that reads more than its
/// dependencies keeps the React Compiler from compiling the component that calls it.
export function useHeldPer<T>(key: string, compute: () => T): T {
  const [held] = useState(() => new HeldPer<T>());
  return held.get(key, compute);
}

class HeldPer<T> {
  private key: string | undefined;
  private value: T | undefined;
  private filled = false;

  get(key: string, compute: () => T): T {
    if (!this.filled || this.key !== key) {
      this.value = compute();
      this.key = key;
      this.filled = true;
    }
    return this.value as T;
  }
}
