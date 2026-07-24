// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Manaflow, Inc.
//
// Pure decision logic for the ShareSession Durable Object: identifier
// generation, palette colors, join verdict memory, chat history capping,
// cursor rate limiting, and inbound message validation. Everything here is
// side-effect free (random sources are injected) so bun tests cover it
// without miniflare.

export const SHARE_ID_LENGTH = 22;
export const BASE62_ALPHABET =
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
export const HOST_TOKEN_BYTES = 32;
export const PALETTE_SIZE = 10;
export const HOST_COLOR = 0;
/** Frames from viewers larger than this close the socket (1009). */
export const MAX_VIEWER_FRAME_BYTES = 32 * 1024;
/** Host frames may carry snapshots (replay_b64 <= 256KB per pane). */
export const MAX_HOST_FRAME_BYTES = 1024 * 1024;
export const CHAT_HISTORY_CAP = 200;
/** Bound stored chat text so 200 retained messages stay small in DO storage. */
export const MAX_CHAT_TEXT_LENGTH = 4096;
export const CURSOR_RATE_PER_SEC = 30;
/** Host reconnect grace before the session is ended and storage deleted. */
export const HOST_GRACE_MS = 60_000;

export type Role = "host" | "viewer";
export type Verdict = "approved" | "denied";
export type JoinState = "pending" | "approved" | "denied";

export interface Participant {
  id: string;
  email: string;
  name: string;
  color: number;
  role: Role;
}

export interface StoredChatMessage {
  type: "chat";
  participantId: string;
  ts: number;
  text: string;
  x: number;
  y: number;
}

/** Fill shape of crypto.getRandomValues, injected so tests are deterministic. */
export type RandomFill = (bytes: Uint8Array) => Uint8Array;

/** Uniform base62 id via rejection sampling: a byte is accepted only when it
 * falls inside the largest multiple of 62 below 256 (62 * 4 = 248), so
 * `byte % 62` is unbiased. Rejected bytes are simply redrawn. */
export function generateShareId(
  randomFill: RandomFill,
  length: number = SHARE_ID_LENGTH,
): string {
  const limit = 62 * 4; // 248: largest multiple of 62 that fits in a byte
  let out = "";
  const buf = new Uint8Array(length * 2); // over-provision to cut redraw loops
  while (out.length < length) {
    randomFill(buf);
    for (const byte of buf) {
      if (byte >= limit) continue; // rejection sampling: redraw biased bytes
      out += BASE62_ALPHABET[byte % 62];
      if (out.length === length) break;
    }
  }
  return out;
}

export function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Per-session host credential: 32 random bytes, base64url (43 chars). Only
 * its SHA-256 hash is stored in the DO. */
