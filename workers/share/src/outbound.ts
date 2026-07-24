// SPDX-License-Identifier: GPL-3.0-or-later
// Acknowledged, hibernation-safe outbound delivery for ShareSession sockets.

import {
  isAckNonce,
  isIdentityEmail,
  isProtocolId,
  MAX_BINARY_FRAME_BYTES,
  MAX_SERVER_JSON_FRAME_BYTES,
  utf8ByteLength,
} from "./protocol";
import type { Effect, PersistedSession, ShareSessionCore } from "./session";

/** A socket may have at most this many unacknowledged logical payloads. */
export const MAX_SOCKET_OUTSTANDING_ENTRIES = 128;
/** A UUID collision is extraordinarily unlikely, but attachment restore
 * requires unique entries, so retry a bounded number before failing closed. */
export const MAX_NONCE_GENERATION_ATTEMPTS = 4;
/** The boundary is inclusive: prospective credit at 2 MiB is rejected. */
export const MAX_SOCKET_OUTSTANDING_BYTES = 2 * 1024 * 1024;
/** Compatibility name retained for downstream imports. */
export const MAX_SOCKET_BUFFERED_BYTES = MAX_SOCKET_OUTSTANDING_BYTES;
/** A server-to-client WebSocket frame has at most ten bytes of RFC 6455
 * framing. Every logical delivery consists of a payload frame and a following
 * ACK-request frame, so both receive this conservative allowance. */
export const WEBSOCKET_FRAME_ALLOWANCE_BYTES = 10;

export const SLOW_CLIENT_CLOSE_CODE = 4008;
export const SLOW_CLIENT_CLOSE_REASON = "slow_client";
export const DELIVERY_FAILURE_CLOSE_CODE = 1011;
export const DELIVERY_FAILURE_CLOSE_REASON = "delivery_failed";
export const SERVER_MESSAGE_TOO_LARGE_CLOSE_CODE = 1011;
export const SERVER_MESSAGE_TOO_LARGE_CLOSE_REASON = "server_message_too_large";

export interface DeliveryCreditEntry {
  nonce: string;
  bytes: number;
}

/** In-memory form. serializeSocketAttachment() emits compact keys and tuples
 * so the 128-entry worst case remains well under Cloudflare's 16 KiB
 * attachment ceiling. */
export interface ShareSocketAttachment {
  connId: string;
  user: string;
  email: string;
  host: boolean;
  outstanding: DeliveryCreditEntry[];
}

interface SerializedSocketAttachment {
  /** Format version. */
  v: 1;
  /** Connection id, user, email, host bit, outstanding [nonce, bytes] tuples. */
  i: string;
  u: string;
  e: string;
  h: boolean;
  w: Array<[string, number]>;
}

type UnknownRecord = Record<string, unknown>;

function record(value: unknown): UnknownRecord | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as UnknownRecord)
    : null;
}

function parseOutstanding(value: unknown): DeliveryCreditEntry[] | null {
  if (!Array.isArray(value) || value.length > MAX_SOCKET_OUTSTANDING_ENTRIES) return null;
  const entries: DeliveryCreditEntry[] = [];
  const seen = new Set<string>();
  let total = 0;
  for (const raw of value) {
    if (
      !Array.isArray(raw) ||
      raw.length !== 2 ||
      !isAckNonce(raw[0]) ||
      !Number.isSafeInteger(raw[1]) ||
      (raw[1] as number) <= 0 ||
      (raw[1] as number) >= MAX_SOCKET_OUTSTANDING_BYTES ||
      seen.has(raw[0])
    ) {
      return null;
    }
    total += raw[1] as number;
    if (!Number.isSafeInteger(total) || total >= MAX_SOCKET_OUTSTANDING_BYTES) return null;
    seen.add(raw[0]);
    entries.push({ nonce: raw[0], bytes: raw[1] as number });
  }
  return entries;
}

