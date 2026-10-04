// In-memory transport pair for tests. Delivery is asynchronous (one microtask per message,
// in order) like a real socket, and every message is copied so peers never share buffers.

import { BaseTransport, type TransportMessage } from "../transport";

export class MockTransport extends BaseTransport {
  peer: MockTransport | null = null;
  /** Every message this side sent, in order. */
  readonly sent: TransportMessage[] = [];

  protected sendRaw(msg: TransportMessage): void {
    const copy = typeof msg === "string" ? msg : msg.slice();
    this.sent.push(copy);
    const peer = this.peer;
    queueMicrotask(() => peer?.receiveFromPeer(copy));
  }

  protected closeRaw(): void {
    const peer = this.peer;
    queueMicrotask(() => peer?.closeFromPeer());
  }

  /** Simulates the remote end dropping the connection. */
  drop(reason = "dropped"): void {
    this.finish({ reason });
    const peer = this.peer;
    queueMicrotask(() => peer?.closeFromPeer(reason));
  }

  private receiveFromPeer(msg: TransportMessage): void {
    this.deliver(msg);
  }

  private closeFromPeer(reason = "peer closed"): void {
    this.finish({ reason });
  }
}

export function createMockPair(): [MockTransport, MockTransport] {
  const a = new MockTransport();
  const b = new MockTransport();
  a.peer = b;
  b.peer = a;
  return [a, b];
}
