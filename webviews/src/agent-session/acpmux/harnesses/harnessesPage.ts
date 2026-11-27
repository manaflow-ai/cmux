// Opens the pane's Harnesses page from a control the pane does not own (the model picker's +).
// The pane registers the one opener while it is mounted; the Quick Composer, which cannot show
// the page, registers none, so its + is hidden.
import { useSyncExternalStore } from "react";

let opener: (() => void) | undefined;
const listeners = new Set<() => void>();
const changed = () => {
  for (const listener of listeners) listener();
};

/// Registers `open`; returns the unregister function.
export function registerHarnessesPage(open: () => void): () => void {
  opener = open;
  changed();
  return () => {
    if (opener !== open) return;
    opener = undefined;
    changed();
  };
}

/// Shows the Harnesses page; false when no pane is mounted.
export function openHarnessesPage(): boolean {
  opener?.();
  return opener !== undefined;
}

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};

/// `openHarnessesPage` while a pane that can show the page is mounted, else undefined.
export function useHarnessesPage(): (() => void) | undefined {
  return useSyncExternalStore(subscribe, () => (opener ? openHarnessesPage : undefined));
}
