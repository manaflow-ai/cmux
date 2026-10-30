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
// The same message is shown once (Leo: "nx-sidebar #27128 own red fixed..." twice): by its prompt
// id, else by its sender and whole text (a relay retried under a new id) when it carries no images,
// its text is not acpmux's cut preview (two messages can share a preview's head), and both are
// queued or both are steers (a steer never hides a queue entry it cannot take back). The
// copy that shows carries the hidden copies' queue entries (`queuedMessage.twins`), so its Dismiss
// takes back every copy and none comes back after it.
//
// Cost: nothing while nothing waits. The group is made once per change of the waiting rows; the
// same rows give the same row back, so the transcript keeps its identity.
import { PENDING_MESSAGES, QUEUED_MESSAGE, type AcpmuxRow } from "../model";
import { nextQueuedRowVersion } from "./queuedMessages";

/// The group's row id: one while any message waits.
export const PENDING_MESSAGES_ROW_ID = "pending-messages";

/// Whether `row` is another session's message the agent has not read yet in the running turn.
export const isWaitingMessage = (row: AcpmuxRow) =>
  row.kind === "user" && row.steer === "waiting" && row.incoming?.kind === "message";

/// A waiting message's prompt id: the queue entry's, or the steer's.
const promptIdOf = (row: AcpmuxRow) => row.queuedMessage?.promptId ?? row.steerPromptId;

/// The key a sender's message is the same under: its sender and its whole words. A message with
/// images has none: two "See attached" with different images are two messages, only one prompt id is
/// one. Nor has one whose words are acpmux's cut preview (a reload's queue list, direct.ts
/// `mergeQueue`): two messages can share their first 200 characters, and folding them would hide one
/// and let Dismiss or Send now on the other take it back too. A steer and a queued message are
/// never the same by their words, only by one prompt id: the steer is already in the running turn and
/// the queue entry is due after it, so hiding the entry behind the steer would leave it queued, with
/// no Dismiss of its own, after the steer is sent or read.
function contentKey(row: AcpmuxRow): string | undefined {
  if (row.incoming?.kind !== "message" || row.images?.length || row.queuedMessage?.preview) return undefined;
  const { name, sessionId, text } = row.incoming.message;
  return `${row.kind === QUEUED_MESSAGE ? "queued" : "steer"}\u0000${sessionId ?? name}\u0000${text.trim()}`;
}

/// `rows` with each message once: the first of those with one prompt id, or one sender and text.
export function dedupeMessages(rows: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (rows.length < 2) return rows;
  const ids = new Set<string>();
  const texts = new Set<string>();
  let out: AcpmuxRow[] | undefined;
  rows.forEach((row, index) => {
    const id = promptIdOf(row);
    const text = contentKey(row);
    const seen = (id !== undefined && ids.has(id)) || (text !== undefined && texts.has(text));
    if (id !== undefined) ids.add(id);
    if (text !== undefined) texts.add(text);
    if (seen) out ??= rows.slice(0, index);
    else out?.push(row);
  });
  return out ?? rows;
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

/// The shown message of `members` a hidden copy was folded into (the same prompt id, or the same
/// sender and words).
function shownCopy(members: readonly AcpmuxRow[], hidden: AcpmuxRow): AcpmuxRow | undefined {
  const id = promptIdOf(hidden);
  const text = contentKey(hidden);
  return members.find(
    (row) => (id !== undefined && promptIdOf(row) === id) || (text !== undefined && contentKey(row) === text),
  );
}

/// The shown message in `group` that draws waiting row `rowId`: itself, or the first copy a
/// duplicate was folded into.
export function pendingMemberId(group: AcpmuxRow, rowId: string): string {
  const members = group.pendingMessages?.rows ?? [];
  if (members.some((row) => row.id === rowId)) return rowId;
  const hidden = (group.pendingMessages?.all ?? []).find((row) => row.id === rowId);
  return (hidden && shownCopy(members, hidden)?.id) ?? rowId;
}

/// `members` with each queued one carrying the queue entries of its hidden copies in `waiting`
/// (`queuedMessage.twins`); the same array when nothing was folded.
function withTwins(members: readonly AcpmuxRow[], waiting: readonly AcpmuxRow[]): readonly AcpmuxRow[] {
  if (members.length === waiting.length) return members;
  const shown = new Set(members);
  const twins = new Map<AcpmuxRow, string[]>();
  for (const row of waiting) {
    const promptId = row.queuedMessage?.promptId;
    if (shown.has(row) || promptId === undefined) continue;
    const copy = shownCopy(members, row);
    if (!copy?.queuedMessage || copy.queuedMessage.promptId === promptId) continue;
    const list = twins.get(copy) ?? [];
    if (!list.includes(promptId)) list.push(promptId);
    twins.set(copy, list);
  }
  if (twins.size === 0) return members;
  return members.map((row) => {
    const list = twins.get(row);
    return list && row.queuedMessage ? carrying(row, list) : row;
  });
}

// The copy that carries its twins, by the row it was made from: the same twins give the same row back.
const carriers = new WeakMap<AcpmuxRow, { key: string; row: AcpmuxRow }>();

/// `row` carrying `twins`, as a new version: the transcript memoizes a queued message's row by its id
/// and version (App.tsx QueuedMessageRow), so a duplicate that arrives or leaves after the copy was
/// drawn draws it again, and its Dismiss and Send now take back exactly the twins it shows.
function carrying(row: AcpmuxRow, twins: string[]): AcpmuxRow {
  const key = twins.join("\u0000");
  const held = carriers.get(row);
  if (held?.key === key) return held.row;
  const made = { ...row, version: nextQueuedRowVersion(), queuedMessage: { ...row.queuedMessage!, twins } };
  carriers.set(row, { key, row: made });
  return made;
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
  const waiting = all.filter((row) => row.kind === QUEUED_MESSAGE || isWaitingMessage(row));
  const members = withTwins(dedupeMessages(waiting), waiting);
  if (members.length === 0) return undefined;
  const held = last?.pendingMessages?.all;
  if (held && held.length === waiting.length && held.every((row, index) => row === waiting[index])) return last;
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
    // Every waiting row, a hidden duplicate too: Find counts each queued entry (App.tsx findRows), and
    // a match in a duplicate lands here and on the copy that shows.
    joined: waiting.map((row) => row.id),
    pendingMessages: { rows: members, all: waiting },
  };
}
