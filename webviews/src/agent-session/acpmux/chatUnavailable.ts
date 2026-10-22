// Why a tab's chat is not here (`missingSession`): the pane tells "deleted" from "its machine is
// not connected" from "its machine is still connecting", so a chat that is only loading never reads
// as gone (Leo 2026-10-21: "second pic is weird has "this chat isn't available"").
//
// acpmux keeps listing a peer's chats while that peer is down (stale, from the list it last had or
// saved, hub/peer_cache.rs), so a chat it does not list is deleted, unless it is on a machine whose
// list acpmux does not hold: one it has never reached (no `lastSeen`), or the chat's own machine
// when the pane knows it. `_acpmux/status` says each peer's `state`, `lastSeen` and failed
// `attempts` (acpmux peer.rs `Peer::summary`); the app's relay passes those through
// (AcpmuxPaneMethods+ReplyShapes).

/// One peer as `_acpmux/status` last said.
export type PeerStatus = {
  connected?: boolean;
  /// acpmux's link state: `connecting`, `connected`, `degraded`, `reconnecting` or `offline`.
  state?: string;
  /// When the peer last answered, in milliseconds since the epoch.
  lastSeen?: number;
  /// Failed attempts since the link was last ready.
  attempts?: number;
};

/// What the pane shows in place of a chat the daemon does not list.
export type ChatUnavailable =
  | { reason: "deleted" }
  /// The chat's machine is still connecting: the chat may be there once it does (loading).
  | { reason: "connecting"; machine?: string }
  /// The chat's machine is not connected; `machine` when the pane knows which one.
  | { reason: "offline"; machine?: string; lastSeen?: number };

/// How long a machine still in its first attempts counts as loading; after that it is offline.
export const CONNECTING_GRACE_MS = 30_000;

/// Each peer's status from `_acpmux/status`; fields that are not the right JSON type are left out.
export function peerStatusFromStatus(status: unknown): Record<string, PeerStatus> {
  const peers = (status as { peers?: unknown } | undefined)?.peers;
  if (!Array.isArray(peers)) return {};
  const out: Record<string, PeerStatus> = {};
  for (const peer of peers) {
    const { name, connected, state, lastSeen, attempts } = (peer ?? {}) as Record<string, unknown>;
    if (typeof name !== "string" || !name) continue;
    out[name] = {
      ...(typeof connected === "boolean" ? { connected } : {}),
      ...(typeof state === "string" && state ? { state } : {}),
      ...(typeof lastSeen === "number" && Number.isFinite(lastSeen) && lastSeen > 0 ? { lastSeen } : {}),
      ...(typeof attempts === "number" && Number.isFinite(attempts) ? { attempts } : {}),
    };
  }
  return out;
}

/// A peer whose chats acpmux has listed: its link is ready (`connected`). A socket that is open
/// but still in its handshake says `connected: true, state: "degraded"` before acpmux has read its
/// chats (acpmux peer.rs `serve`), so `connected` alone does not settle it; an older daemon that
/// says no `state` is read by `connected`.
function settled(status: PeerStatus): boolean {
  return status.state !== undefined ? status.state === "connected" : status.connected === true;
}

/// A peer still on its way up: acpmux's first attempt (`connecting`), a socket whose handshake has
/// not finished (`degraded`), or a saved peer a restarted daemon has not tried yet.
function stillConnecting(status: PeerStatus): boolean {
  if (settled(status)) return false;
  if (status.state === "connecting" || status.state === "degraded") return true;
  return status.state === "reconnecting" && (status.attempts ?? 0) === 0;
}

/**
 * Why the chat is not listed. `peer` is the machine the chat was last seen on (its summary's
 * peer), when the pane knows it. `waitedMs` is how long the pane has been without the chat:
 * a machine still connecting past `CONNECTING_GRACE_MS` is offline.
 */
export function chatUnavailable(input: {
  peer?: string;
  peers: Record<string, PeerStatus>;
  waitedMs: number;
}): ChatUnavailable {
  const { peer, peers, waitedMs } = input;
  const grace = waitedMs < CONNECTING_GRACE_MS;
  if (peer !== undefined) {
    // The chat's own machine: once acpmux has its chats, the chat is gone from it; one acpmux no
    // longer lists, or that is down, is not connected.
    const status = peers[peer];
    if (status && settled(status)) return { reason: "deleted" };
    if (status && grace && stillConnecting(status)) return { reason: "connecting", machine: peer };
    return {
      reason: "offline",
      machine: peer,
      ...(status?.lastSeen !== undefined ? { lastSeen: status.lastSeen } : {}),
    };
  }
  // The chat's machine is not known. A machine still connecting may list it once acpmux has its
  // chats (loading); past that, only a machine acpmux has never reached could hold it unlisted.
  const connecting = Object.entries(peers).filter(([, status]) => stillConnecting(status));
  if (grace && connecting.length > 0)
    return connecting.length === 1 ? { reason: "connecting", machine: connecting[0]![0] } : { reason: "connecting" };
  const unreached = Object.entries(peers).filter(
    ([, status]) => !settled(status) && status.connected !== true && status.lastSeen === undefined,
  );
  if (unreached.length === 0) return { reason: "deleted" };
  return unreached.length === 1 ? { reason: "offline", machine: unreached[0]![0] } : { reason: "offline" };
}
