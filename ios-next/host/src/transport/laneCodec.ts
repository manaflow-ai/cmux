// PROTOCOL.md §1 "Fragmentation": every lane message is split into chunks of
// at most 16 KiB of payload, each prefixed with a flag byte. Bit 0 (0x01)
// marks the final chunk of a message. Lanes are ordered, so the receiver just
// concatenates chunks until it sees a final one.

export const MAX_CHUNK_PAYLOAD = 16 * 1024;
export const FLAG_FINAL = 0x01;

/** Splits one message into wire chunks. An empty message is one final chunk. */
export function encodeMessage(message: Uint8Array, maxPayload = MAX_CHUNK_PAYLOAD): Uint8Array[] {
  if (message.byteLength === 0) return [Uint8Array.of(FLAG_FINAL)];
  const chunks: Uint8Array[] = [];
  for (let off = 0; off < message.byteLength; off += maxPayload) {
    const end = Math.min(off + maxPayload, message.byteLength);
    const chunk = new Uint8Array(1 + end - off);
    chunk[0] = end === message.byteLength ? FLAG_FINAL : 0;
    chunk.set(message.subarray(off, end), 1);
    chunks.push(chunk);
  }
  return chunks;
}

/** Per-lane reassembly of chunks into whole messages. */
export class Reassembler {
  private parts: Uint8Array[] = [];
  private size = 0;

  constructor(private readonly maxMessageBytes = 256 * 1024 * 1024) {}

  /** Feeds one chunk; returns the completed message when the chunk is final. */
  push(chunk: Uint8Array): Uint8Array | null {
    if (chunk.byteLength < 1) throw new Error("lane chunk without flag byte");
    const flags = chunk[0]!;
    const payload = chunk.subarray(1);
    this.size += payload.byteLength;
    if (this.size > this.maxMessageBytes) {
      this.reset();
      throw new Error("lane message exceeds limit");
    }
    if ((flags & FLAG_FINAL) === 0) {
      // Copy: the transport may reuse its buffer.
      this.parts.push(Uint8Array.from(payload));
      return null;
    }
    let out: Uint8Array;
    if (this.parts.length === 0) {
      out = Uint8Array.from(payload);
    } else {
      out = new Uint8Array(this.size);
      let off = 0;
      for (const p of this.parts) {
        out.set(p, off);
        off += p.byteLength;
      }
      out.set(payload, off);
    }
    this.reset();
    return out;
  }

  reset(): void {
    this.parts = [];
    this.size = 0;
  }
}
