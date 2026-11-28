import { pageSpace } from "../conversation/disclosureStore";

const opened = pageSpace("card", (rowId) => rowId);

export function setCardOpen(rowId: string, open: boolean) {
  if (open) opened.set(rowId, true);
  else opened.delete(rowId);
}

/// Whether the reader opened card `rowId`, outside React: the row's estimate (model.ts) reads it.
export const cardOpen = (rowId: string): boolean => opened.get(rowId) === true;
