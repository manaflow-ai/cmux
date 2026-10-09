/** Signaling frames per PROTOCOL.md §5. Pure helpers, no runtime state. */

export type Role = "phone" | "host";

export interface PeerInfo {
  peerId: string;
  role: Role;
  hostId?: string;
  userId: string;
  /** Phones: access-token expiry (ms). The socket is closed with 4002 at this time. */
  expiresAt?: number;
  /** Phones: refresh-token family of the access token (JWT `fam`). */
  family?: string;
}

export type RelayType = "offer" | "answer" | "candidate" | "bye";

export interface RelayFrame {
  type: RelayType;
  to: string;
  sessionId: string;
  [key: string]: unknown;
}

export interface ErrorFrame {
  type: "error";
  code: string;
  message: string;
  sessionId?: string;
}

export const MAX_FRAME_BYTES = 64 * 1024;

const RELAY_TYPES: RelayType[] = ["offer", "answer", "candidate", "bye"];

export function errorFrame(code: string, message: string, sessionId?: string): ErrorFrame {
  return sessionId ? { type: "error", code, message, sessionId } : { type: "error", code, message };
}

/** Validates an incoming frame. Returns the frame or an error frame to send back. */
export function parseRelayFrame(raw: string | ArrayBuffer): RelayFrame | ErrorFrame {
  if (typeof raw !== "string") return errorFrame("bad_request", "frames must be JSON text");
  if (raw.length > MAX_FRAME_BYTES) return errorFrame("bad_request", "frame too large");
  let msg: unknown;
  try {
    msg = JSON.parse(raw);
  } catch {
    return errorFrame("bad_request", "invalid JSON");
  }
  if (!msg || typeof msg !== "object" || Array.isArray(msg)) return errorFrame("bad_request", "frame must be an object");
  const m = msg as Record<string, unknown>;
  const sessionId = typeof m.sessionId === "string" ? m.sessionId : undefined;
  if (!RELAY_TYPES.includes(m.type as RelayType)) return errorFrame("bad_request", `unknown type ${String(m.type)}`, sessionId);
  if (typeof m.to !== "string" || !m.to) return errorFrame("bad_request", "to is required", sessionId);
  if (!sessionId) return errorFrame("bad_request", "sessionId is required");
  if ((m.type === "offer" || m.type === "answer") && typeof m.sdp !== "string") return errorFrame("bad_request", "sdp is required", sessionId);
  if (m.type === "candidate" && typeof m.candidate !== "string") return errorFrame("bad_request", "candidate is required", sessionId);
  return m as RelayFrame;
}

/** The address other peers use for `sender`: hostId for hosts, peerId for phones. */
export function addressOf(peer: PeerInfo): string {
  return peer.role === "host" && peer.hostId ? peer.hostId : peer.peerId;
}

/**
 * Direction rules: phones offer to hosts, hosts answer phones; candidates
 * and byes go either way between a phone and a host.
 */
export function directionError(sender: PeerInfo, frame: RelayFrame): ErrorFrame | null {
  if (frame.type === "offer" && sender.role !== "phone") return errorFrame("forbidden", "only phones send offers", frame.sessionId);
  if (frame.type === "answer" && sender.role !== "host") return errorFrame("forbidden", "only hosts send answers", frame.sessionId);
  return null;
}

/** Target role for a frame from `sender`. */
export function targetRole(sender: PeerInfo): Role {
  return sender.role === "phone" ? "host" : "phone";
}