export function createSocketAttachment(identity: {
  connId: string;
  user: string;
  email: string;
  host: boolean;
}): ShareSocketAttachment {
  return { ...identity, outstanding: [] };
}

/** Validate and defensively clone attachment state after hibernation. The
 * long-key branch upgrades sockets created by the pre-credit worker. */
export function parseSocketAttachment(value: unknown): ShareSocketAttachment | null {
  const obj = record(value);
  if (!obj) return null;

  const compact = obj.v === 1;
  const connId = compact ? obj.i : obj.connId;
  const user = compact ? obj.u : obj.user;
  const email = compact ? obj.e : obj.email;
  const host = compact ? obj.h : obj.host;
  const outstanding = compact ? parseOutstanding(obj.w) : [];
  if (
    !isProtocolId(connId) ||
    !isProtocolId(user) ||
    !isIdentityEmail(email) ||
    typeof host !== "boolean" ||
    outstanding === null
  ) {
    return null;
  }
  return { connId, user, email, host, outstanding };
}

export function serializeSocketAttachment(
  attachment: ShareSocketAttachment,
): SerializedSocketAttachment {
  return {
    v: 1,
    i: attachment.connId,
    u: attachment.user,
    e: attachment.email,
    h: attachment.host,
    w: attachment.outstanding.map(({ nonce, bytes }) => [nonce, bytes]),
  };
}

export function outstandingDeliveryBytes(attachment: ShareSocketAttachment): number {
  let total = 0;
  for (const entry of attachment.outstanding) total += entry.bytes;
  return total;
}

export function ackRequestPayload(nonce: string): string {
  return JSON.stringify({ t: "ack-request", nonce });
}

/** Exact conservative reservation: application payload UTF-8/binary bytes,
 * exact ACK-request UTF-8 bytes, and worst-case framing for the two frames. */
export function deliveryCreditBytes(payloadBytes: number, nonce: string): number {
  if (!Number.isSafeInteger(payloadBytes) || payloadBytes < 0 || !isAckNonce(nonce)) {
    return Number.POSITIVE_INFINITY;
  }
  return (
    payloadBytes +
    utf8ByteLength(ackRequestPayload(nonce)) +
    2 * WEBSOCKET_FRAME_ALLOWANCE_BYTES
  );
}

export function canReserveDeliveryCredit(
  attachment: ShareSocketAttachment,
  bytes: number,
): boolean {
  if (!Number.isSafeInteger(bytes) || bytes <= 0) return false;
  if (attachment.outstanding.length + 1 > MAX_SOCKET_OUTSTANDING_ENTRIES) return false;
  const total = outstandingDeliveryBytes(attachment);
  return (
    Number.isSafeInteger(total) &&
    total >= 0 &&
    total < MAX_SOCKET_OUTSTANDING_BYTES &&
    bytes < MAX_SOCKET_OUTSTANDING_BYTES &&
    total < MAX_SOCKET_OUTSTANDING_BYTES - bytes
  );
}

export interface OutboundSocket {
  serializeAttachment(value: unknown): void;
  send(data: string | ArrayBuffer | ArrayBufferView): void;
  close(code?: number, reason?: string): void;
}

export interface OutboundEffectRuntime<TSocket extends OutboundSocket> {
  core: ShareSessionCore | null;
  sockets: Map<string, TSocket>;
  attachments: Map<string, ShareSocketAttachment>;
  now(): number;
  randomUUID(): string;
  persist(session: PersistedSession): Promise<void>;
  setAlarm(at: number): Promise<void>;
  clearAlarm(): Promise<void>;
  deleteAllStorage(): Promise<void>;
  removeSocketState(id: string): void;
  /** Details must contain only invariant metadata, never payloads or identity. */
  logInvariant(event: string, details: Readonly<Record<string, number | string>>): void;
}

export type AckReleaseResult = "released" | "ignored" | "serialization-failed";

