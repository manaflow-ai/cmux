import { expect, test } from "bun:test";
import { parseEnvelope, parsePeer, randomSessionCode, randomToken } from "../src/protocol";

test("parsePeer accepts complete peer metadata", () => {
  expect(parsePeer({ peerID: "p1", displayName: "Peer", color: "#123456" })).toEqual({
    peerID: "p1",
    displayName: "Peer",
    color: "#123456",
  });
});

test("parseEnvelope rejects malformed or oversized frames", () => {
  expect(parseEnvelope("{")).toBeNull();
  expect(parseEnvelope(JSON.stringify({ nope: true }))).toBeNull();
  expect(parseEnvelope("x".repeat(1024 * 1024 + 1))).toBeNull();
  expect(parseEnvelope(JSON.stringify({ type: "document.update", payloadBase64: "abc" }))).toEqual({
    type: "document.update",
    payloadBase64: "abc",
  });
});

test("invite material has expected shape", () => {
  expect(randomSessionCode()).toMatch(/^[A-Z0-9]{4}-[A-Z0-9]{4}$/);
  expect(randomToken()).toMatch(/^[0-9a-f]{36}$/);
});
