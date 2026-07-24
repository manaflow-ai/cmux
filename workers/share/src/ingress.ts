// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded per-socket application ingress accounting for untrusted guests.

import {
  BINARY_KIND_GRID,
  decodeBinaryHeader,
  type BinaryHeader,
  MAX_BINARY_FRAME_BYTES,
} from "./protocol";

export const APPLICATION_INGRESS_WINDOW_MS = 1_000;
export const MAX_APPLICATION_MESSAGES_PER_WINDOW = 120;
export const MAX_APPLICATION_BYTES_PER_WINDOW = 512 * 1024;

interface IngressWindow {
  startedAt: number;
  messages: number;
  bytes: number;
}

/** Fixed one-second windows are intentionally represented by one small record
 * per connected guest. Exact matching delivery ACKs are refunded by the DO;
 * invalid, pending, viewer, and unknown/replayed ACK traffic remains charged. */
export class ApplicationIngressLimiter {
  private readonly windows = new Map<string, IngressWindow>();

  consume(id: string, bytes: number, now: number): boolean {
    if (
      !Number.isSafeInteger(bytes) ||
      bytes < 0 ||
      !Number.isFinite(now)
    ) {
      return false;
    }
    let window = this.windows.get(id);
    if (
      !window ||
      now < window.startedAt ||
      now >= window.startedAt + APPLICATION_INGRESS_WINDOW_MS
    ) {
      window = { startedAt: now, messages: 0, bytes: 0 };
      this.windows.set(id, window);
    }
    if (
      window.messages >= MAX_APPLICATION_MESSAGES_PER_WINDOW ||
      bytes > MAX_APPLICATION_BYTES_PER_WINDOW - window.bytes
    ) {
      return false;
    }
    window.messages += 1;
    window.bytes += bytes;
    return true;
  }

  /** Refund the immediately consumed message when it proves to be an exact
   * outstanding ACK. No other message path calls this method. */
  refund(id: string, bytes: number, now: number): void {
    const window = this.windows.get(id);
    if (
      !window ||
      now < window.startedAt ||
      now >= window.startedAt + APPLICATION_INGRESS_WINDOW_MS ||
      !Number.isSafeInteger(bytes) ||
      bytes < 0 ||
      window.messages <= 0 ||
      window.bytes < bytes
    ) {
      return;
    }
    window.messages -= 1;
    window.bytes -= bytes;
  }

  remove(id: string): void {
    this.windows.delete(id);
  }

  get profileCount(): number {
    return this.windows.size;
  }

  profile(id: string): Readonly<IngressWindow> | null {
    const window = this.windows.get(id);
    return window ? { ...window } : null;
  }
}

export type BinaryIngressDecision =
  | { ok: true; header: BinaryHeader }
  | { ok: false; code: 1009 | 4400; reason: string };

/** Validate the complete host frame before the session core can fan out any
 * prefix. Guest binary and every non-v1/malformed header are protocol errors. */
export function validateBinaryIngress(
  isHost: boolean,
  bytes: Uint8Array,
): BinaryIngressDecision {
  if (!isHost) return { ok: false, code: 4400, reason: "guest binary not allowed" };
  if (bytes.byteLength >= MAX_BINARY_FRAME_BYTES) {
    return { ok: false, code: 1009, reason: "binary message too large" };
  }
  const header = decodeBinaryHeader(bytes);
  if (!header || header.kind !== BINARY_KIND_GRID) {
    return { ok: false, code: 4400, reason: "invalid binary message" };
  }
  return { ok: true, header };
}
