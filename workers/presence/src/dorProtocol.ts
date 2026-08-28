// dor/1 — pure protocol helpers for the AccountRelay Durable Object.
//
// ONE AccountRelay instance per Stack user (`dor:user:<uid>`), named by the
// worker AFTER edge auth: every Mac the account owns parks a standing "host"
// WebSocket leg on the same object, and every phone opens a "phone" leg bound
// to exactly one of those Macs. All Mac↔phone traffic for the account flows
// through this single object. Binary frames carry a fixed 14-byte routing
// header the relay reads (and rewrites for phone uploads); the payload is
// opaque end-to-end ciphertext.
//
// Reliability: each directed stream (mac→phone, phone→mac) is sender
// sequenced. The relay keeps a bounded replay ring per stream, prunes it on
// receiver acks, and replays the exact gap when a leg redials with its resume
// key — but only when coverage is provable (`ReplayRing.coversGap`); anything
// else fails the resume so the E2E session layer re-handshakes instead of
// silently skipping frames.

export const DOR_PROTOCOL = "dor/1";

/** Binary data frame header: [u8 version][u8 kind][u32be legId][u64be seq]. */
export const DATA_HEADER_BYTES = 14;
export const DATA_FRAME_VERSION = 1;
export const DATA_KIND_DATA = 1;

/** Control frames are small JSON. */
export const MAX_CONTROL_BYTES = 4 * 1024;
/** Cloudflare caps inbound WebSocket messages at 1 MiB; refuse anything close. */
export const MAX_DATA_FRAME_BYTES = 1024 * 1024 - 1024;

/** Replay ring caps per directed stream (frames / bytes). Overflow marks the
 * ring broken: the next resume that needs evicted frames fails instead of
 * silently gapping. */
export const RING_MAX_FRAMES = 256;
export const RING_MAX_BYTES = 2 * 1024 * 1024;

/** A leg that never completes hello gets closed. */
export const HELLO_TIMEOUT_MS = 15_000;
/** Auth deadline cap per verification (token exp capped at 15 min); legs
 * extend in-band with `auth.refresh` instead of reconnecting. */
export const DOR_MAX_SUBSCRIBE_AGE_MS = 15 * 60 * 1000;
/** Grace past the auth deadline before the alarm closes a leg. */
export const AUTH_GRACE_MS = 60_000;
/** Phone legs per account object (a couple phones × a few Macs). */
export const MAX_PHONE_LEGS = 32;
/** Host legs per account object (one per Mac). */
export const MAX_HOST_LEGS = 16;

// Close codes (4xxx application range).
export const CLOSE_UNAUTHORIZED = 4401;
export const CLOSE_PROTOCOL_ERROR = 4400;
export const CLOSE_SUPERSEDED = 4409;
export const CLOSE_CAPACITY = 4429;

export interface DataFrameHeader {
  version: number;
  kind: number;
  legId: number;
  seq: number;
}

/** Parse and validate a binary data frame header. Null when malformed or
 * oversized (callers close the leg with a protocol error). */
export function decodeDataHeader(frame: ArrayBuffer): DataFrameHeader | null {
  if (frame.byteLength < DATA_HEADER_BYTES || frame.byteLength > MAX_DATA_FRAME_BYTES) return null;
  const view = new DataView(frame);
  const version = view.getUint8(0);
  if (version !== DATA_FRAME_VERSION) return null;
  const kind = view.getUint8(1);
  if (kind !== DATA_KIND_DATA) return null;
  const legId = view.getUint32(2);
  const seq = Number(view.getBigUint64(6));
  if (!Number.isSafeInteger(seq) || seq < 1) return null;
  return { version, kind, legId, seq };
}

/** Rewrite the legId field in place (phone uploads get stamped with the
 * phone's own leg id before forwarding to the Mac). */
export function rewriteLegId(frame: ArrayBuffer, legId: number): void {
  new DataView(frame).setUint32(2, legId);
}

export type ControlFrame =
  // hello: `ack` is a phone's last-received download seq; `acks` is a Mac's
  // per-source map keyed by phone leg id (a Mac downloads one sequenced
  // stream per phone leg bound to it).
  | { t: "hello"; proto: string; device: string; resume?: string; ack?: number; acks?: Record<string, number> }
  | { t: "hello.ack"; legId: number; resumeKey: string; epoch: string; peerOnline: boolean; replayed: number }
  | { t: "resume.failed"; reason: string }
  | { t: "ping"; ts: number }
  | { t: "pong"; ts: number }
  | { t: "auth.refresh"; token: string }
  | { t: "auth.ok"; deadline: number }
  | { t: "ack"; seq: number; leg?: number }
  // relay→uploader: "your upload is ring-durable through seq" — prunes the
  // client's resend buffer. For Mac uploads, `leg` names the destination.
  | { t: "ackup"; seq: number; leg?: number }
  | { t: "peer.online"; legId?: number; device?: string }
  | { t: "peer.offline"; legId?: number; reason?: string }
  | { t: "error"; code: string; message: string };

/** Parse an inbound control frame. Only client→relay types are accepted;
 * unknown or oversized input returns null (protocol error). */
