import type { PeerLinkState } from "./protocol/generated/types";

const STATES = new Set<unknown>(["connecting", "connected", "degraded", "reconnecting", "offline"]);
type Link = { state: PeerLinkState; connected: boolean; lastSeen: number | undefined; error: string | undefined };
type VersionedLink = { link: Link; revision: number };
const object = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {};
const same = (a: Link | undefined, b: Link) => a?.state === b.state && a.lastSeen === b.lastSeen && a.error === b.error;

/// One local/app connection's snapshot and pushed state. The daemon names both proven origins
/// `local`; a peer daemon's connection never hears this host's peer inventory (#26860).
export class PeerStateEvents {
  supported = false;
  authoritative = false;
  revision = 0;
  private reads = 0;
  private links = new Map<string, VersionedLink>();

  configure(initialized: unknown): void {
    const acpmux = object(object(object(initialized)._meta).acpmux);
    this.supported =
      acpmux.origin === "local" && Array.isArray(acpmux.features) && acpmux.features.includes("peerStateEvents");
    this.authoritative = false;
    this.revision = 0;
    this.links.clear();
    this.reads += 1;
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
    this.links.set(note.peer, { link, revision: ++this.revision });
    return !same(previous, link);
  }

  readStarted(): number {
    return ++this.reads;
  }

  snapshot(value: unknown, since: number, read = this.reads): boolean {
    const peers = object(value).peers;
    if (!this.supported || read !== this.reads || !Array.isArray(peers)) return false;
    const next = new Map<string, VersionedLink>();
    for (const value of peers) {
      const peer = object(value);
      const link = observation(peer);
      if (typeof peer.name === "string" && peer.name && link) next.set(peer.name, { link, revision: since });
    }
    for (const [name, entry] of this.links) if (entry.revision > since) next.set(name, entry);
    this.links = next;
    this.authoritative = true;
    return true;
  }

  *entries(): IterableIterator<[string, Link]> {
    for (const [name, entry] of this.links) yield [name, entry.link];
  }
}

function observation(value: Record<string, unknown>): Link | undefined {
  if (!STATES.has(value.state)) return undefined;
  return {
    state: value.state as PeerLinkState,
    connected: value.state === "connected",
    // A full observation clears old nullable values when overlaid on an older status read.
    lastSeen: typeof value.lastSeen === "number" && Number.isFinite(value.lastSeen) ? value.lastSeen : undefined,
    error: typeof value.error === "string" ? value.error : undefined,
  };
}
