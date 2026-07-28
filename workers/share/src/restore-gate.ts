// SPDX-License-Identifier: GPL-3.0-or-later

import type { Effect } from "./session";

interface WaitingConnection {
  readonly outstanding: Set<string>;
  readonly queued: Effect[];
}

/**
 * Keeps outbound work for a hibernation survivor behind the delivery credit
 * that was serialized before eviction. Non-socket effects and unrelated
 * sockets continue immediately, so fetch and alarm wakes cannot violate the
 * ACK-before-restore ordering or stall the room.
 */
export class HibernationRestoreGate {
  private readonly waiting = new Map<string, WaitingConnection>();

  register(connectionId: string, outstandingNonces: ReadonlyArray<string>): void {
    if (outstandingNonces.length === 0) {
      this.waiting.delete(connectionId);
      return;
    }
    this.waiting.set(connectionId, {
      outstanding: new Set(outstandingNonces),
      queued: [],
    });
  }

  isWaiting(connectionId: string): boolean {
    return this.waiting.has(connectionId);
  }

  /**
   * Queue sends to waiting survivors. A close is authoritative and cannot wait
   * for a peer that may never ACK, so it discards that survivor's held sends.
   */
  route(effects: ReadonlyArray<Effect>): Effect[] {
    const immediate: Effect[] = [];
    for (const effect of effects) {
      if (
        effect.kind !== "send" &&
        effect.kind !== "sendBinary" &&
        effect.kind !== "close"
      ) {
        immediate.push(effect);
        continue;
      }
      const waiting = this.waiting.get(effect.to);
      if (!waiting) {
        immediate.push(effect);
        continue;
      }
      if (effect.kind === "close") {
        this.waiting.delete(effect.to);
        immediate.push(effect);
        continue;
      }
      waiting.queued.push(effect);
    }
    return immediate;
  }

  /**
   * Release one nonce only for its original socket. Buffered effects become
   * runnable after every pre-wake entry has been acknowledged.
   */
  release(connectionId: string, nonce: string): Effect[] {
    const waiting = this.waiting.get(connectionId);
    if (!waiting || !waiting.outstanding.delete(nonce)) return [];
    if (waiting.outstanding.size > 0) return [];
    this.waiting.delete(connectionId);
    return waiting.queued;
  }

  discard(connectionId: string): void {
    this.waiting.delete(connectionId);
  }

  clear(): void {
    this.waiting.clear();
  }
}
