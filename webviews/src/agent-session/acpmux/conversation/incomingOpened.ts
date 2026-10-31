// Which messages from other agents the person opened (IncomingMessageCard.tsx), by chat and row: row
// ids repeat across chats. It lasts while the page does, so a message scrolled out of the virtualized
// transcript and back keeps its state, and the row estimator (model.ts) reads it: in Minimal Mode a
// closed message is its line alone, an opened one its whole card.

const opened = new Set<string>();

const key = (sessionId: string | undefined, rowId: string) => `${sessionId ?? ""}\u0000${rowId}`;

/// Whether the person opened the message on row `rowId` of chat `sessionId`.
export const messageOpened = (sessionId: string | undefined, rowId: string): boolean =>
  opened.has(key(sessionId, rowId));

/// Records that the person opened (or closed) the message on row `rowId` of chat `sessionId`.
export function setMessageOpened(sessionId: string | undefined, rowId: string, open: boolean): void {
  if (open) opened.add(key(sessionId, rowId));
  else opened.delete(key(sessionId, rowId));
}
