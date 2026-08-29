import { describe, expect, test } from "bun:test";

import {
  DATA_FRAME_VERSION,
  DATA_HEADER_BYTES,
  DATA_KIND_DATA,
  MAX_DATA_FRAME_BYTES,
  RING_MAX_BYTES,
  RING_MAX_FRAMES,
  ReplayRing,
  decodeControl,
  decodeDataHeader,
  encodeControl,
  mintResumeKey,
  relayObjectName,
  rewriteLegId,
  sha256Base64,
  validOpaqueId,
} from "../src/relayProtocol";

function dataFrame(legId: number, seq: number, payloadBytes = 4): ArrayBuffer {
  const buffer = new ArrayBuffer(DATA_HEADER_BYTES + payloadBytes);
  const view = new DataView(buffer);
  view.setUint8(0, DATA_FRAME_VERSION);
  view.setUint8(1, DATA_KIND_DATA);
  view.setUint32(2, legId);
  view.setBigUint64(6, BigInt(seq));
  return buffer;
}

describe("data frame header", () => {
  test("round-trips version, kind, legId, seq", () => {
    const header = decodeDataHeader(dataFrame(7, 42));
    expect(header).toEqual({ version: 1, kind: DATA_KIND_DATA, legId: 7, seq: 42 });
  });

  test("rejects wrong version, short frames, zero seq, oversize", () => {
    const wrongVersion = dataFrame(1, 1);
    new DataView(wrongVersion).setUint8(0, 2);
    expect(decodeDataHeader(wrongVersion)).toBeNull();
    expect(decodeDataHeader(new ArrayBuffer(DATA_HEADER_BYTES - 1))).toBeNull();
    expect(decodeDataHeader(dataFrame(1, 0))).toBeNull();
    expect(decodeDataHeader(new ArrayBuffer(MAX_DATA_FRAME_BYTES + 1))).toBeNull();
  });

  test("rewriteLegId stamps the routing field in place", () => {
    const frame = dataFrame(0, 9);
    rewriteLegId(frame, 12345);
    expect(decodeDataHeader(frame)?.legId).toBe(12345);
  });
});

describe("control frames", () => {
  test("hello with resume, phone ack, and host acks map", () => {
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "mac-1" }))).toEqual({
      t: "hello",
      proto: "dot/1",
      device: "mac-1",
    });
    expect(
      decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "p", resume: "k", ack: 5 })),
    ).toEqual({ t: "hello", proto: "dot/1", device: "p", resume: "k", ack: 5 });
    expect(
      decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "m", acks: { "3": 17 } })),
    ).toEqual({ t: "hello", proto: "dot/1", device: "m", acks: { "3": 17 } });
  });

  test("rejects malformed input", () => {
    expect(decodeControl("not json")).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dot/1" }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "", ack: -1 }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "d", acks: { "0": 1 } }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "d", acks: { "01": 1 } }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "pong", ts: 1 }))).toBeNull(); // server→client only
    expect(decodeControl(JSON.stringify({ t: "ack", seq: "1" }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "auth.refresh", token: "" }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "ping", ts: Number.POSITIVE_INFINITY }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "ping", ts: "1" }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dot/1", device: "é".repeat(2_100) }))).toBeNull();
  });

  test("accepts ping, ack (with and without leg), auth.refresh", () => {
    expect(decodeControl(JSON.stringify({ t: "ping", ts: 123 }))).toEqual({ t: "ping", ts: 123 });
    expect(decodeControl(JSON.stringify({ t: "ack", seq: 9 }))).toEqual({ t: "ack", seq: 9 });
    expect(decodeControl(JSON.stringify({ t: "ack", seq: 9, leg: 2 }))).toEqual({ t: "ack", seq: 9, leg: 2 });
    expect(decodeControl(JSON.stringify({ t: "auth.refresh", token: "tok" }))).toEqual({
      t: "auth.refresh",
      token: "tok",
    });
  });

  test("encode/decode round trip", () => {
    const frame = { t: "ack", seq: 3, leg: 1 } as const;
    expect(decodeControl(encodeControl(frame))).toEqual(frame);
  });
});

