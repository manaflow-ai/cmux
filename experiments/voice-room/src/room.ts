// Who is in the room and what the server relays between them. Media never passes through the
// server: browsers connect to each other with WebRTC over the tailnet (each peer's 100.x address
// is a direct host candidate, so no STUN or TURN), and the server only forwards their offers,
// answers and ICE candidates.

export interface Peer {
  id: string;
  /** Tailnet login when the server could look it up, else the name the page sent. */
  name: string;
  /** The device the peer joined from (`tailscale whois`), when known. */
  device: string;
  joinedAt: number;
  muted: boolean;
  camera: boolean;
  sharing: boolean;
}

export type ClientMessage =
  | { t: "signal"; to: string; data: unknown }
  | { t: "state"; muted?: boolean; camera?: boolean; sharing?: boolean }
  | { t: "speech"; text: string; level?: number }
  | { t: "pause"; on: boolean }
  | { t: "task.send"; id: number }
  | { t: "task.dismiss"; id: number };

export function parseClientMessage(raw: string): ClientMessage | null {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object") return null;
  const message = value as Record<string, unknown>;
  switch (message.t) {
    case "signal":
      return typeof message.to === "string" ? { t: "signal", to: message.to, data: message.data } : null;
    case "state":
      return {
        t: "state",
        muted: typeof message.muted === "boolean" ? message.muted : undefined,
        camera: typeof message.camera === "boolean" ? message.camera : undefined,
        sharing: typeof message.sharing === "boolean" ? message.sharing : undefined,
      };
    case "speech":
      return typeof message.text === "string" && message.text.trim()
        ? { t: "speech", text: message.text.slice(0, 4000), level: typeof message.level === "number" ? message.level : 0 }
        : null;
    case "pause":
      return typeof message.on === "boolean" ? { t: "pause", on: message.on } : null;
    case "task.send":
    case "task.dismiss":
      return typeof message.id === "number" ? { t: message.t, id: message.id } : null;
    default:
      return null;
  }
}

export class Roster {
  private readonly peers = new Map<string, Peer>();
  private counter = 0;

  join(name: string, device: string, at = Date.now()): Peer {
    this.counter += 1;
    const peer: Peer = { id: `p${this.counter}`, name, device, joinedAt: at, muted: false, camera: true, sharing: false };
    this.peers.set(peer.id, peer);
    return peer;
  }

  leave(id: string): Peer | undefined {
    const peer = this.peers.get(id);
    this.peers.delete(id);
    return peer;
  }

  get(id: string): Peer | undefined {
    return this.peers.get(id);
  }

  update(id: string, state: Extract<ClientMessage, { t: "state" }>): void {
    const peer = this.peers.get(id);
    if (!peer) return;
    if (state.muted !== undefined) peer.muted = state.muted;
    if (state.camera !== undefined) peer.camera = state.camera;
    if (state.sharing !== undefined) peer.sharing = state.sharing;
  }

  list(): Peer[] {
    return [...this.peers.values()];
  }

  /** A signal goes only to a peer in this room, never back to its sender. */
  relayTarget(from: string, to: string): Peer | undefined {
    if (from === to || !this.peers.has(from)) return undefined;
    return this.peers.get(to);
  }
}

/** Tailnet (100.64.0.0/10, fd7a:115c:a1e0::/48) or loopback: the only addresses the room answers. */
export function isAllowedAddress(address: string): boolean {
  const ip = address.replace(/^::ffff:/, "");
  if (ip === "127.0.0.1" || ip === "::1") return true;
  if (ip.toLowerCase().startsWith("fd7a:115c:a1e0:")) return true;
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) return false;
  return parts[0] === 100 && parts[1]! >= 64 && parts[1]! <= 127;
}

export function isLoopback(address: string): boolean {
  const ip = address.replace(/^::ffff:/, "");
  return ip === "127.0.0.1" || ip === "::1";
}