export function decodeControl(text: string): ControlFrame | null {
  if (text.length > MAX_CONTROL_BYTES) return null;
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null) return null;
  const frame = value as Record<string, unknown>;
  switch (frame.t) {
    case "hello": {
      if (typeof frame.proto !== "string" || typeof frame.device !== "string") return null;
      if (!frame.device || frame.device.length > 128) return null;
      if (frame.resume !== undefined && typeof frame.resume !== "string") return null;
      if (frame.ack !== undefined && !validSeq(frame.ack)) return null;
      let acks: Record<string, number> | undefined;
      if (frame.acks !== undefined) {
        if (typeof frame.acks !== "object" || frame.acks === null || Array.isArray(frame.acks)) return null;
        acks = {};
        for (const [key, ack] of Object.entries(frame.acks as Record<string, unknown>)) {
          const legId = Number(key);
          if (!Number.isSafeInteger(legId) || legId < 1 || !validSeq(ack)) return null;
          acks[key] = ack as number;
        }
        if (Object.keys(acks).length > MAX_PHONE_LEGS) return null;
      }
      return {
        t: "hello",
        proto: frame.proto,
        device: frame.device,
        ...(frame.resume !== undefined ? { resume: frame.resume } : {}),
        ...(frame.ack !== undefined ? { ack: frame.ack as number } : {}),
        ...(acks !== undefined ? { acks } : {}),
      };
    }
    case "ping": {
      if (typeof frame.ts !== "number") return null;
      return { t: "ping", ts: frame.ts };
    }
    case "auth.refresh": {
      if (typeof frame.token !== "string" || !frame.token || frame.token.length > 8192) return null;
      return { t: "auth.refresh", token: frame.token };
    }
    case "ack": {
      if (!validSeq(frame.seq)) return null;
      if (frame.leg !== undefined && (!Number.isSafeInteger(frame.leg) || (frame.leg as number) < 1)) return null;
      return { t: "ack", seq: frame.seq as number, ...(frame.leg !== undefined ? { leg: frame.leg as number } : {}) };
    }
    default:
      return null;
  }
}

export function encodeControl(frame: ControlFrame): string {
  return JSON.stringify(frame);
}

function validSeq(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

interface RingEntry {
  seq: number;
  frame: ArrayBuffer;
}

/** Bounded replay ring for one directed stream. `broken` means un-acked
 * frames were evicted: any later resume that needs them must fail. */
export class ReplayRing {
  private entries: RingEntry[] = [];
  private bytes = 0;
  /** Highest seq ever enqueued for this stream. */
  lastEnqueued = 0;
  /** Set when un-acked frames were evicted; cleared only by a fresh session. */
  broken = false;

  push(seq: number, frame: ArrayBuffer): void {
    if (seq <= this.lastEnqueued) return; // sender resends are idempotent
    this.lastEnqueued = seq;
    this.entries.push({ seq, frame });
    this.bytes += frame.byteLength;
    while (this.entries.length > RING_MAX_FRAMES || this.bytes > RING_MAX_BYTES) {
      const evicted = this.entries.shift();
      if (!evicted) break;
      this.bytes -= evicted.frame.byteLength;
      this.broken = true;
    }
  }

  /** Prune entries the receiver has acknowledged. */
  ackTo(seq: number): void {
    while (this.entries.length > 0 && this.entries[0]!.seq <= seq) {
      this.bytes -= this.entries[0]!.frame.byteLength;
      this.entries.shift();
    }
  }

  /** Frames after the receiver's last-received seq, oldest first. */
  replayAfter(seq: number): ArrayBuffer[] {
    return this.entries.filter((entry) => entry.seq > seq).map((entry) => entry.frame);
  }

  /** Retained (un-acked) entries with their seqs, oldest first. */
  pendingEntries(): ReadonlyArray<{ seq: number; frame: ArrayBuffer }> {
    return this.entries;
  }

  /** A resume is valid only when the ring provably covers (ack, lastEnqueued]:
   * nothing was evicted un-acked, and the oldest retained frame is no newer
   * than ack+1. */
  coversGap(ack: number): boolean {
    if (this.broken) return false;
    if (ack > this.lastEnqueued) return false; // receiver claims the future
    if (ack === this.lastEnqueued) return true; // nothing outstanding
    const oldest = this.entries[0];
    return oldest !== undefined && oldest.seq <= ack + 1;
  }

  get size(): number {
    return this.entries.length;
  }
}

/** Random 32-byte resume key, base64url. */
export function mintResumeKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Resume keys are stored and compared as SHA-256 digests so DO storage never
 * holds the raw key. */
export async function sha256Base64(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  let binary = "";
  for (const byte of new Uint8Array(digest)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Mac/phone device identifiers on the URL path (opaque-identifier rule). */
export function validOpaqueId(value: string, maximum = 128): boolean {
  if (!value || value.length > maximum) return false;
  for (let i = 0; i < value.length; i += 1) {
    const code = value.charCodeAt(i);
    const alphanumeric =
      (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
    if (!alphanumeric && code !== 0x2d /* - */ && code !== 0x5f /* _ */ && code !== 0x3a /* : */ && code !== 0x2e /* . */) {
      return false;
    }
  }
  return true;
}

// ---- account-scoped stream addressing ----
//
// Every directed stream inside the account object is `dst<src` where each
// side is a namespaced endpoint key:
//   `h:<macDeviceId>`  the (single live) host leg of one Mac — keyed by the
//                      MAC, not its leg id, so host leg-id churn across
//                      resumes never re-keys the streams, and phone uploads
//                      buffered while that Mac is briefly away survive into
//                      the Mac's resume.
//   `p:<legId>`        one phone leg (stable id across ITS resumes).

export function hostKey(macDeviceId: string): string {
  return `h:${macDeviceId}`;
}

export function phoneKey(legId: number): string {
  return `p:${legId}`;
}

export function streamId(dst: string, src: string): string {
  return `${dst}<${src}`;
}

export function spillPrefix(dst: string, src: string): string {
  return `spill:${dst}:${src}:`;
}

export function spillKey(dst: string, src: string, seq: number): string {
  return `${spillPrefix(dst, src)}${String(seq).padStart(16, "0")}`;
}
