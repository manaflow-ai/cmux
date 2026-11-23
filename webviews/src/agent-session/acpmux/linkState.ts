/// acpmux's whole machine link state (`_acpmux/peer_state_changed` and `_acpmux/peers` `link`,
/// acpmux `protocol/peer_state.rs` `MachineLink`). acpmux owns it: the pane only reads it and draws it
/// (peerLink.ts), with no clock of its own. An older daemon sends no `link`; its `state` word (one of
/// the first six) stands in.
export type AcpmuxLink =
  | "connected"
  | "connecting"
  | "reconnecting"
  | "restarting"
  | "degraded"
  | "offline"
  | "authFailed"
  | "updateRequired"
  | "paused";

/// Why a link is down (`cause`): this Mac's network, the team hub, the machine, or a refused token.
export type LinkCause = "localNetwork" | "hubDown" | "peerDown" | "auth";

/// The carrier of the open link (`carrier`).
export type LinkCarrier = "direct" | "ssh" | "hub" | "cloud";

/// One peer's link as acpmux said it.
export type PeerLinkDetail = {
  link: AcpmuxLink;
  carrier?: LinkCarrier;
  cause?: LinkCause;
  /// When `link` took its value, ms since the epoch.
  since?: number;
  /// When acpmux dials again on its own, ms since the epoch.
  nextRetryAt?: number;
};

export const ACPMUX_LINKS: ReadonlySet<string> = new Set<AcpmuxLink>([
  "connected",
  "connecting",
  "reconnecting",
  "restarting",
  "degraded",
  "offline",
  "authFailed",
  "updateRequired",
  "paused",
]);
const CAUSES: ReadonlySet<string> = new Set<LinkCause>(["localNetwork", "hubDown", "peerDown", "auth"]);
const CARRIERS: ReadonlySet<string> = new Set<LinkCarrier>(["direct", "ssh", "hub", "cloud"]);

const time = (value: unknown) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);

/// A note's or a peer row's link (`link`, else its `state` word from an older daemon), or undefined
/// when it names none acpmux sends.
export function readPeerLinkDetail(value: unknown): PeerLinkDetail | undefined {
  if (!value || typeof value !== "object") return undefined;
  const raw = value as Record<string, unknown>;
  const sent = (word: unknown) => (typeof word === "string" && ACPMUX_LINKS.has(word) ? word : undefined);
  const word = sent(raw.link) ?? sent(raw.state);
  if (word === undefined) return undefined;
  const detail: PeerLinkDetail = { link: word as AcpmuxLink };
  if (typeof raw.carrier === "string" && CARRIERS.has(raw.carrier)) detail.carrier = raw.carrier as LinkCarrier;
  if (typeof raw.cause === "string" && CAUSES.has(raw.cause)) detail.cause = raw.cause as LinkCause;
  const since = time(raw.since);
  if (since !== undefined) detail.since = since;
  const nextRetryAt = time(raw.nextRetryAt);
  if (nextRetryAt !== undefined) detail.nextRetryAt = nextRetryAt;
  return detail;
}
