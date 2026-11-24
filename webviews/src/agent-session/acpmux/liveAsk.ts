import type { AcpmuxSnapshot } from "./model";

/// The statuses acpmux reports for a chat whose turn can still be waiting on an answer
/// (store.rs `SessionStatus`: `running`, and `waiting`, "waiting for a permission answer").
const ASKING_STATUSES = new Set(["running", "waiting"]);

/// The snapshot as the pane draws its permission card: the chat's pending ask only while the chat
/// can still be waiting on it. One kept past its turn (acpmux reports the chat `idle`, `ready`,
/// `closed` or `disconnected`: the turn ended, was stopped, or its agent is gone) is dropped with
/// the asks queued behind it, so no Allow button shows beside a stopped or finished turn, where a
/// press could only fail (Leo 2026-11-11: "the permission state gets [messed up]"). A chat that has
/// not reported a status yet keeps its ask: acpmux sent it, so a turn asks. The same snapshot
/// comes back when nothing is dropped.
export function liveAsk(snapshot: AcpmuxSnapshot): AcpmuxSnapshot {
  if (!snapshot.permission?.pending) return snapshot;
  const status = snapshot.summary?.status;
  if (status === undefined || snapshot.isWorking || ASKING_STATUSES.has(status)) return snapshot;
  return { ...snapshot, permission: undefined, permissionsWaiting: undefined, permissionsQueued: undefined };
}
