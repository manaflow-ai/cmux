// Which edited-files cards the user opened while agentPane.editedFiles.show is collapsed, by row
// id. A module store, not component state: the transcript is virtualized, so a card mounts again
// when it scrolls back into view, and the setting can arrive after the card first mounted.
import { useSyncExternalStore } from "react";

const opened = new Set<string>();
const listeners = new Set<() => void>();

export function setCardOpen(rowId: string, open: boolean) {
  if (opened.has(rowId) === open) return;
  if (open) opened.add(rowId);
  else opened.delete(rowId);
  for (const listener of listeners) listener();
}

export function useCardOpen(rowId: string): boolean {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => opened.has(rowId),
  );
}
