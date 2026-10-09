// In-memory Link pair for tests. Chunks go through the real LaneCodec and are
// delivered asynchronously, preserving per-lane order.

import { ChunkLink, type Lane } from "./link.ts";

class LoopbackLink extends ChunkLink {
  peer: LoopbackLink | null = null;

  constructor(private readonly name: string) {
    super();
  }

  describe(): string {
    return `loopback ${this.name}`;
  }

  protected sendChunk(lane: Lane, chunk: Uint8Array): void {
    const peer = this.peer;
    const copy = Uint8Array.from(chunk);
    setImmediate(() => {
      if (peer && peer.state === "open") peer.deliver(lane, copy);
    });
  }

  deliver(lane: Lane, chunk: Uint8Array): void {
    this.receiveChunk(lane, chunk);
  }

  protected closeTransport(): void {
    const peer = this.peer;
    this.peer = null;
    if (peer) setImmediate(() => peer.close("peer closed"));
  }

  open(): void {
    this.setState("open");
  }
}

/** Returns two connected links (a = phone side, b = host side by convention). */
export function createLoopbackPair(): [ChunkLink, ChunkLink] {
  const a = new LoopbackLink("a");
  const b = new LoopbackLink("b");
  a.peer = b;
  b.peer = a;
  setImmediate(() => {
    a.open();
    b.open();
  });
  return [a, b];
}

/** Same as createLoopbackPair but already open (synchronous). */
export function createOpenLoopbackPair(): [ChunkLink, ChunkLink] {
  const a = new LoopbackLink("a");
  const b = new LoopbackLink("b");
  a.peer = b;
  b.peer = a;
  a.open();
  b.open();
  return [a, b];
}
