// Every message other sessions sent this chat that the agent has not read yet is in ONE collapsed
// group at the transcript's end, "N messages from M sessions", never a loose list of rows (Leo,
// 2026-10-29: "And these need to be fucking grouped up... How are there so fucking many
// messages? ... why the fuck aren't they folded into the big, like 200-plus fucking messages?").
// Two kinds of message wait, and both go in it:
// - a steer into the running turn the agent has not read yet (`steer === "waiting"`), which the
//   running turn gives up as it is drawn (turns.ts `pending`);
// - a message queued behind the running turn (queuedMessages.ts, kind `QUEUED_MESSAGE`).
// The group has one id while messages wait, so one that arrives after it was drawn joins it, and it
// stays open or closed as the person left it. Opened, its messages are grouped by the session that
// sent them, in the order each session first wrote; each is its own received line (its ⋯ menu kept).
// Once the agent reads a message it leaves the group and draws where it was read.
// The same delivery is shown once by its prompt id (or its row id when the prompt id is absent).
// Preview text is not identity: after a reload the queue may hold only the first 200 characters,
// and distinct messages from the same sender can have identical previews.
//
// Cost: nothing while nothing waits. The group is made once per change of the waiting rows; the
// same rows give the same row back, so the transcript keeps its identity.
import { batchLaneNotices, flattenInboxRows, noticeOf } from "./laneNoticeBatches";
import { PENDING_MESSAGES, QUEUED_MESSAGE, type AcpmuxRow } from "../model";

/// The group's row id: one while any message waits.
export const PENDING_MESSAGES_ROW_ID = "pending-messages";

/// Whether `row` is another session's message the agent has not read yet in the running turn.
export const isWaitingMessage = (row: AcpmuxRow) =>
  row.kind === "user" &&
  row.steer === "waiting" &&
  (row.incoming?.kind === "message" || row.incoming?.kind === "inbox");

/// A waiting message's prompt id: the queue entry's, or the steer's.
const promptIdOf = (row: AcpmuxRow) => row.queuedMessage?.promptId ?? row.steerPromptId;

/// `rows` with each stable delivery id once. Separate prompt ids remain separate messages,
/// even when their sender, preview and attachments match. Keep row ids in a separate namespace.
export function dedupeMessages(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (rows.length < 2) return rows;
  const ids = new Set<string>();
  let out: AcpmuxRow[] | undefined;
  rows.forEach((row, index) => {
    const promptId = promptIdOf(row);
    const id = promptId ? `prompt:${promptId}` : `row:${row.id}`;
    const seen = ids.has(id);
    ids.add(id);
    if (seen) out ??= rows.slice(0, index);
    else out?.push(row);
  });
  return out ?? rows;
}

/// Rows Find searches for waiting messages. The transcript draws the same messages through
/// `pendingMessagesRow`, which deduplicates them, so Find must search that same set or it can
/// select a duplicate row id that is not present in the rendered group.
export function searchablePendingRows(
  sourceRows: readonly AcpmuxRow[],
  queuedRows: readonly AcpmuxRow[],
): readonly AcpmuxRow[] {
  const raw = queuedRows.length ? [...sourceRows, ...queuedRows] : sourceRows;
  const all = flattenInboxRows(raw);
  const waiting = all.filter((row) => row.kind === QUEUED_MESSAGE || isWaitingMessage(row));
  if (waiting.length === 0) return all;
  const kept = new Set(dedupeMessages(waiting));
  const visible = flattenInboxRows([...kept]);
  return all
    .filter(
      (row) =>
        (row.kind !== QUEUED_MESSAGE && !isWaitingMessage(row)) || (kept.has(row) && noticeOf(row)?.kind !== "inbox"),
    )
    .concat(visible.filter((row) => !kept.has(row)));
}

/// The key a message's sender is grouped under.
export const senderKey = (row: AcpmuxRow) =>
  row.incoming?.kind === "message" ? (row.incoming.message.sessionId ?? row.incoming.message.name) : row.id;

/// The group's messages by sender, each sender once in the order it first wrote, its messages oldest first.
export function bySender(rows: readonly AcpmuxRow[]): { key: string; rows: AcpmuxRow[] }[] {
  const groups = new Map<string, AcpmuxRow[]>();
  for (const row of rows) {
    const key = senderKey(row);
    const list = groups.get(key);
    if (list) list.push(row);
    else groups.set(key, [row]);
  }
  return [...groups].map(([key, list]) => ({ key, rows: list }));
}

let version = 0;

/// The one group row of the waiting messages (`steers`, then `queued`), or undefined when none wait.
/// `last`: the previous result, given back while it holds the same rows.
export function pendingMessagesRow(
  steers: readonly AcpmuxRow[],
  queued: readonly AcpmuxRow[],
  last?: AcpmuxRow,
): AcpmuxRow | undefined {
  const all = steers.length === 0 ? queued : queued.length === 0 ? steers : [...steers, ...queued];
  const members = dedupeMessages(all.filter((row) => row.kind === QUEUED_MESSAGE || isWaitingMessage(row)));
  if (members.length === 0) return undefined;
  const held = last?.pendingMessages?.rows;
  if (held && held.length === members.length && held.every((row, index) => row === members[index])) return last;
  const flat = members.some((row) => row.inboxDelivery === true || noticeOf(row)?.kind === "inbox");
  const flattened = flattenInboxRows(members);
  // Inbox deliveries already form the flat message run required by the waiting card. Keep
  // report batching out of that run so no notice/report group can nest inside the outer card.
  const displayRows = flat ? flattened : batchLaneNotices(flattened);
  return {
    id: PENDING_MESSAGES_ROW_ID,
    version: ++version,
    at: members[0]!.at,
    kind: PENDING_MESSAGES,
    // Find counts the messages' words; the group opens for a match in one of them.
    text: displayRows
      .map((row) => (row.incoming?.kind === "message" ? row.incoming.message.text : (row.text ?? "")))
      .join("\n\n"),
    untyped: true,
    joined: [...members.map((row) => row.id), ...displayRows.map((row) => row.id)],
    pendingMessages: { rows: members, displayRows, ...(flat ? { flat: true } : {}) },
  };
}
