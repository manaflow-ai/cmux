import type { PeerLinkState } from "./protocol/generated/types";

/// Every state acpmux sends (peer_link.rs `PeerState::as_str`). Notes carry the protocol's
/// `PeerLinkState`; `_acpmux/peers` also says `restarting` while the peer's daemon restarts, and a
/// snapshot that dropped that row would leave the picker no state, so it would read the peer as ready.
type LinkState = PeerLinkState | "restarting";
const STATES = new Set<unknown>(["connecting", "connected", "degraded", "reconnecting", "restarting", "offline"]);
type Link = { state: LinkState; connected: boolean; lastSeen: number | undefined; error: string | undefined };
type VersionedLink = { link: Link; revision: number };
const object = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
const same = (a: Link | undefined, b: Link) => a?.state === b.state && a.lastSeen === b.lastSeen && a.error === b.error;

/// One local/app connection's snapshot and pushed state. The daemon names both proven origins
/// `local`; a peer daemon's connection never hears this host's peer inventory (#26860).
export class PeerStateEvents {
  supported = false;
  authoritative = false;
  /// One clock for notes and for the start of every read, status and snapshot alike: an entry keeps
  /// the tick it was written at, and a read that lands is ordered against the others by the tick it
  /// started at, so neither kind of read brings back or erases what a newer one said.
  private clock = 0;
  /// The newest snapshot read started; only that one may land.
  private latestRead = 0;
  /// The start of the newest status read and of the newest snapshot that landed.
  private statusLanded = 0;
  private snapshotLanded = 0;
  private links = new Map<string, VersionedLink>();

  configure(initialized: unknown): void {
    const acpmux = object(object(object(initialized)._meta).acpmux);
    this.supported =
      acpmux.origin === "local" && Array.isArray(acpmux.features) && acpmux.features.includes("peerStateEvents");
    this.authoritative = false;
    this.links.clear();
    // The clock never goes back, so no read from before reads as one from this connection.
    this.latestRead = 0;
    this.statusLanded = this.clock;
    this.snapshotLanded = this.clock;
  }

  /// Whether anything here overlays a status read.
  get observed(): boolean {
    return this.authoritative || this.links.size > 0;
  }

  changed(value: unknown): boolean {
    const note = object(value);
    const link = observation(note);
    if (
      !this.supported ||
      typeof note.peer !== "string" ||
      !note.peer ||
      !link ||
      typeof note.at !== "number" ||
      !Number.isFinite(note.at)
    )
      return false;
    const previous = this.links.get(note.peer)?.link;
    // Even a repeated note fences an in-flight stale read, without redrawing identical content.
    this.links.set(note.peer, { link, revision: ++this.clock });
    return !same(previous, link);
  }

  /// A `_acpmux/peers` read starts: its tick, which `snapshot` takes when it lands.
  readStarted(): number {
    this.latestRead = ++this.clock;
    return this.latestRead;
  }

  /// A `_acpmux/status` read starts: its tick, which `statusRead` takes when it lands.
  statusStarted(): number {
    return ++this.clock;
  }

  /// The snapshot read started at `start` landed. A newer snapshot read, or a status read that
  /// started later and already landed, says more than it does: it is dropped. Entries written after
  /// it started (a note, a newer status read's) stay.
  snapshot(value: unknown, start = this.latestRead): boolean {
    const peers = object(value).peers;
    if (!this.supported || start !== this.latestRead || start < this.statusLanded || !Array.isArray(peers))
      return false;
    const next = new Map<string, VersionedLink>();
    for (const value of peers) {
      const peer = object(value);
      const link = observation(peer);
      if (typeof peer.name === "string" && peer.name && link) next.set(peer.name, { link, revision: start });
    }
    for (const [name, entry] of this.links) if (entry.revision > start) next.set(name, entry);
    this.links = next;
    this.snapshotLanded = start;
    this.authoritative = true;
    return true;
  }

  /// The status read started at `start` landed. One older than a status read that already landed
  /// (or than this connection) says nothing new: false, and the caller drops it whole. Otherwise it
  /// is newer than every entry written before it started, so those are dropped and the status read
  /// speaks for them. A failed restart goes restarting -> reconnecting, both `reconnecting` on the
  /// wire, so the daemon sends no note and only a status read says so. A snapshot that started after
  /// it stays the authority.
  statusRead(start: number): boolean {
    if (start <= this.statusLanded) return false;
    this.statusLanded = start;
    for (const [name, entry] of this.links) if (entry.revision < start) this.links.delete(name);
    if (start > this.snapshotLanded) this.authoritative = false;
    return true;
  }

  *entries(): IterableIterator<[string, Link]> {
    for (const [name, entry] of this.links) yield [name, entry.link];
  }
}

function observation(value: Record<string, unknown>): Link | undefined {
  if (!STATES.has(value.state)) return undefined;
  return {
    state: value.state as LinkState,
    connected: value.state === "connected",
    // A full observation clears old nullable values when overlaid on an older status read.
    lastSeen: typeof value.lastSeen === "number" && Number.isFinite(value.lastSeen) ? value.lastSeen : undefined,
    error: typeof value.error === "string" ? value.error : undefined,
  };
}
