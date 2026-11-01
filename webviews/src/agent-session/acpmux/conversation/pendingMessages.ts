// Every message other sessions sent this chat that the agent has not read yet is in ONE collapsed
// group at the transcript's end, "N messages from M sessions", never a loose list of rows (Leo,
// 2026-10-29: "And these need to be fucking grouped up... How are there so fucking many
// messages? ... why the fuck aren't they folded into the big, like 200-plus fucking messages?").
// Three kinds of message wait, and all go in it:
// - a steer into the running turn the agent has not read yet (`steer === "waiting"`), which the
//   running turn gives up as it is drawn (turns.ts `pending`);
// - a message queued behind the running turn (queuedMessages.ts, kind `QUEUED_MESSAGE`);
// - acpmux's inbox notice, steered or queued: its threads, never its text for the agent.
// The group has one id while messages wait, so one that arrives after it was drawn joins it, and it
// stays open or closed as the person left it. Opened, it is one flat run of received lines, each the
// sender and that message's own first line: no group inside it, no sender heads that repeat the
// line's own name, and every inbox notice's threads as lines of one notice, a thread once, and none
// whose messages already wait as their own lines (Leo, 2026-11-01, on a group holding "13 inbox
// threads" holding a row per delivery: "WTF IS THIS FUCKING RENDERING").
// Once the agent reads a message it leaves the group and draws where it was read.
// The same delivery is shown once by its prompt id (or its row id when the prompt id is absent).
// Preview text is not identity: after a reload the queue may hold only the first 200 characters,
// and distinct messages from the same sender can have identical previews.
//
// Cost: nothing while nothing waits. The group is made once per change of the waiting rows; the
// same rows give the same row back, so the transcript keeps its identity.
import { PENDING_MESSAGES, QUEUED_MESSAGE, type AcpmuxRow } from "../model";
import { inboxCounts, inboxText, joinNotices, type InboxNotice } from "./inboxNotice";

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
  const all = queuedRows.length ? [...sourceRows, ...queuedRows] : sourceRows;
  const waiting = all.filter((row) => row.kind === QUEUED_MESSAGE || isWaitingMessage(row));
  if (waiting.length < 2) return all;
  const kept = new Set(dedupeMessages(waiting));
  return all.filter((row) => (row.kind !== QUEUED_MESSAGE && !isWaitingMessage(row)) || kept.has(row));
}

/// The rows the group draws, flat and in order: each message as its own line, and every inbox
/// notice's threads joined into one notice where the first notice was (a thread in two notices
/// once), without a thread whose messages all wait as their own lines here.
export function pendingDisplayRows(members: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  const notices = members.filter((row) => row.incoming?.kind === "inbox");
  if (notices.length === 0) return members;
  const own = new Set(members.flatMap((row) => (row.incoming?.kind === "inbox" ? [] : [promptIdOf(row) ?? ""])));
  let notice: InboxNotice | undefined;
  for (const row of notices) {
    const next = (row.incoming as { kind: "inbox"; notice: InboxNotice }).notice;
    notice = notice ? joinNotices(notice, next) : next;
  }
  const threads = notice!.threads.filter(
    (thread) => !(thread.promptIds.length > 0 && thread.promptIds.every((id) => own.has(id))),
  );
  const first = notices[0]!;
  const joined: InboxNotice = { threads };
  const merged: AcpmuxRow | undefined = threads.length
    ? {
        ...first,
        id: `pending-inbox:${first.id}`,
        version: notices.reduce((sum, row) => sum + row.version, 0),
        kind: "user",
        text: inboxText(joined),
        incoming: { kind: "inbox", notice: joined },
        joined: notices.map((row) => row.id),
      }
    : undefined;
  const out: AcpmuxRow[] = [];
  for (const row of members) {
    if (row.incoming?.kind !== "inbox") out.push(row);
    else if (row === first && merged) out.push(merged);
  }
  return out;
}

/// What the group's line says: how many messages, and every sender once in the order it first wrote.
export function pendingCounts(rows: readonly AcpmuxRow[]): { messages: number; senders: string[] } {
  const senders: string[] = [];
  let messages = 0;
  for (const row of rows) {
    if (row.incoming?.kind === "inbox") {
      const counts = inboxCounts(row.incoming.notice);
      messages += counts.messages;
      for (const name of counts.senders) if (!senders.includes(name)) senders.push(name);
      continue;
    }
    messages += 1;
    const name = row.incoming?.kind === "message" ? row.incoming.message.name : "";
    if (name && !senders.includes(name)) senders.push(name);
  }
  return { messages, senders };
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
  return {
    id: PENDING_MESSAGES_ROW_ID,
    version: ++version,
    at: members[0]!.at,
    kind: PENDING_MESSAGES,
    // Find counts the messages' words; the group opens for a match in one of them.
    text: members
      .map((row) => (row.incoming?.kind === "message" ? row.incoming.message.text : (row.text ?? "")))
      .join("\n\n"),
    untyped: true,
    joined: members.map((row) => row.id),
    pendingMessages: { rows: members, displayRows: pendingDisplayRows(members) },
  };
}
