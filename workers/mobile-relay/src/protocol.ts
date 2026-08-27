// cmux mobile relay wire protocol — SINGLE SOURCE OF TRUTH.
//
// Everything rides one WebSocket per device. Two frame kinds:
//   - Control: JSON text frames, schema-validated below. The only messages the
//     relay itself understands.
//   - Data: binary frames `[u8 type][u32 BE sessionId][payload]`. The relay
//     reads only the 5-byte header to route; payloads are opaque to it. A
//     client's inbound frames get their sessionId STAMPED by the relay (never
//     trusted from the wire); host frames address the target client session.
//     By endpoint convention the first payload byte is a channel tag (see
//     CHANNEL_*), reserved so raw terminal/simulator channels can be added
//     without a protocol break; v1 uses only CHANNEL_RPC.
//
// Every control message is a FLAT struct of primitives (no nesting). That is
// a deliberate constraint: tools/generate.ts walks the JSON Schema of each
// message and emits Swift Codable types, and flat messages keep that emitter
// small and total. Existing-peer state after `welcome` arrives as individual
// `peer_joined` messages instead of an embedded array for the same reason.
//
// Generated copies (do not edit them, run `bun run generate`):
//   - web/services/mobileRelay/generated/protocol.ts (verbatim copy)
//   - Packages/Shared/CmuxRelayTransport/.../Generated/RelayProtocolGenerated.swift

import * as Schema from "effect/Schema";

export const PROTOCOL_VERSION = 1;

// ---------------------------------------------------------------------------
// Binary data frames
// ---------------------------------------------------------------------------

/** First byte of every binary frame. Anything else is a protocol error. */
export const DATA_FRAME_TYPE = 0x01;
/** [u8 type][u32 BE sessionId] */
export const DATA_HEADER_BYTES = 5;
/** The host's fixed session id. Client sessions are allocated from 1. */
export const HOST_SESSION_ID = 0;
/** Endpoint-convention channel tags (first payload byte). Opaque to the relay. */
export const CHANNEL_RPC = 0;
export const CHANNEL_TERMINAL = 1;
export const CHANNEL_SIMULATOR = 2;
export const CHANNEL_CREDIT = 3;

/** Payload cap per data frame. Endpoints chunk above this; the relay closes
 * on oversized frames. Chosen well under the Workers 1 MiB message limit and
 * equal to the Mac's terminal envelope chunk cap. */
export const MAX_DATA_PAYLOAD_BYTES = 256 * 1024;
export const MAX_DATA_FRAME_BYTES = DATA_HEADER_BYTES + MAX_DATA_PAYLOAD_BYTES;
/** Control frames are small JSON; bound before JSON.parse. */
export const MAX_CONTROL_BYTES = 4096;

// ---------------------------------------------------------------------------
// Session policy
// ---------------------------------------------------------------------------

/** Connected clients per host object. The product shape is one phone, a few
 * at most; this is an abuse bound, not a product limit. */
export const MAX_CLIENTS = 8;
/** How long a session may live past its last accepted ticket (connect or
 * refresh). Endpoints refresh lazily (mint a new ticket and send `refresh`)
 * well before this; a revoked device that stays connected is therefore
 * bounded by this window, on top of the host dropping unpaired devices. */
export const SESSION_MAX_AGE_MS = 12 * 60 * 60 * 1000;
/** Connect-ticket lifetime. Tickets authorize one WebSocket connect (or one
 * in-band refresh); they are not session credentials. */
export const TICKET_TTL_SECONDS = 5 * 60;

/** Hibernation keepalive: clients may send this text frame; the runtime
 * answers without waking the object. */
export const PING_TEXT = "ping";
export const PONG_TEXT = "pong";

/** Production connect URL (the `mr.cmux.dev` custom domain in wrangler.toml).
 * The web ticket route can override per environment via CMUX_MOBILE_RELAY_URL. */
export const DEFAULT_RELAY_URL = "wss://mr.cmux.dev/v1/connect";

export function encodeDataFrame(sessionId: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(DATA_HEADER_BYTES + payload.byteLength);
  out[0] = DATA_FRAME_TYPE;
  new DataView(out.buffer).setUint32(1, sessionId >>> 0, false);
  out.set(payload, DATA_HEADER_BYTES);
  return out;
}

export interface DataFrame {
  readonly sessionId: number;
  readonly payload: Uint8Array;
}

/** Returns null for anything that is not a well-formed, size-bounded data
 * frame. Callers treat null as a protocol violation. */
export function decodeDataFrame(buffer: ArrayBuffer): DataFrame | null {
  if (buffer.byteLength < DATA_HEADER_BYTES) return null;
  if (buffer.byteLength > MAX_DATA_FRAME_BYTES) return null;
  const view = new DataView(buffer);
  if (view.getUint8(0) !== DATA_FRAME_TYPE) return null;
  const sessionId = view.getUint32(1, false);
  return { sessionId, payload: new Uint8Array(buffer, DATA_HEADER_BYTES) };
}

