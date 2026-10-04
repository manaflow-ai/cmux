// Credit-based byte streams (spec: "byte stream"). A writer may send only as many payload
// bytes as the reader granted; the reader grants more with `{"t":"credit"}` (or the credit
// field of a binary frame it sends). Frames are capped at `maxFramePayload`, so a large
// transfer interleaves with calls instead of blocking them.

import { ProtocolError, ProtocolErrorCode } from "./errors";
import { MAX_U32, type EndMessage } from "./envelope";

export interface ByteStreamHost {
  sendFrame(stream: number, payload: Uint8Array): void;
  sendCredit(stream: number, bytes: number): void;
  sendEnd(stream: number, abort?: { code: string; message: string }): void;
  forget(stream: number): void;
}

export interface ByteStreamOptions {
  /**
   * Receive window. The stream grants this many bytes up front and grants back each chunk
   * after its data listeners return. Leave unset to grant manually with `grant()`.
   */
  window?: number;
  maxFramePayload?: number;
}

interface PendingWrite {
  data: Uint8Array;
  offset: number;
  resolve: () => void;
  reject: (error: Error) => void;
}

export const DEFAULT_MAX_FRAME_PAYLOAD = 64 * 1024;

export class ByteStream {
  readonly id: number;
  readonly op: string;
  private readonly host: ByteStreamHost;
  private readonly maxFramePayload: number;
  private readonly window: number | undefined;
  private sendCredit = 0;
  /** Bytes we granted that the peer has not used yet. */
  private recvCredit = 0;
  private readonly writes: PendingWrite[] = [];
  private readonly dataListeners = new Set<(chunk: Uint8Array) => void>();
  private readonly buffered: Uint8Array[] = [];
  private readonly endListeners = new Set<(error: ProtocolError | null) => void>();
  private localEndRequested = false;
  private localEnded = false;
  private remoteEnded = false;
  private failure: ProtocolError | null = null;
  private endedNotified = false;
  private readonly drainWaiters: Array<() => void> = [];

  constructor(host: ByteStreamHost, id: number, op: string, options: ByteStreamOptions = {}) {
    this.host = host;
    this.id = id;
    this.op = op;
    this.maxFramePayload = Math.max(1, options.maxFramePayload ?? DEFAULT_MAX_FRAME_PAYLOAD);
    this.window = options.window;
  }

  /** Called once the stream is registered with the session, so the initial grant follows `open`. */
  start(): void {
    if (this.window && this.window > 0) this.grant(this.window);
  }

  get availableCredit(): number {
    return this.sendCredit;
  }

  get ended(): boolean {
    return this.endedNotified;
  }

