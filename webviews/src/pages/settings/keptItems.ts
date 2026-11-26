// A list the host sends whole on every change (a push, a read) arrives as new objects even where
// nothing changed, so a memo row would draw again for each. `useKeptItems` hands back the list with
// each item equal to the one the last list had under its id replaced by that one: a row whose item
// did not change keeps its props and skips the new list. Built once per new list, not per render.
import { useState } from "react";

const same = (a: unknown, b: unknown) => a === b || JSON.stringify(a) === JSON.stringify(b);

export function useKeptItems<T>(items: readonly T[], idOf: (item: T) => string): T[] {
  const [kept, setKept] = useState(() => ({ items, out: [...items] }));
  if (kept.items === items) return kept.out;
  const held = new Map(kept.out.map((item) => [idOf(item), item]));
  const out = items.map((item) => {
    const old = held.get(idOf(item));
    return old !== undefined && same(old, item) ? old : item;
  });
  setKept({ items, out });
  return out;
}
