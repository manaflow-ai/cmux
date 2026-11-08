/// The link of the acpmux peer a chat runs on, as the composer's quiet row draws it
/// (MachineLinkStatus.tsx): only what acpmux reports for that peer's link (`PeerLinkState`,
/// `peer_link.rs`), in the sidebar machine header's states (connected, connecting, offline).
export type LinkState = "connected" | "connecting" | "offline";

export type PeerLink = {
  /// The peer's name, as acpmux knows it (`summary.peer`): what the row writes and what Reconnect asks for.
  machine: string;
  link: LinkState;
  /// A link coming back rather than coming up the first time: "Reconnecting…", not "Connecting…".
  reconnecting?: true;
};

/// acpmux's peer link states (`peer_link.rs` `as_str`) in the sidebar's words: a link that has not
/// finished its handshake again is on its way (`degraded`, `restarting`, `reconnecting`).
const PEER_LINKS: Record<string, { link: LinkState; reconnecting?: true }> = {
  connected: { link: "connected" },
  connecting: { link: "connecting" },
  degraded: { link: "connecting", reconnecting: true },
  reconnecting: { link: "connecting", reconnecting: true },
  restarting: { link: "connecting", reconnecting: true },
  offline: { link: "offline" },
};

type LinkSnapshot = {
  summary?: { peer?: string } | undefined;
  peerKinds?: Record<string, "ssh" | "cloud"> | undefined;
  peerStates?: Record<string, string> | undefined;
  peerConnected?: Record<string, boolean> | undefined;
};

/// The link of the peer the open chat runs on (the session this Mac's acpmux mirrors,
/// `summary.peer`), as acpmux last said it (`peerStates`, kept current by
/// `_acpmux/peer_state_changed`; `peerConnected` before the first state arrives), or null for a chat
/// on this Mac. A Cloud peer that is not answering says nothing here: the peer copy banner says
/// whether it is paused or starting, and offers Resume (PeerCopyBanner.tsx). O(1).
export function peerLink(snapshot: LinkSnapshot): PeerLink | null {
  const peer = snapshot.summary?.peer;
  if (!peer) return null;
  const said = snapshot.peerStates?.[peer];
  const connected = snapshot.peerConnected?.[peer];
  const known: { link: LinkState; reconnecting?: true } | undefined =
    said !== undefined
      ? PEER_LINKS[said]
      : connected === undefined
        ? undefined
        : { link: connected ? "connected" : "offline" };
  if (!known) return null;
  if (known.link === "offline" && snapshot.peerKinds?.[peer] === "cloud") return null;
  return { machine: peer, link: known.link, ...(known.reconnecting ? { reconnecting: true } : {}) };
}