export function generateHostToken(randomFill: RandomFill): string {
  return base64UrlEncode(randomFill(new Uint8Array(HOST_TOKEN_BYTES)));
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Viewer palette color for the nth admitted viewer (0-based ordinal). The
 * host permanently owns index 0, so viewers cycle the remaining 9 slots and
 * can never collide with the host color. */
export function viewerColor(ordinal: number): number {
  return 1 + (((ordinal % (PALETTE_SIZE - 1)) + (PALETTE_SIZE - 1)) % (PALETTE_SIZE - 1));
}

/** Initial join state from the remembered per-user verdict: an earlier allow
 * admits immediately, an earlier deny rejects immediately, no verdict waits
 * for the host. */
export function joinStateForVerdict(verdict: Verdict | undefined): JoinState {
  return verdict ?? "pending";
}

/** Append one chat message, keeping only the newest `cap` entries. */
export function appendChat(
  history: readonly StoredChatMessage[],
  entry: StoredChatMessage,
  cap: number = CHAT_HISTORY_CAP,
): StoredChatMessage[] {
  const next = [...history, entry];
  return next.length > cap ? next.slice(next.length - cap) : next;
}

// ---- Cursor rate limiting (token bucket, 30 msgs/sec per socket) ----

export interface TokenBucket {
  tokens: number;
  lastRefillMs: number;
}

export function newTokenBucket(
  nowMs: number,
  burst: number = CURSOR_RATE_PER_SEC,
): TokenBucket {
  return { tokens: burst, lastRefillMs: nowMs };
}

/** Take one token if available, refilling at `ratePerSec` up to `burst`.
 * Returns false when the caller should silently drop the message. */
export function tryTakeToken(
  bucket: TokenBucket,
  nowMs: number,
  ratePerSec: number = CURSOR_RATE_PER_SEC,
  burst: number = CURSOR_RATE_PER_SEC,
): boolean {
  const elapsedMs = Math.max(0, nowMs - bucket.lastRefillMs);
  bucket.tokens = Math.min(burst, bucket.tokens + (elapsedMs * ratePerSec) / 1000);
  bucket.lastRefillMs = nowMs;
  if (bucket.tokens < 1) return false;
  bucket.tokens -= 1;
  return true;
}

// ---- Frame size gates ----

/** Whether a frame of `byteLength` is admissible for `role`. Oversize frames
 * close the socket with 1009 (message too big). */
export function frameWithinLimit(role: Role, byteLength: number): boolean {
  return byteLength <= (role === "host" ? MAX_HOST_FRAME_BYTES : MAX_VIEWER_FRAME_BYTES);
}

// ---- Inbound message validation ----

export type IncomingMessage =
  | { type: "join_response"; requestId: string; allow: boolean }
  | { type: "snapshot"; to: string; workspace: unknown }
  | { type: "layout"; workspace: unknown }
  | { type: "term"; surfaceId: string; seq: number; data_b64: string }
  | { type: "term_resize"; surfaceId: string; cols: number; rows: number }
  | { type: "textbox"; paneId: string; text: string; selStart: number; selEnd: number; active: boolean }
  | { type: "cursor"; x: number; y: number }
  | { type: "chat"; text: string; x: number; y: number }
  | { type: "end" };

const VIEWER_TYPES: ReadonlySet<string> = new Set(["cursor", "chat"]);

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Validate one decoded frame for `role`. Returns null for anything that
 * should be silently dropped: unknown types, missing/ill-typed fields, and
 * every non-cursor/chat type from a viewer (viewers are read-only by
 * protocol; no input path to the Mac exists). Cursor coordinates are clamped
 * to [0,1]; chat text is trimmed and bounded. */
export function parseIncoming(role: Role, value: unknown): IncomingMessage | null {
  if (!isRecord(value) || typeof value.type !== "string") return null;
  const type = value.type;
  if (role === "viewer" && !VIEWER_TYPES.has(type)) return null;

  switch (type) {
    case "cursor": {
      const x = finiteNumber(value.x);
      const y = finiteNumber(value.y);
      if (x === null || y === null) return null;
      return { type, x: clamp01(x), y: clamp01(y) };
    }
    case "chat": {
      const rawText = typeof value.text === "string" ? value.text.trim() : "";
      if (!rawText) return null;
      const x = finiteNumber(value.x);
      const y = finiteNumber(value.y);
      if (x === null || y === null) return null;
      return {
        type,
        text: rawText.slice(0, MAX_CHAT_TEXT_LENGTH),
        x: clamp01(x),
        y: clamp01(y),
      };
    }
    case "join_response": {
      const requestId = nonEmptyString(value.requestId);
      if (requestId === null || typeof value.allow !== "boolean") return null;
      return { type, requestId, allow: value.allow };
    }
    case "snapshot": {
      const to = nonEmptyString(value.to);
      if (to === null || !isRecord(value.workspace)) return null;
      return { type, to, workspace: value.workspace };
    }
    case "layout": {
      if (!isRecord(value.workspace)) return null;
      return { type, workspace: value.workspace };
    }
    case "term": {
      const surfaceId = nonEmptyString(value.surfaceId);
      const seq = finiteNumber(value.seq);
      if (surfaceId === null || seq === null || typeof value.data_b64 !== "string") return null;
      return { type, surfaceId, seq, data_b64: value.data_b64 };
    }
    case "term_resize": {
      const surfaceId = nonEmptyString(value.surfaceId);
      const cols = finiteNumber(value.cols);
      const rows = finiteNumber(value.rows);
      if (surfaceId === null || cols === null || rows === null) return null;
      return { type, surfaceId, cols, rows };
    }
    case "textbox": {
      const paneId = nonEmptyString(value.paneId);
      const selStart = finiteNumber(value.selStart);
      const selEnd = finiteNumber(value.selEnd);
      if (
        paneId === null ||
        typeof value.text !== "string" ||
        selStart === null ||
        selEnd === null ||
        typeof value.active !== "boolean"
      ) {
        return null;
      }
      return { type, paneId, text: value.text, selStart, selEnd, active: value.active };
    }
    case "end":
      return { type };
    default:
      return null;
  }
}