/** Release only an exact nonce in this socket's own persisted window. Unknown,
 * duplicate, replayed, and cross-socket nonces mutate and free nothing. */
export function releaseDeliveryCredit<TSocket extends OutboundSocket>(
  socket: TSocket,
  attachment: ShareSocketAttachment,
  nonce: string,
): AckReleaseResult {
  const index = attachment.outstanding.findIndex((entry) => entry.nonce === nonce);
  if (index < 0) return "ignored";
  const nextOutstanding = attachment.outstanding.filter((_, i) => i !== index);
  const next = { ...attachment, outstanding: nextOutstanding };
  try {
    socket.serializeAttachment(serializeSocketAttachment(next));
  } catch {
    return "serialization-failed";
  }
  attachment.outstanding = nextOutstanding;
  return "released";
}

interface EncodedPayload {
  data: string | Uint8Array;
  bytes: number;
}

function encodeEffectPayload(
  effect: Extract<Effect, { kind: "send" | "sendBinary" }>,
): { payload: EncodedPayload | null; event?: string; bytes?: number } {
  if (effect.kind === "sendBinary") {
    if (effect.data.byteLength >= MAX_BINARY_FRAME_BYTES) {
      return {
        payload: null,
        event: "server_binary_too_large",
        bytes: effect.data.byteLength,
      };
    }
    return { payload: { data: effect.data, bytes: effect.data.byteLength } };
  }
  try {
    const data = JSON.stringify(effect.msg);
    const bytes = utf8ByteLength(data);
    if (bytes >= MAX_SERVER_JSON_FRAME_BYTES) {
      return { payload: null, event: "server_json_too_large", bytes };
    }
    return { payload: { data, bytes } };
  } catch {
    return { payload: null, event: "server_json_encode_failed" };
  }
}

function closeSocket<TSocket extends OutboundSocket>(
  runtime: OutboundEffectRuntime<TSocket>,
  id: string,
  code: number,
  reason: string,
): boolean {
  const socket = runtime.sockets.get(id);
  if (!socket) return false;
  runtime.sockets.delete(id);
  runtime.attachments.delete(id);
  runtime.removeSocketState(id);
  try {
    socket.close(code, reason);
  } catch {
    // Already closed.
  }
  return true;
}

function appendDisconnectEffects<TSocket extends OutboundSocket>(
  queue: Effect[],
  runtime: OutboundEffectRuntime<TSocket>,
  id: string,
): void {
  if (runtime.core) queue.push(...runtime.core.disconnect(id, runtime.now()));
}

function failDelivery<TSocket extends OutboundSocket>(
  queue: Effect[],
  runtime: OutboundEffectRuntime<TSocket>,
  id: string,
  code: number,
  reason: string,
  event: string,
  details: Readonly<Record<string, number | string>> = {},
): void {
  runtime.logInvariant(event, details);
  if (closeSocket(runtime, id, code, reason)) appendDisconnectEffects(queue, runtime, id);
}

/** Execute core effects in one queue. Each payload is reserved in the
 * serialized attachment before either frame is sent. Payload is always first,
 * then its ACK request. Any failure closes only that socket and appends the
 * core disconnect effects, allowing healthy fan-out to continue. */
