import { describe, expect, test } from "bun:test";
import {
  DATA_HEADER_BYTES,
  decodeClientControl,
  decodeDataFrame,
  decodeServerControl,
  encodeDataFrame,
  MAX_DATA_PAYLOAD_BYTES,
} from "../src/protocol";

describe("data frames", () => {
  test("roundtrips session id and payload", () => {
    const payload = new Uint8Array([0, 1, 2, 250, 255]);
    const frame = encodeDataFrame(0xdeadbeef, payload);
    const decoded = decodeDataFrame(frame.buffer as ArrayBuffer);
    expect(decoded).not.toBeNull();
    expect(decoded!.sessionId).toBe(0xdeadbeef);
    expect(Array.from(decoded!.payload)).toEqual(Array.from(payload));
  });

  test("rejects a truncated header", () => {
    expect(decodeDataFrame(new Uint8Array([1, 0, 0]).buffer as ArrayBuffer)).toBeNull();
  });

  test("rejects an unknown frame type", () => {
    const frame = encodeDataFrame(1, new Uint8Array([1]));
    frame[0] = 9;
    expect(decodeDataFrame(frame.buffer as ArrayBuffer)).toBeNull();
  });

  test("rejects an oversized frame", () => {
    const frame = new Uint8Array(DATA_HEADER_BYTES + MAX_DATA_PAYLOAD_BYTES + 1);
    frame[0] = 1;
    expect(decodeDataFrame(frame.buffer as ArrayBuffer)).toBeNull();
  });

  test("empty payload is legal", () => {
    const decoded = decodeDataFrame(encodeDataFrame(7, new Uint8Array(0)).buffer as ArrayBuffer);
    expect(decoded!.sessionId).toBe(7);
    expect(decoded!.payload.byteLength).toBe(0);
  });
});

describe("control message schemas", () => {
  test("accepts a refresh", () => {
    expect(decodeClientControl({ t: "refresh", accessToken: "eyJ.a.b" })._tag).toBe("Right");
  });

  test("rejects unknown client messages and extra fields", () => {
    expect(decodeClientControl({ t: "welcome" })._tag).toBe("Left");
    expect(decodeClientControl({ t: "refresh", accessToken: "x", extra: 1 })._tag).toBe("Left");
    expect(decodeClientControl({ t: "refresh", accessToken: "" })._tag).toBe("Left");
    expect(decodeClientControl({ t: "refresh", ticket: "v1.a.b" })._tag).toBe("Left");
  });

  test("accepts every server message shape", () => {
    const messages = [
      { t: "welcome", v: 1, role: "client", sessionId: 3, deadline: 123.0, hostPresent: true },
      { t: "peer_joined", sessionId: 1, deviceId: "d" },
      { t: "peer_left", sessionId: 1, reason: "closed" },
      { t: "refresh_ack", deadline: 5 },
      { t: "bye", code: "expired", reason: "" },
    ];
    for (const message of messages) {
      expect(decodeServerControl(message)._tag).toBe("Right");
    }
  });

  test("rejects a welcome with a bad role", () => {
    expect(
      decodeServerControl({ t: "welcome", v: 1, role: "admin", sessionId: 3, deadline: 1, hostPresent: false })._tag,
    ).toBe("Left");
  });
});
