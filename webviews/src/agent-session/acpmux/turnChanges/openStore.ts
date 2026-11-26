// Which edited-files cards the user opened while agentPane.editedFiles.show is collapsed, by row
// id. A module store, not component state: the transcript is virtualized, so a card mounts again
// when it scrolls back into view, and the setting can arrive after the card first mounted.
// Its values are the open-state store's "card" space (conversation/disclosureStore.ts), keyed by the
// card's row, which every change is credited to.
import { useSyncExternalStore } from "react";
import { pageSpace, subscribeDisclosure } from "../conversation/disclosureStore";

const opened = pageSpace("card", (rowId) => rowId);

export function setCardOpen(rowId: string, open: boolean) {
  if (open) opened.set(rowId, true);
  else opened.delete(rowId);
}

/// Whether the reader opened card `rowId`, outside React: the row's estimate (model.ts) reads it.
export const cardOpen = (rowId: string): boolean => opened.get(rowId) === true;

export function useCardOpen(rowId: string): boolean {
  return useSyncExternalStore(subscribeDisclosure, () => cardOpen(rowId));
}