// ---------------------------------------------------------------------------
// Ticket claims
// ---------------------------------------------------------------------------

export const RelayRole = Schema.Literal("host", "client");
export type RelayRole = typeof RelayRole.Type;

/** Claims inside a signed relay ticket (`v1.<b64url claims>.<b64url hmac>`).
 * Minted only by the web app after Stack auth + device-registry ownership
 * checks; verified by the worker (connect) and the object (refresh). */
export const TicketClaims = Schema.Struct({
  userId: Schema.NonEmptyString,
  hostDeviceId: Schema.NonEmptyString,
  deviceId: Schema.NonEmptyString,
  role: RelayRole,
  iat: Schema.Int,
  exp: Schema.Int,
});
export type TicketClaims = typeof TicketClaims.Type;

// ---------------------------------------------------------------------------
// Control messages (JSON text frames)
// ---------------------------------------------------------------------------

/** client -> relay: extend the session deadline with a fresh ticket. The
 * ticket must carry the exact identity the socket connected with. */
export const RefreshMessage = Schema.Struct({
  t: Schema.Literal("refresh"),
  ticket: Schema.NonEmptyString,
});
export type RefreshMessage = typeof RefreshMessage.Type;

/** host -> relay: close one client session (auth failure, quota, teardown).
 * The relay closes that client's socket with `bye(host_closed)`. Ignored from
 * client sockets. */
export const CloseSessionMessage = Schema.Struct({
  t: Schema.Literal("close_session"),
  sessionId: Schema.Int,
});
export type CloseSessionMessage = typeof CloseSessionMessage.Type;

export const ClientControlMessage = Schema.Union(RefreshMessage, CloseSessionMessage);
export type ClientControlMessage = typeof ClientControlMessage.Type;

/** relay -> endpoint: first message on every accepted socket. */
export const WelcomeMessage = Schema.Struct({
  t: Schema.Literal("welcome"),
  v: Schema.Int,
  role: RelayRole,
  sessionId: Schema.Int,
  /** Epoch ms after which the relay closes this socket unless refreshed. */
  deadline: Schema.Number,
  /** For clients: whether the host is currently connected. Hosts get true. */
  hostPresent: Schema.Boolean,
});
export type WelcomeMessage = typeof WelcomeMessage.Type;

/** relay -> host: a client session joined (also replayed for each existing
 * client right after a host `welcome`). relay -> client: sessionId 0 means
 * the host joined. */
export const PeerJoinedMessage = Schema.Struct({
  t: Schema.Literal("peer_joined"),
  sessionId: Schema.Int,
  deviceId: Schema.NonEmptyString,
});
export type PeerJoinedMessage = typeof PeerJoinedMessage.Type;

export const PeerLeftMessage = Schema.Struct({
  t: Schema.Literal("peer_left"),
  sessionId: Schema.Int,
  reason: Schema.String,
});
export type PeerLeftMessage = typeof PeerLeftMessage.Type;

export const RefreshAckMessage = Schema.Struct({
  t: Schema.Literal("refresh_ack"),
  deadline: Schema.Number,
});
export type RefreshAckMessage = typeof RefreshAckMessage.Type;

/** relay -> endpoint: terminal close reason, sent immediately before close. */
export const ByeMessage = Schema.Struct({
  t: Schema.Literal("bye"),
  code: Schema.NonEmptyString,
  reason: Schema.String,
});
export type ByeMessage = typeof ByeMessage.Type;

export const ServerControlMessage = Schema.Union(
  WelcomeMessage,
  PeerJoinedMessage,
  PeerLeftMessage,
  RefreshAckMessage,
  ByeMessage,
);
export type ServerControlMessage = typeof ServerControlMessage.Type;

/** Close codes carried in `bye`. */
export const BYE_SUPERSEDED = "superseded";
export const BYE_EXPIRED = "expired";
export const BYE_PROTOCOL_ERROR = "protocol_error";
export const BYE_AT_CAPACITY = "at_capacity";
export const BYE_HOST_CLOSED = "host_closed";

// Strict decoding: unknown fields are protocol errors on this security
// surface, matching the `additionalProperties: false` the schemas advertise.
const STRICT = { onExcessProperty: "error" } as const;
export const decodeClientControl = Schema.decodeUnknownEither(ClientControlMessage, STRICT);
export const decodeServerControl = Schema.decodeUnknownEither(ServerControlMessage, STRICT);
export const decodeTicketClaims = Schema.decodeUnknownEither(TicketClaims, STRICT);
