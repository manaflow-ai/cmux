// Which disclosures of a turn are open: UI state keyed by the stable ids derive.ts assigns.
import { useCallback, useState } from "react";

/**
 * Open/closed disclosures of one turn, by stable key (turn id, group key, item id). `seen`
 * keys have been open: their content stays mounted while closed so collapsing can animate
 * (the app keeps it mounted through its exit animation).
 */
export function useDisclosure(initiallyOpen: readonly string[] = []) {
  const [state, setState] = useState(() => ({
    open: new Set(initiallyOpen) as ReadonlySet<string>,
    seen: new Set(initiallyOpen) as ReadonlySet<string>,
  }));
  const toggle = useCallback(
    (key: string) =>
      setState(({ open, seen }) => {
        const next = new Set(open);
        if (next.has(key)) next.delete(key);
        else next.add(key);
        return { open: next, seen: seen.has(key) ? seen : new Set(seen).add(key) };
      }),
    [],
  );
  return {
    isOpen: (key: string) => state.open.has(key),
    wasOpen: (key: string) => state.seen.has(key),
    toggle,
  };
}

export type Disclosure = ReturnType<typeof useDisclosure>;