  /** Queues bytes; resolves once every byte has been framed and handed to the transport. */
  write(data: Uint8Array): Promise<void> {
    if (this.failure) return Promise.reject(this.failure);
    if (this.localEndRequested) {
      return Promise.reject(new ProtocolError(ProtocolErrorCode.streamAborted, "write after end"));
    }
    if (data.byteLength === 0) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      this.writes.push({ data, offset: 0, resolve, reject });
      this.pump();
    });
  }

  /** Ends our direction after queued writes drain. */
  end(): Promise<void> {
    if (this.failure) return Promise.reject(this.failure);
    if (!this.localEndRequested) {
      this.localEndRequested = true;
      this.pump();
    }
    if (this.localEnded) return Promise.resolve();
    return new Promise<void>((resolve) => this.drainWaiters.push(resolve));
  }

  /** Aborts both directions and tells the peer. */
  abort(code: string = ProtocolErrorCode.streamAborted, message = "stream aborted"): void {
    if (this.failure || this.endedNotified) return;
    this.host.sendEnd(this.id, { code, message });
    this.fail(new ProtocolError(code, message));
  }

  /** Allows the peer to send `bytes` more. */
  grant(bytes: number): void {
    if (this.failure || this.remoteEnded || bytes <= 0) return;
    const amount = Math.min(bytes, MAX_U32);
    this.recvCredit = Math.min(this.recvCredit + amount, MAX_U32);
    this.host.sendCredit(this.id, amount);
  }

  /**
   * Data that arrives before the first listener is held (at most the granted credit) and
   * delivered to it, so attaching after `await openStream()` loses nothing.
   */
  onData(cb: (chunk: Uint8Array) => void): () => void {
    this.dataListeners.add(cb);
    if (this.buffered.length > 0) {
      for (const chunk of this.buffered.splice(0)) this.dispatch(chunk);
      this.maybeFinish();
    }
    return () => this.dataListeners.delete(cb);
  }

  /** Fires once when both directions finished (null) or the stream failed. */
  onEnd(cb: (error: ProtocolError | null) => void): () => void {
    if (this.endedNotified) {
      const failure = this.failure;
      queueMicrotask(() => cb(failure));
      return () => {};
    }
    this.endListeners.add(cb);
    return () => this.endListeners.delete(cb);
  }

  // Session-facing entry points.

  receiveCredit(bytes: number): void {
    if (this.failure) return;
    this.sendCredit = Math.min(this.sendCredit + bytes, MAX_U32);
    this.pump();
  }

  receiveData(payload: Uint8Array, headerCredit: number): void {
    if (this.failure) return;
    if (headerCredit > 0) this.receiveCredit(headerCredit);
    if (payload.byteLength === 0) return;
    if (this.remoteEnded) {
      this.abort(ProtocolErrorCode.streamAborted, "data after end");
      return;
    }
    if (payload.byteLength > this.recvCredit) {
      this.abort(
        ProtocolErrorCode.creditExceeded,
        `peer sent ${payload.byteLength} bytes with ${this.recvCredit} credit`,
      );
      return;
    }
    this.recvCredit -= payload.byteLength;
    // Listeners may keep the chunk; copy it out of the frame buffer.
    const chunk = payload.slice();
    if (this.dataListeners.size === 0) this.buffered.push(chunk);
    else this.dispatch(chunk);
  }

  private dispatch(chunk: Uint8Array): void {
    for (const cb of Array.from(this.dataListeners)) cb(chunk);
    if (this.window && !this.failure) this.grant(chunk.byteLength);
  }

  receiveEnd(msg: EndMessage): void {
    if (this.failure) return;
    if (msg.code) {
      this.fail(new ProtocolError(msg.code, msg.message ?? "stream aborted by peer"));
      return;
    }
    this.remoteEnded = true;
    this.maybeFinish();
  }

  fail(error: ProtocolError): void {
    if (this.failure || this.endedNotified) return;
    this.failure = error;
    for (const write of this.writes.splice(0)) write.reject(error);
    for (const waiter of this.drainWaiters.splice(0)) waiter();
    this.notifyEnd();
  }

  private pump(): void {
    while (this.writes.length > 0 && this.sendCredit > 0 && !this.failure) {
      const write = this.writes[0];
      const remaining = write.data.byteLength - write.offset;
      const size = Math.min(remaining, this.sendCredit, this.maxFramePayload);
      this.host.sendFrame(this.id, write.data.subarray(write.offset, write.offset + size));
      this.sendCredit -= size;
      write.offset += size;
      if (write.offset === write.data.byteLength) {
        this.writes.shift();
        write.resolve();
      }
    }
    if (this.localEndRequested && !this.localEnded && this.writes.length === 0 && !this.failure) {
      this.localEnded = true;
      this.host.sendEnd(this.id);
      for (const waiter of this.drainWaiters.splice(0)) waiter();
      this.maybeFinish();
    }
  }

  private maybeFinish(): void {
    if (this.localEnded && this.remoteEnded && this.buffered.length === 0) this.notifyEnd();
  }

  private notifyEnd(): void {
    if (this.endedNotified) return;
    this.endedNotified = true;
    this.host.forget(this.id);
    const listeners = [...this.endListeners];
    this.endListeners.clear();
    this.dataListeners.clear();
    this.buffered.length = 0;
    for (const cb of listeners) cb(this.failure);
  }
}
