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

/// Opens (or closes) every message of a digest with the digest itself: a group's head shows what
/// each of its messages said, not one more row to open per message (Leo, 2026-11-05: "we don't seem
/// to be able to click it at the top level, which is no bueno. Like all of these things, we need to
/// be able to see them here"). `memberIds` are the rows (or inbox thread keys) its lines open by.
export function setDigestOpened(
  sessionId: string | undefined,
  rowId: string,
  memberIds: Iterable<string>,
  open: boolean,
): void {
  setMessageOpened(sessionId, rowId, open);
  for (const id of memberIds) setMessageOpened(sessionId, id, open);
}