export async function dispatchEffects<TSocket extends OutboundSocket>(
  initialEffects: readonly Effect[],
  runtime: OutboundEffectRuntime<TSocket>,
): Promise<void> {
  const queue = [...initialEffects];
  for (let index = 0; index < queue.length; index += 1) {
    const effect = queue[index];
    if (!effect) continue;
    switch (effect.kind) {
      case "send":
      case "sendBinary": {
        const socket = runtime.sockets.get(effect.to);
        const attachment = runtime.attachments.get(effect.to);
        if (!socket || !attachment) break;

        const encoded = encodeEffectPayload(effect);
        if (!encoded.payload) {
          failDelivery(
            queue,
            runtime,
            effect.to,
            SERVER_MESSAGE_TOO_LARGE_CLOSE_CODE,
            SERVER_MESSAGE_TOO_LARGE_CLOSE_REASON,
            encoded.event ?? "server_json_encode_failed",
            encoded.bytes === undefined ? {} : { bytes: encoded.bytes },
          );
          break;
        }

        let nonce: string | null = null;
        let nonceGenerationFailed = false;
        for (let attempt = 0; attempt < MAX_NONCE_GENERATION_ATTEMPTS; attempt += 1) {
          let candidate: string;
          try {
            candidate = runtime.randomUUID();
          } catch {
            nonceGenerationFailed = true;
            break;
          }
          if (!isAckNonce(candidate)) {
            nonceGenerationFailed = true;
            break;
          }
          if (!attachment.outstanding.some((entry) => entry.nonce === candidate)) {
            nonce = candidate;
            break;
          }
        }
        if (nonceGenerationFailed) {
          failDelivery(
            queue,
            runtime,
            effect.to,
            DELIVERY_FAILURE_CLOSE_CODE,
            DELIVERY_FAILURE_CLOSE_REASON,
            "delivery_nonce_failed",
          );
          break;
        }
        if (nonce === null) {
          failDelivery(
            queue,
            runtime,
            effect.to,
            DELIVERY_FAILURE_CLOSE_CODE,
            DELIVERY_FAILURE_CLOSE_REASON,
            "delivery_nonce_collision",
          );
          break;
        }
        const ackPayload = ackRequestPayload(nonce);
        const reservedBytes = deliveryCreditBytes(encoded.payload.bytes, nonce);
        if (!canReserveDeliveryCredit(attachment, reservedBytes)) {
          failDelivery(
            queue,
            runtime,
            effect.to,
            SLOW_CLIENT_CLOSE_CODE,
            SLOW_CLIENT_CLOSE_REASON,
            "delivery_credit_exhausted",
            {
              entries: attachment.outstanding.length,
              outstandingBytes: outstandingDeliveryBytes(attachment),
              prospectiveBytes: reservedBytes,
            },
          );
          break;
        }

        const nextOutstanding = [
          ...attachment.outstanding,
          { nonce, bytes: reservedBytes },
        ];
        const next = { ...attachment, outstanding: nextOutstanding };
        try {
          socket.serializeAttachment(serializeSocketAttachment(next));
        } catch {
          failDelivery(
            queue,
            runtime,
            effect.to,
            DELIVERY_FAILURE_CLOSE_CODE,
            DELIVERY_FAILURE_CLOSE_REASON,
            "delivery_attachment_serialize_failed",
          );
          break;
        }
        attachment.outstanding = nextOutstanding;

        try {
          socket.send(encoded.payload.data);
        } catch {
          failDelivery(
            queue,
            runtime,
            effect.to,
            DELIVERY_FAILURE_CLOSE_CODE,
            DELIVERY_FAILURE_CLOSE_REASON,
            "delivery_payload_send_failed",
          );
          break;
        }
        try {
          socket.send(ackPayload);
        } catch {
          failDelivery(
            queue,
            runtime,
            effect.to,
            DELIVERY_FAILURE_CLOSE_CODE,
            DELIVERY_FAILURE_CLOSE_REASON,
            "delivery_ack_request_send_failed",
          );
        }
        break;
      }
      case "close":
        if (closeSocket(runtime, effect.to, effect.code, effect.reason)) {
          appendDisconnectEffects(queue, runtime, effect.to);
        }
        break;
      case "setAlarm":
        await runtime.setAlarm(effect.at);
        break;
      case "clearAlarm":
        await runtime.clearAlarm();
        break;
      case "deleteAllStorage":
        await runtime.deleteAllStorage();
        break;
      case "persist":
        if (runtime.core) await runtime.persist(runtime.core.persisted);
        break;
    }
  }
}
