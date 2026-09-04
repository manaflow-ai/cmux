// Mobile pairing relay — pure core (no Workers APIs, bun-testable).
//
// One MobilePairingRelay Durable Object per Mac device id relays opaque
// binary frames between exactly two WebSocket legs: the Mac ("host", dialing
// out from MobileHostCloudflareRelayRuntime) and the paired phone/Android app
// ("client", dialing out from the mobile app's WebSocketByteTransport). Each
// binary message is exactly one already `MobileSyncFrameCodec`-framed cmux
// RPC/event payload — this DO never parses cmux content, so the RPC protocol
// on both ends is completely unaware the transport changed.
//
// The thin Durable Object adapter (WebSocket hibernation, attachment
// serialization) lives in mobilePairingRelayDo.ts.

export type MprRole = "host" | "client";

export interface MprAttachment {
  role: MprRole;
  /** Verified Stack user id, forwarded by the worker — never client input. */
  accountId: string;
}

export interface MprSocket {
  send(data: string | ArrayBuffer): void;
  close(code?: number, reason?: string): void;
  getAttachment(): MprAttachment | null;
  setAttachment(attachment: MprAttachment): void;
}

/** Mirrors MobileSyncFrameCodec's 8 MiB max frame, plus slack for the
 * WebSocket/TLS framing overhead around the same payload. Bounded before any
 * processing: client-controlled input on a live DO. */
export const MAX_RELAY_FRAME_BYTES = 8 * 1024 * 1024 + 4_096;

export interface MprConnectDecision {
  ok: boolean;
  /** Existing same-role sockets to close once the new one is accepted — at
   * most one active leg per role, so a reconnect replaces the old socket
   * instead of stacking silently alongside it. */
  toEvict: MprSocket[];
}

/** Decide whether a connecting socket may join this Mac device id's relay.
 *
 * Rejects when the opposite role is already present under a DIFFERENT
 * verified account (account matching, not just per-leg auth — mirrors the
 * Mac-side check in MobileHostStackAuthVerifier that a phone's Stack account
 * must match the signed-in Mac account). Otherwise accepts and marks any
 * existing socket of the SAME role for eviction. Pure: takes the current
 * socket list rather than reading it itself, so it is bun-testable without a
 * DO. */
export function decideConnect(
  sockets: readonly MprSocket[],
  role: MprRole,
  accountId: string,
): MprConnectDecision {
  const peerRole: MprRole = role === "host" ? "client" : "host";
  const toEvict: MprSocket[] = [];
  for (const socket of sockets) {
    const attachment = socket.getAttachment();
    if (!attachment) continue;
    if (attachment.role === peerRole && attachment.accountId !== accountId) {
      return { ok: false, toEvict: [] };
    }
    if (attachment.role === role) {
      toEvict.push(socket);
    }
  }
  return { ok: true, toEvict };
}

function isPingFrame(message: string): boolean {
  try {
    const parsed = JSON.parse(message) as { type?: unknown };
    return parsed.type === "ping";
  } catch {
    return false;
  }
}

/** Handle one inbound WebSocket message from `sender`.
 *
 * Binary messages are the pairing wire protocol: forwarded verbatim to the
 * one connected socket with the opposite role and the same account id, or
 * silently dropped when no such peer is connected yet — this is a best-effort
 * passthrough with no buffering; the RPC layer above it already retries and
 * reconnects, the same way it already tolerates a dropped TCP connection.
 * Text messages are transport-liveness heartbeats only (mirrors the `ping`
 * convention already used by the presence/control-plane DOs in this worker)
 * and are never forwarded. */
export function forwardMessage(
  sockets: readonly MprSocket[],
  sender: MprSocket,
  message: string | ArrayBuffer,
): void {
  const attachment = sender.getAttachment();
  if (!attachment) return;
  if (typeof message === "string") {
    if (isPingFrame(message)) {
      try {
        sender.send(JSON.stringify({ type: "pong" }));
      } catch {
        // the peer went away between receive and reply
      }
    }
    return;
  }
  if (message.byteLength > MAX_RELAY_FRAME_BYTES) {
    try {
      sender.close(1009, "frame too large");
    } catch {
      // already closed
    }
    return;
  }
  const peerRole: MprRole = attachment.role === "host" ? "client" : "host";
  const peer = sockets.find((candidate) => {
    if (candidate === sender) return false;
    const peerAttachment = candidate.getAttachment();
    return peerAttachment !== null
      && peerAttachment.role === peerRole
      && peerAttachment.accountId === attachment.accountId;
  });
  if (!peer) return;
  try {
    peer.send(message);
  } catch {
    // the peer went away between lookup and send
  }
}

/** Path-segment-safe Mac device id: the Durable Object name and a URL path
 * component, so this is deliberately stricter than the general free-text
 * device ids elsewhere in the pairing system. */
export function isValidMacDeviceId(value: string): boolean {
  return value.length > 0 && value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value);
}
