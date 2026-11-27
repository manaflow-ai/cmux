// Settled chats (acpmux hub/auto_settle.rs): acpmux archives a chat with a reason when its pull
// requests merge or close, or after idle days (Leo, 2026-11-18: "I know there's, like, the settle
// chats feature or whatever"). The pane only reads it: a chat it listed that turns up settled gets
// a toast with Undo (settledToasts.ts), and the home keeps the settled ones on a collapsed shelf
// (SettledShelf.tsx). Undo and Unsettle are the chat menu's Unarchive (`_acpmux/archive` false),
// which drops the reason too.
import { type StringKey, type Translate, translate } from "./i18n";
import { replacedSince, sessionIndex } from "./sessionIndex";
import { activityTime, type AcpmuxSessionEntry, listed, type SettleReason } from "./sessionList";

const DAY_MS = 24 * 60 * 60 * 1000;

/// The shelf shows at most this many settled chats, newest first; the rest are found by search.
export const SETTLED_ROWS = 20;

/// A copy of a chat on another computer has the same id as this Mac's: the peer tells them apart.
const keyOf = (entry: AcpmuxSessionEntry) => `${entry.peer ?? ""}\u0000${entry.sessionId}`;

/// Whether `entry` is `before` settled since: listed then (neither archived nor a side chat), settled now.
const becameSettled = (before: AcpmuxSessionEntry | undefined, entry: AcpmuxSessionEntry | undefined) =>
  before !== undefined && entry?.settled !== undefined && listed(before) && keyOf(before) === keyOf(entry);

/// Reads each session list the pane gets and answers the chats that settled since the list before:
/// a chat this client already listed that now carries a reason. The first list answers none (the
/// pane just opened), and neither does a chat first seen settled or one that was already archived.
/// A list made in place from the one before (one session's change, sessionIndex.ts `noteReplaced`)
/// costs its changed rows; any other costs the settled chats, through the list's shared index.
export function createSettleWatch(): (sessions: readonly AcpmuxSessionEntry[]) => AcpmuxSessionEntry[] {
  let last: readonly AcpmuxSessionEntry[] | undefined;
  return (sessions) => {
    const before = last;
    last = sessions;
    if (!before || before === sessions) return [];
    const changed = replacedSince(before, sessions);
    if (changed) return changed.filter((at) => becameSettled(before[at], sessions[at])).map((at) => sessions[at]!);
    const settled = sessionIndex(sessions).of("settled");
    if (settled.length === 0) return [];
    const earlier = sessionIndex(before);
    const find = earlier.unique
      ? (entry: AcpmuxSessionEntry) => earlier.get(entry.sessionId)
      : (
          (byKey) => (entry: AcpmuxSessionEntry) =>
            byKey.get(keyOf(entry))
        )(new Map(before.map((entry) => [keyOf(entry), entry])));
    return settled.filter((entry) => becameSettled(find(entry), entry));
  };
}

/// The home's Settled shelf: settled chats but side chats and the shown one, newest first, at most
/// `SETTLED_ROWS`, with how many there are.
export function settledShelf(
  sessions: readonly AcpmuxSessionEntry[],
  currentId?: string,
): { rows: AcpmuxSessionEntry[]; total: number } {
  const all = sessionIndex(sessions)
    .of("settled")
    .filter((entry) => !entry.side && entry.sessionId !== currentId);
  const rows = all.sort((left, right) => (activityTime(right) ?? 0) - (activityTime(left) ?? 0)).slice(0, SETTLED_ROWS);
  return { rows, total: all.length };
}

const REASONS: Record<Exclude<SettleReason, "idle" | "manual">, StringKey> = {
  merged: "settle.reason.merged",
  closed: "settle.reason.closed",
};

/// Why a chat settled, in words: "PR merged", "PR closed", "idle 3 days"; undefined for one settled
/// by hand. Idle counts whole days since the chat's last activity, which is what acpmux measured;
/// with no activity time it says nothing.
export function settleReasonText(
  entry: Pick<AcpmuxSessionEntry, "settled" | "activityAt" | "updatedAt">,
  now = Date.now(),
  t: Translate = translate,
): string | undefined {
  const reason = entry.settled;
  if (reason === undefined || reason === "manual") return undefined;
  if (reason !== "idle") return t(REASONS[reason]);
  const since = activityTime(entry);
  if (since === undefined || since > now) return undefined;
  return t("settle.reason.idleDays", { n: Math.max(1, Math.floor((now - since) / DAY_MS)) });
}

/// The toast's line: "Settled: Fix the cache — PR merged", or without a reason for a manual settle.
export function settledToastText(entry: AcpmuxSessionEntry, now = Date.now(), t: Translate = translate): string {
  const title = entry.displayTitle ?? entry.title ?? entry.name ?? entry.sessionId;
  const reason = settleReasonText(entry, now, t);
  return reason ? t("settle.toast", { title, reason }) : t("settle.toastPlain", { title });
}

/// Whether a key press is the settle toast's Undo: Cmd+Z or Ctrl+Z alone, outside any editable
/// field. In one it stays the field's own undo, even when the field is empty: deleting all its text
/// leaves that text to undo.
export function isSettleUndoKey(event: KeyboardEvent): boolean {
  if (event.key.toLowerCase() !== "z" || event.shiftKey || event.altKey || event.repeat) return false;
  if (event.metaKey === event.ctrlKey) return false;
  const target = event.target as HTMLElement | null;
  if (!target || typeof target.closest !== "function") return true;
  return !target.closest("input, textarea, [contenteditable]:not([contenteditable='false'])");
}
