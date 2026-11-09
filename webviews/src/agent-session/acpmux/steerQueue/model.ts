// Steer queue (steerQueue.experiment.ts, off by default): every live chat in one keyboard list,
// ranked by which one needs the person now, so they can step into a running agent (steer it,
// redirect it, stop it, fork it) without opening each chat first. Needs you (../needsYou/) lists
// the asks; this list also holds the chats that ask nothing yet but may need a hand: a failed turn,
// a running turn that has gone quiet, a finished one nobody has read.
//
// Nothing here is a store: every item comes from the session list acpmux already reports, so a
// chat moves or leaves as soon as acpmux says its state changed. The one thing kept is the
// person's own record of where they stepped in (log.ts), which the rows show beside each chat.
import { activityTime, listed, sessionTitle, withoutChildren, type AcpmuxSessionEntry } from "../sessionList";
import type { SteerAct } from "./log";

/// Why a chat is in the queue, in the order the queue ranks them: it waits on the person
/// (`ask`), its turn failed or its machine is gone (`failed`), its turn runs but has said nothing
/// for `STALLED_MS` (`stalled`), it finished and is unread (`review`), or it runs (`running`).
export type SteerReason = "ask" | "failed" | "stalled" | "review" | "running";

const RANK: Record<SteerReason, number> = { ask: 0, failed: 1, stalled: 2, review: 3, running: 4 };

/// A running turn quiet for this long is worth a look: most tool calls report well within it.
export const STALLED_MS = 4 * 60_000;

/// The queue draws at most this many chats, one digit key each: its cost stays the same however
/// many chats acpmux lists, and past nine the person is better served by Needs you or the sidebar.
export const STEER_QUEUE_LIMIT = 9;

export type SteerItem = {
  sessionId: string;
  title: string;
  reason: SteerReason;
  /// What the chat is doing or saying now, on one line: its ask, its error, its live step, or its
  /// latest reply.
  line?: string;
  host?: string;
  harness?: string;
  /// When the reason began, as near as acpmux tells (epoch ms): the ask, the last activity.
  at?: number;
  /// A turn runs: a typed line steers into it, and Stop and Redirect apply.
  running: boolean;
  /// The person's latest step into this chat from the queue, when there is one.
  last?: SteerAct;
};

export type SteerQueueInput = {
  sessions: readonly AcpmuxSessionEntry[];
  now: number;
  /// The person's record of steps into chats (log.ts), newest last.
  log?: readonly SteerAct[];
};

export function steerQueue({ sessions, now, log = [] }: SteerQueueInput): SteerItem[] {
  const lastAct = new Map<string, SteerAct>();
  for (const act of log) lastAct.set(act.sessionId, act);
  const items: SteerItem[] = [];
  for (const session of withoutChildren(sessions.filter(listed))) {
    if (session.unsent) continue;
    const reason = steerReason(session, now);
    if (!reason) continue;
    const last = lastAct.get(session.sessionId);
    items.push({
      sessionId: session.sessionId,
      title: session.displayTitle || sessionTitle(session),
      reason,
      ...optional("line", steerLine(session, reason)),
      ...optional("host", session.hostKind === "cloud" || session.peer ? session.host : undefined),
      ...optional("harness", session.harness),
      ...optional("at", activityTime(session)),
      running: reason === "running" || reason === "stalled",
      ...(last ? { last } : {}),
    });
  }
  // The longest wait first within a reason, since it has waited the longest; a finished chat
  // newest first, as every list of chats in the pane.
  items.sort((a, b) => {
    const rank = RANK[a.reason] - RANK[b.reason];
    if (rank) return rank;
    return a.reason === "review" ? (b.at ?? 0) - (a.at ?? 0) : (a.at ?? Infinity) - (b.at ?? Infinity);
  });
  return items.slice(0, STEER_QUEUE_LIMIT);
}

/// Why a chat needs the person, or undefined when it needs nothing (idle and read, or archived).
export function steerReason(session: AcpmuxSessionEntry, now: number): SteerReason | undefined {
  // A chat whose machine is unreachable waits on nobody: it is a failure to look at, never an ask.
  if (session.indicator === "lost" || session.lane === "lost") return "failed";
  // As Needs you reads it (needsYou/model.ts `waitsOnPerson`): a local chat acpmux says is not
  // waiting has nothing pending, whatever its dot last said.
  if (
    (session.pendingPermissions ?? 0) > 0 ||
    session.waitingOn ||
    session.status === "waiting" ||
    (session.indicator === "input" && (Boolean(session.peer) || session.status === undefined))
  )
    return "ask";
  if (session.indicator === "failed" || session.lane === "failed") return "failed";
  if (session.indicator === "working" || session.status === "running" || session.lane === "working") {
    const at = activityTime(session);
    return at !== undefined && now - at >= STALLED_MS ? "stalled" : "running";
  }
  if (session.unread && session.indicator === "done") return "review";
  return undefined;
}

function steerLine(session: AcpmuxSessionEntry, reason: SteerReason): string | undefined {
  const reply = session.preview || session.lastMessage;
  switch (reason) {
    case "ask":
      return session.waitingOn?.on === "question" ? session.waitingOn.prompt || reply : session.doing || reply;
    case "failed":
      return session.laneError || reply;
    case "stalled":
    case "running":
      return session.doing || session.doingTool || reply;
    case "review":
      return reply;
  }
}

/// The index the queue's focus moves to after a step into item `index`, so the person goes on
/// down the list: the next item, or the one before when it was the last.
export function nextFocus(count: number, index: number): number {
  if (count <= 1) return 0;
  return index + 1 < count ? index + 1 : index - 1;
}

const optional = <K extends string, V>(key: K, value: V | undefined) =>
  (value === undefined || value === "" ? {} : { [key]: value }) as Partial<Record<K, V>>;
