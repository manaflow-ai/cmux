// In-memory Link pair for tests. Chunks go through the real LaneCodec and are
// delivered asynchronously, preserving per-lane order. Bytes sent but not yet
// delivered count as the sender's bufferedAmount, and the receiving side can
// stop draining (holdDelivery) to simulate a slow phone.

import { ChunkLink, type Lane } from "./link.ts";

class LoopbackLink extends ChunkLink {
  peer: LoopbackLink | null = null;
  private readonly inFlight: Record<Lane, number> = { ctl: 0, int: 0, blk: 0 };
  /** Chunks waiting while the receiver holds delivery. */
  private held: { lane: Lane; chunk: Uint8Array; from: LoopbackLink }[] = [];
  private holding = false;

  constructor(private readonly name: string) {
    super();
  }

  describe(): string {
    return `loopback ${this.name}`;
  }

  override bufferedAmount(lane: Lane): number {
    return this.inFlight[lane];
  }

  /** Receiver side: stop (true) or resume (false) consuming incoming chunks. */
  holdDelivery(hold: boolean): void {
    this.holding = hold;
    if (hold) return;
    const held = this.held;
    this.held = [];
    for (const h of held) this.consume(h.lane, h.chunk, h.from);
  }

  protected sendChunk(lane: Lane, chunk: Uint8Array): void {
    const peer = this.peer;
    const copy = Uint8Array.from(chunk);
    this.inFlight[lane] += copy.byteLength;
    setImmediate(() => {
      if (!peer || peer.state === "closed") {
        this.inFlight[lane] -= copy.byteLength;
        return;
      }
      peer.deliver(lane, copy, this);
    });
  }

  deliver(lane: Lane, chunk: Uint8Array, from: LoopbackLink): void {
    if (this.holding) {
      this.held.push({ lane, chunk, from });
      return;
    }
    this.consume(lane, chunk, from);
  }

  private consume(lane: Lane, chunk: Uint8Array, from: LoopbackLink): void {
    from.inFlight[lane] -= chunk.byteLength;
    if (this.state !== "closed") this.receiveChunk(lane, chunk);
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

export type { LoopbackLink };

/** a opens now, b only when the returned function is called (lane-open race). */
export function createStaggeredLoopbackPair(): [LoopbackLink, LoopbackLink, () => void] {
  const a = new LoopbackLink("a");
  const b = new LoopbackLink("b");
  a.peer = b;
  b.peer = a;
  a.open();
  return [a, b, () => b.open()];
}

/** Returns two connected links (a = phone side, b = host side by convention). */
export function createLoopbackPair(): [LoopbackLink, LoopbackLink] {
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
export function createOpenLoopbackPair(): [LoopbackLink, LoopbackLink] {
  const a = new LoopbackLink("a");
  const b = new LoopbackLink("b");
  a.peer = b;
  b.peer = a;
  a.open();
  b.open();
  return [a, b];
}
