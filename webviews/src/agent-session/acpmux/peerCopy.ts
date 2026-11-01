// A peer chat as the Mac's acpmux last saw it (`_acpmux/peer_snapshot`, acpmux
// hub/peer_snapshot.rs): a chat that runs on another machine (huge-blue, a Cloud VM) paints at once
// from it, as a kept tail (tailCache.ts), and stays, marked possibly stale, while that machine is
// paused or offline. Once the machine answers, its attach page continues the copy where they join
// (each seq once) and replaces it where they do not. The machine's own log stays the chat: this
// copy is never written back, never a reason to send, and a session the machine recreated
// (another `createdAt`) replaces it.
//
// Lawrence: "start new VMs from acp chat - decouple persistence of acp trajectories from the VM
// itself, in case the VM is resuming" (cmuxterm-hq#4381, "Persistence, pause and resume").
import type { EventRecord } from "./direct";
import type { KeptTail } from "./tailCache";

/// The longest an open waits on the Mac's daemon for its copy. It answers from its own disk, so
/// this only keeps a daemon that does not answer (an older one has no such method) from holding a
/// chat up, as `HOST_TAIL_READ_MS` does for the app host's tail.
export const PEER_COPY_READ_MS = 400;

/// What the pane says about a chat drawn from the copy.
export type PeerCopyState = {
  /// The machine the chat runs on.
  peer: string;
  /// When the Mac last kept a record of it (ms), if it says.
  capturedAt?: number;
  /// The machine did not answer this page's attach: the rows are the copy, not the chat.
  offline: boolean;
};

export type PeerCopy = PeerCopyState & {
  sessionId: string;
  /// The session the copy is of (its `createdAt`); an attach naming another one replaces it.
  generation?: number;
  /// The copy's newest seq: what an attach of it continues from.
  lastSeq: number;
  /// An attach of it is out (the open's, or one after its machine came back): no other starts.
  attaching?: boolean;
};

/// Whether a copy of generation `kept` (its `createdAt`) is of the session that names `current`:
/// when either is unknown, it cannot be told, so it is not.
export function sameGeneration(kept: unknown, current: unknown): boolean {
  return typeof kept === "number" && typeof current === "number" && kept === current;
}

/// The daemon's `_acpmux/peer_snapshot` reply as a tail the pane draws (`drawKeptTail`), and what
/// the pane keeps of it; undefined when it holds no record of the chat.
export function peerCopyTail(reply: unknown, sessionId: string): { tail: KeptTail; copy: PeerCopy } | undefined {
  const r = (reply ?? {}) as Record<string, unknown>;
  const listed = Array.isArray(r.events) ? r.events : [];
  const events = listed.filter(
    (e): e is EventRecord =>
      typeof e === "object" &&
      e !== null &&
      typeof (e as EventRecord).seq === "number" &&
      typeof (e as EventRecord).kind === "string",
  );
  const peer = typeof r.peer === "string" ? r.peer : undefined;
  if (events.length === 0 || !peer) return undefined;
  const summary = typeof r.summary === "object" && r.summary !== null ? (r.summary as Record<string, any>) : undefined;
  const whole = r.hasMore === false && events.length === listed.length;
  const tail: KeptTail = {
    events,
    summary,
    turnOpener: undefined,
    historyExhausted: whole,
    queue: [],
    configSeq: 0,
    // A copy that starts after the chat's first record cannot add up its usage.
    usageFromSeq: whole ? 0 : events[0]!.seq,
  };
  const number = (v: unknown) => (typeof v === "number" ? v : undefined);
  const copy: PeerCopy = {
    sessionId,
    peer,
    capturedAt: number(r.capturedAt),
    generation: number(r.generation),
    lastSeq: Math.max(number(r.lastSeq) ?? 0, ...events.map((e) => e.seq)),
    offline: false,
  };
  return { tail, copy };
}

/// The attach failed because the chat's machine is down (acpmux `peer_unreachable`), not because
/// the chat is gone: what the pane drew of it can stay, marked as a copy.
export function peerDown(error: unknown): boolean {
  const reason = (error as { reason?: unknown } | undefined)?.reason;
  if (reason === "peer_unreachable") return true;
  const message = error instanceof Error ? error.message : "";
  return message.startsWith("peer_unreachable");
}

/// The machine's row says it answers again (a `session_changed` that is not last-known).
export function peerBack(summary: Record<string, any> | undefined): boolean {
  return !!summary && summary.stale !== true && summary.status !== "unreachable";
}
