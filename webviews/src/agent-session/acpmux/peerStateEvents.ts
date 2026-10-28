const STATES = new Set(["connecting", "connected", "degraded", "reconnecting", "offline"]);
type Link = {
  state: string;
  connected: boolean;
  lastSeen?: number;
  error?: string;
  at?: number;
  revision: number;
};

/// A snapshot plus transitions on one daemon connection. A late snapshot cannot erase a newer event.
export class PeerStateEvents {
  supported = false;
  authoritative = false;
  revision = 0;
  private reads = 0;
  private links = new Map<string, Link>();

  configure(initialized: any): void {
    this.supported =
      Array.isArray(initialized?._meta?.acpmux?.features) &&
      initialized._meta.acpmux.features.includes("peerStateEvents");
    this.authoritative = false;
    this.revision = 0;
    this.links.clear();
    this.reads += 1;
  }

  changed(value: any): boolean {
    if (
      !this.supported ||
      typeof value?.peer !== "string" ||
      !value.peer ||
      !STATES.has(value.state) ||
      typeof value.at !== "number" ||
      !Number.isFinite(value.at)
    )
      return false;
    this.links.set(value.peer, { ...this.link(value), at: value.at, revision: ++this.revision });
    return true;
  }

  readStarted(): number {
    return ++this.reads;
  }

  snapshot(value: any, since: number, read = this.reads): boolean {
    if (read !== this.reads || !Array.isArray(value?.peers)) return false;
    const next = new Map<string, Link>();
    for (const peer of value.peers)
      if (typeof peer?.name === "string" && peer.name && STATES.has(peer.state))
        next.set(peer.name, { ...this.link(peer), revision: since });
    for (const [name, link] of this.links) if (link.revision > since) next.set(name, link);
    this.links = next;
    this.authoritative = true;
    return true;
  }

  entries(): IterableIterator<[string, Link]> {
    return this.links.entries();
  }

  private link(value: any): Omit<Link, "revision"> {
    return {
      state: value.state,
      connected: value.state === "connected",
      ...(typeof value.lastSeen === "number" && Number.isFinite(value.lastSeen) ? { lastSeen: value.lastSeen } : {}),
      ...(typeof value.error === "string" ? { error: value.error } : {}),
    };
  }
}
