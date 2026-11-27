import { createContext, useCallback, useContext, useState, type SetStateAction } from "react";

/// A Needs you list's state per ask that outlives the ask's row: the list draws only the rows in and
/// near view (NeedsYou.tsx), so a row scrolled away unmounts, and one scrolled back reads what it
/// showed (expanded, Ask about this open with its draft, an answer in flight, a refusal). It lives
/// as long as the list, as a row's own state did.
export class RowMemory {
  private readonly values = new Map<string, unknown>();
  has(key: string): boolean {
    return this.values.has(key);
  }
  read<T>(key: string): T | undefined {
    return this.values.get(key) as T | undefined;
  }
  write(key: string, value: unknown): void {
    this.values.set(key, value);
  }
}

export const RowMemoryContext = createContext<RowMemory | null>(null);

/// `useState` for a row's part, kept under `key` in the list's RowMemory. The setter writes the
/// memory first, so an answer that settles after its row scrolled away still lands there.
export function useRowState<T>(key: string, initial: T): [T, (action: SetStateAction<T>) => void] {
  const memory = useContext(RowMemoryContext);
  const [value, setValue] = useState<T>(() => (memory?.has(key) ? (memory.read<T>(key) as T) : initial));
  const set = useCallback(
    (action: SetStateAction<T>) => {
      if (!memory) {
        setValue(action);
        return;
      }
      const before = memory.has(key) ? (memory.read<T>(key) as T) : initial;
      const next = typeof action === "function" ? (action as (before: T) => T)(before) : action;
      memory.write(key, next);
      setValue(next);
    },
    [memory, key, initial],
  );
  return [value, set];
}
