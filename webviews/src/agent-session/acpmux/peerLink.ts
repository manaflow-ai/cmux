import type { AcpmuxLink, LinkCause, PeerLinkDetail } from "./linkState";

/// The link of the acpmux peer a chat runs on, as the composer's quiet row draws it
/// (MachineLinkStatus.tsx): only what acpmux reports for that peer's link (`link`, linkState.ts;
/// `peer_link.rs`), in the sidebar machine header's states (connected, connecting, offline). The
/// mapping is the sidebar's own (`cmux-layout-reducer` `sidebar_bridge::link::peer_link`), so the row
/// and the sidebar never disagree; nothing here keeps a clock.
export type LinkState = "connected" | "connecting" | "offline";

/// Why a link that is down needs more than a retry, or where the fault is, in the row's words.
export type LinkWhy = "authFailed" | "updateRequired" | "localNetwork";

export type PeerLink = {
  /// The peer's name, as acpmux knows it (`summary.peer`): what the row writes and what Reconnect asks for.
  machine: string;
  link: LinkState;
  /// A link coming back rather than coming up the first time: "Reconnecting…", not "Connecting…".
  reconnecting?: true;
  /// What the row says instead of the plain state: a refused sign-in, an update the machine needs, or
  /// this Mac's own network being down (acpmux's `cause`).
  why?: LinkWhy;
  /// A person must act (sign-in, an update): no Reconnect.
  stuck?: true;
};

type Shown = { link: LinkState; reconnecting?: true; why?: LinkWhy; stuck?: true } | null;

/// Every acpmux link state in the row's terms: a link that has not finished its handshake again is on
/// its way (`degraded`, `restarting`, `reconnecting`); a refused token or an old build is down and waits
/// for a person; a paused Cloud machine is the peer copy banner's (null).
export const PEER_LINKS: Record<AcpmuxLink, Shown> = {
  connected: { link: "connected" },
  connecting: { link: "connecting" },
  degraded: { link: "connecting", reconnecting: true },
  reconnecting: { link: "connecting", reconnecting: true },
  restarting: { link: "connecting", reconnecting: true },
  offline: { link: "offline" },
  authFailed: { link: "offline", why: "authFailed", stuck: true },
  updateRequired: { link: "offline", why: "updateRequired", stuck: true },
  paused: null,
};

const LOCAL = "localNetwork" satisfies LinkCause;

type LinkSnapshot = {
  summary?: { peer?: string } | undefined;
  peerKinds?: Record<string, "ssh" | "cloud"> | undefined;
  peerStates?: Record<string, string> | undefined;
  peerLinks?: Record<string, PeerLinkDetail> | undefined;
  peerConnected?: Record<string, boolean> | undefined;
};

/// The link of the peer the open chat runs on (the session this Mac's acpmux mirrors,
/// `summary.peer`), as acpmux last said it (`peerLinks`, else an older daemon's `peerStates` word,
/// both kept current by `_acpmux/peer_state_changed`; `peerConnected` before the first state
/// arrives), or null for a chat on this Mac. A Cloud peer that is not answering, or paused, says
/// nothing here: the peer copy banner says whether it is paused or starting, and offers Resume
/// (PeerCopyBanner.tsx). O(1).
export function peerLink(snapshot: LinkSnapshot): PeerLink | null {
  const peer = snapshot.summary?.peer;
  if (!peer) return null;
  const detail = snapshot.peerLinks?.[peer];
  const said = detail?.link ?? snapshot.peerStates?.[peer];
  const connected = snapshot.peerConnected?.[peer];
  const known: Shown | undefined =
    said !== undefined
      ? PEER_LINKS[said as AcpmuxLink]
      : connected === undefined
        ? undefined
        : { link: connected ? "connected" : "offline" };
  if (!known) return null;
  if (known.link === "offline" && snapshot.peerKinds?.[peer] === "cloud") return null;
  const why: LinkWhy | undefined =
    known.why ?? (known.link !== "connected" && detail?.cause === LOCAL ? LOCAL : undefined);
  return {
    machine: peer,
    link: known.link,
    ...(known.reconnecting ? { reconnecting: true } : {}),
    ...(why ? { why } : {}),
    ...(known.stuck ? { stuck: true } : {}),
  };
}
