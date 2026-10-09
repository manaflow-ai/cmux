import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { encodeMessage, FLAG_FINAL, MAX_CHUNK_PAYLOAD, Reassembler } from "../src/transport/laneCodec.ts";

describe("laneCodec", () => {
  it("encodes an empty message as one final chunk", () => {
    const chunks = encodeMessage(new Uint8Array());
    expect(chunks).toEqual([Uint8Array.of(FLAG_FINAL)]);
    expect(new Reassembler().push(chunks[0]!)).toEqual(new Uint8Array());
  });

  it("keeps small messages in one chunk", () => {
    const msg = new TextEncoder().encode("hello");
    const chunks = encodeMessage(msg);
    expect(chunks.length).toBe(1);
    expect(chunks[0]![0]).toBe(FLAG_FINAL);
    expect(new Reassembler().push(chunks[0]!)).toEqual(msg);
  });

  it("splits exactly at 16 KiB boundaries", () => {
    const msg = randomBytes(MAX_CHUNK_PAYLOAD * 2);
    const chunks = encodeMessage(msg);
    expect(chunks.map((c) => c.byteLength)).toEqual([MAX_CHUNK_PAYLOAD + 1, MAX_CHUNK_PAYLOAD + 1]);
    expect(chunks.map((c) => c[0])).toEqual([0, FLAG_FINAL]);
  });

  it("round-trips a 1 MB message and back-to-back messages", () => {
    const big = new Uint8Array(randomBytes(1024 * 1024 + 123));
    const small = new Uint8Array(randomBytes(10));
    const r = new Reassembler();
    const out: Uint8Array[] = [];
    for (const c of [...encodeMessage(big), ...encodeMessage(small)]) {
      expect(c.byteLength).toBeLessThanOrEqual(MAX_CHUNK_PAYLOAD + 1);
      const m = r.push(c);
      if (m) out.push(m);
    }
    expect(out.length).toBe(2);
    expect(Buffer.compare(Buffer.from(out[0]!), Buffer.from(big))).toBe(0);
    expect(out[1]).toEqual(small);
  });

  it("rejects chunks without a flag byte", () => {
    expect(() => new Reassembler().push(new Uint8Array())).toThrow();
  });
});