describe("ReplayRing", () => {
  test("replays after ack and prunes on ack", () => {
    const ring = new ReplayRing();
    for (let seq = 1; seq <= 5; seq += 1) ring.push(seq, dataFrame(1, seq));
    expect(ring.replayAfter(2).length).toBe(3);
    ring.ackTo(4);
    expect(ring.size).toBe(1);
    expect(ring.replayAfter(0).length).toBe(1);
    expect(ring.lastEnqueued).toBe(5);
  });

  test("idempotent pushes are dropped", () => {
    const ring = new ReplayRing();
    ring.push(1, dataFrame(1, 1));
    ring.push(1, dataFrame(1, 1));
    expect(ring.size).toBe(1);
  });

  test("coversGap proves coverage exactly", () => {
    const ring = new ReplayRing();
    for (let seq = 1; seq <= 3; seq += 1) ring.push(seq, dataFrame(1, seq));
    expect(ring.coversGap(0)).toBe(true);
    expect(ring.coversGap(3)).toBe(true);
    expect(ring.coversGap(4)).toBe(false); // receiver claims the future
    ring.ackTo(2);
    expect(ring.coversGap(1)).toBe(false); // seq 2 pruned, gap not covered
    expect(ring.coversGap(2)).toBe(true);
  });

  test("frame-count overflow evicts and marks broken", () => {
    const ring = new ReplayRing();
    for (let seq = 1; seq <= RING_MAX_FRAMES + 1; seq += 1) ring.push(seq, dataFrame(1, seq));
    expect(ring.broken).toBe(true);
    expect(ring.size).toBe(RING_MAX_FRAMES);
    expect(ring.coversGap(0)).toBe(false);
  });

  test("byte overflow evicts and marks broken", () => {
    const ring = new ReplayRing();
    const big = dataFrame(1, 0, 600 * 1024);
    for (let seq = 1; seq <= 4; seq += 1) {
      const frame = big.slice(0);
      new DataView(frame).setBigUint64(6, BigInt(seq));
      ring.push(seq, frame);
    }
    expect(ring.broken).toBe(true);
    expect(ring.size * 600 * 1024).toBeLessThanOrEqual(RING_MAX_BYTES);
  });

  test("pendingEntries carries seqs for spill", () => {
    const ring = new ReplayRing();
    ring.push(10, dataFrame(1, 10));
    ring.push(11, dataFrame(1, 11));
    ring.ackTo(10);
    expect(ring.pendingEntries().map((entry) => entry.seq)).toEqual([11]);
  });
});

describe("resume keys and identifiers", () => {
  test("mintResumeKey is url-safe and unique", () => {
    const a = mintResumeKey();
    const b = mintResumeKey();
    expect(a).not.toBe(b);
    expect(a).toMatch(/^[A-Za-z0-9_-]{40,}$/);
  });

  test("sha256Base64 is deterministic", async () => {
    expect(await sha256Base64("abc")).toBe(await sha256Base64("abc"));
    expect(await sha256Base64("abc")).not.toBe(await sha256Base64("abd"));
  });

  test("validOpaqueId accepts device-id shapes and rejects junk", () => {
    expect(validOpaqueId("4A52829D-6427-599F-A166-4058881D2DF4")).toBe(true);
    expect(validOpaqueId("mac:dev.cmux.dotx")).toBe(true);
    expect(validOpaqueId("")).toBe(false);
    expect(validOpaqueId("a".repeat(200))).toBe(false);
    expect(validOpaqueId("bad id with spaces")).toBe(false);
  });

  test("relay object names are isolated by account and app identity", () => {
    expect(relayObjectName("user-a", "identity-1")).toBe("relay:user:user-a:relay:identity-1");
    expect(relayObjectName("user-a", "identity-1")).not.toBe(relayObjectName("user-b", "identity-1"));
    expect(relayObjectName("user-a", "identity-1")).not.toBe(relayObjectName("user-a", "identity-2"));
  });
});
