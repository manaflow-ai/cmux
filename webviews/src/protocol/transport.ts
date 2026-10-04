// Engine-neutral transport for the pane protocol (spec: "Transports (one interface)").
// A transport moves whole messages: a string is one JSON envelope, a Uint8Array is one
// binary stream frame. Typed calls, subscriptions, handles and streams live in Session
// and never see the transport kind.

export type TransportMessage = string | Uint8Array;

export interface TransportCloseInfo {
  /** Engine close code when the engine has one (WebSocket close code, for example). */
  code?: number;
  reason?: string;
}

export interface Transport {
  send(msg: TransportMessage): void;
  /** Returns an unsubscribe function. Messages that arrive before the first listener are queued. */
  onMessage(cb: (msg: TransportMessage) => void): () => void;
  /** Fires once. A listener added after close fires on the next microtask. */
  onClose(cb: (info: TransportCloseInfo) => void): () => void;
  close(): void;
  readonly closed: boolean;
}

export class TransportClosedError extends Error {
  constructor(message = "transport is closed") {
    super(message);
    this.name = "TransportClosedError";
  }
}

/**
 * Shared bookkeeping for adapters: listener sets, a queue for messages that arrive before
 * anyone listens (an adapter often receives its first host push before Session attaches),
 * and close-once semantics. Adapters call `deliver` and `finish`, and implement `sendRaw`
 * and `closeRaw`.
 */
export abstract class BaseTransport implements Transport {
  private readonly messageListeners = new Set<(msg: TransportMessage) => void>();
  private readonly closeListeners = new Set<(info: TransportCloseInfo) => void>();
  private readonly pending: TransportMessage[] = [];
  private closeInfo: TransportCloseInfo | null = null;

  get closed(): boolean {
    return this.closeInfo !== null;
  }

  send(msg: TransportMessage): void {
    if (this.closeInfo) throw new TransportClosedError();
    this.sendRaw(msg);
  }

  onMessage(cb: (msg: TransportMessage) => void): () => void {
    this.messageListeners.add(cb);
    if (this.pending.length > 0) {
      const queued = this.pending.splice(0);
      for (const msg of queued) cb(msg);
    }
    return () => this.messageListeners.delete(cb);
  }

  onClose(cb: (info: TransportCloseInfo) => void): () => void {
    const info = this.closeInfo;
    if (info) {
      queueMicrotask(() => cb(info));
      return () => {};
    }
    this.closeListeners.add(cb);
    return () => this.closeListeners.delete(cb);
  }

  close(): void {
    if (this.closeInfo) return;
    try {
      this.closeRaw();
    } finally {
      this.finish({ reason: "closed locally" });
    }
  }

  protected deliver(msg: TransportMessage): void {
    if (this.closeInfo) return;
    if (this.messageListeners.size === 0) {
      this.pending.push(msg);
      return;
    }
    for (const cb of Array.from(this.messageListeners)) cb(msg);
  }

  protected finish(info: TransportCloseInfo): void {
    if (this.closeInfo) return;
    this.closeInfo = info;
    this.pending.length = 0;
    const listeners = [...this.closeListeners];
    this.closeListeners.clear();
    this.messageListeners.clear();
    for (const cb of listeners) cb(info);
  }

  protected abstract sendRaw(msg: TransportMessage): void;
  protected abstract closeRaw(): void;
}

/** Copies a binary payload into a standalone Uint8Array (engines hand out ArrayBuffer, views or Buffers). */
export function toUint8Array(data: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
}
