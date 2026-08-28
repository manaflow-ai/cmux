import { describe, expect, test } from "bun:test";

import {
  DATA_HEADER_BYTES,
  MAX_DATA_FRAME_BYTES,
  RING_MAX_FRAMES,
  ReplayRing,
  decodeControl,
  decodeDataHeader,
  encodeControl,
  hostKey,
  isAuthorizedPhoneLeg,
  mintResumeKey,
  phoneKey,
  rewriteLegId,
  sha256Base64,
  spillKey,
  streamId,
  validOpaqueId,
} from "../src/dorProtocol";

function frame(legId: number, seq: number, payloadBytes = 4): ArrayBuffer {
  const buffer = new ArrayBuffer(DATA_HEADER_BYTES + payloadBytes);
  const view = new DataView(buffer);
  view.setUint8(0, 1);
  view.setUint8(1, 1);
  view.setUint32(2, legId);
  view.setBigUint64(6, BigInt(seq));
  return buffer;
}

describe("data frame header", () => {
  test("round-trips and validates", () => {
    const header = decodeDataHeader(frame(7, 42));
    expect(header).toEqual({ version: 1, kind: 1, legId: 7, seq: 42 });
  });

  test("rejects malformed input", () => {
    expect(decodeDataHeader(new ArrayBuffer(4))).toBeNull();
    expect(decodeDataHeader(frame(1, 0))).toBeNull(); // seq must be >= 1
    const wrongVersion = frame(1, 1);
    new DataView(wrongVersion).setUint8(0, 9);
    expect(decodeDataHeader(wrongVersion)).toBeNull();
    expect(decodeDataHeader(new ArrayBuffer(MAX_DATA_FRAME_BYTES + 1))).toBeNull();
  });

  test("rewriteLegId stamps in place", () => {
    const data = frame(0, 5);
    rewriteLegId(data, 31337);
    expect(decodeDataHeader(data)?.legId).toBe(31337);
  });
});

describe("control frames", () => {
  test("hello with host acks map round-trips", () => {
    const decoded = decodeControl(
      JSON.stringify({ t: "hello", proto: "dor/1", device: "mac-1", acks: { "3": 9, "5": 0 } }),
    );
    expect(decoded).toEqual({ t: "hello", proto: "dor/1", device: "mac-1", acks: { "3": 9, "5": 0 } });
  });

  test("rejects unknown types, bad seqs, oversized tokens", () => {
    expect(decodeControl(JSON.stringify({ t: "hello.ack", legId: 1 }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "ack", seq: -1 }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "ack", seq: 1.5 }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "auth.refresh", token: "x".repeat(9000) }))).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "dor/1", device: "d", acks: { "0": 1 } }))).toBeNull();
    expect(decodeControl("not json")).toBeNull();
    expect(decodeControl(JSON.stringify({ t: "hello", proto: "😀".repeat(2000), device: "d" }))).toBeNull();
  });

  test("encodeControl emits parseable relay frames", () => {
    const encoded = encodeControl({ t: "ackup", seq: 12, leg: 4 });
    expect(JSON.parse(encoded)).toEqual({ t: "ackup", seq: 12, leg: 4 });
  });
});

describe("ReplayRing", () => {
  test("replays the exact gap and proves coverage", () => {
    const ring = new ReplayRing();
    for (let seq = 1; seq <= 5; seq += 1) ring.push(seq, frame(1, seq));
    expect(ring.coversGap(3)).toBe(true);
    expect(ring.replayAfter(3).length).toBe(2);
    expect(ring.coversGap(5)).toBe(true);
    expect(ring.replayAfter(5).length).toBe(0);
    expect(ring.coversGap(9)).toBe(false); // receiver claims the future
  });

  test("acks prune, coverage still provable at the pruned floor", () => {
    const ring = new ReplayRing();
    for (let seq = 1; seq <= 5; seq += 1) ring.push(seq, frame(1, seq));
    ring.ackTo(3);
    expect(ring.size).toBe(2);
    expect(ring.coversGap(3)).toBe(true);
    expect(ring.coversGap(2)).toBe(false); // 3 was pruned: gap not provable
  });

  test("duplicate sender resends are idempotent", () => {
    const ring = new ReplayRing();
    expect(ring.push(1, frame(1, 1))).toBe(true);
    expect(ring.push(1, frame(1, 1))).toBe(true);
    expect(ring.push(2, frame(1, 2))).toBe(true);
    expect(ring.push(1, frame(1, 1))).toBe(true);
    expect(ring.size).toBe(2);
    expect(ring.lastEnqueued).toBe(2);
  });

  test("rejects sequence gaps and future acknowledgements", () => {
    const ring = new ReplayRing();
    expect(ring.push(1, frame(1, 1))).toBe(true);
    expect(ring.push(3, frame(1, 3))).toBe(false);
    expect(ring.lastEnqueued).toBe(1);
    ring.ackTo(99);
    expect(ring.size).toBe(1);
  });

  test("overflow marks broken and fails coverage forever", () => {
    const ring = new ReplayRing();
    for (let seq = 1; seq <= RING_MAX_FRAMES + 1; seq += 1) ring.push(seq, frame(1, seq));
    expect(ring.broken).toBe(true);
    expect(ring.coversGap(0)).toBe(false);
    expect(ring.coversGap(RING_MAX_FRAMES + 1)).toBe(false);
  });
});

describe("addressing + keys", () => {
  test("stream ids are namespaced per endpoint", () => {
    expect(streamId(hostKey("mac-a"), phoneKey(4))).toBe("h:mac-a<p:4");
    expect(spillKey(phoneKey(4), hostKey("mac-a"), 7)).toBe("spill:p:4:h:mac-a:0000000000000007");
  });

  test("opaque ids accept device-id shapes and reject junk", () => {
    expect(validOpaqueId("4A52829D-6427-599F-A166-4058881D2DF4")).toBe(true);
    expect(validOpaqueId("dev.cmux.mac:instance_1")).toBe(true);
    expect(validOpaqueId("")).toBe(false);
    expect(validOpaqueId("has space")).toBe(false);
    expect(validOpaqueId("x".repeat(200))).toBe(false);
  });

  test("only a phone leg bound to the target Mac is a valid destination", () => {
    expect(isAuthorizedPhoneLeg({ role: "phone", mac: "mac-a" }, "mac-a")).toBe(true);
    expect(isAuthorizedPhoneLeg({ role: "phone", mac: "mac-b" }, "mac-a")).toBe(false);
    expect(isAuthorizedPhoneLeg({ role: "host", mac: "mac-a" }, "mac-a")).toBe(false);
    expect(isAuthorizedPhoneLeg(null, "mac-a")).toBe(false);
  });

  test("resume keys are unique and hash deterministically", async () => {
    const a = mintResumeKey();
    const b = mintResumeKey();
    expect(a).not.toBe(b);
    expect(await sha256Base64(a)).toBe(await sha256Base64(a));
    expect(await sha256Base64(a)).not.toBe(await sha256Base64(b));
  });
});
