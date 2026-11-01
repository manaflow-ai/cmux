import { describe, expect, test } from "bun:test";
import {
  MAX_ARTIFACT_BYTES,
  MAX_EVENT_PAYLOAD_BYTES,
  artifactDigest,
  assertArtifactDigest,
  decodeRunCursor,
  encodeRunCursor,
  isArtifactDigest,
  jsonByteLength,
  leaseIsValid,
  verifyArtifactDigest,
} from "../services/runs/model";

describe("durable Run wire primitives", () => {
  test("round-trips a replay cursor without losing the event id", () => {
    const encoded = encodeRunCursor({ sequence: 42, eventId: "evt-42" });
    expect(encoded).not.toContain("evt-42");
    expect(decodeRunCursor(encoded)).toEqual({ sequence: 42, eventId: "evt-42" });
  });

  test("rejects malformed cursors so a client must request a fresh snapshot", () => {
    expect(decodeRunCursor("not-base64-json")).toBeNull();
    expect(decodeRunCursor(Buffer.from(JSON.stringify({ sequence: 1.5 }), "utf8").toString("base64url"))).toBeNull();
    expect(decodeRunCursor(Buffer.from(JSON.stringify({ sequence: 1, eventId: 7 }), "utf8").toString("base64url"))).toBeNull();
    expect(decodeRunCursor(null)).toBeNull();
  });

  test("accepts only content-addressed SHA-256 artifact references", () => {
    const bytes = new TextEncoder().encode("run artifact\n");
    const digest = artifactDigest(bytes);
    expect(isArtifactDigest(digest)).toBe(true);
    expect(verifyArtifactDigest(bytes, digest)).toBe(true);
    expect(verifyArtifactDigest(bytes, digest.toUpperCase())).toBe(true);
    expect(verifyArtifactDigest(new TextEncoder().encode("tampered\n"), digest)).toBe(false);
    expect(isArtifactDigest("sha256:short")).toBe(false);
    expect(isArtifactDigest(`sha256:${"g".repeat(64)}`)).toBe(false);
    expect(() => assertArtifactDigest(new TextEncoder().encode("tampered\n"), digest)).toThrow("artifact digest mismatch");
  });

  test("uses a strict expiration boundary for lease fencing", () => {
    const now = Date.parse("2026-10-16T20:00:00.000Z");
    expect(leaseIsValid(new Date(now + 1), now)).toBe(true);
    expect(leaseIsValid(new Date(now), now)).toBe(false);
    expect(leaseIsValid(new Date(now - 1), now)).toBe(false);
    expect(leaseIsValid(null, now)).toBe(false);
  });

  test("publishes bounded payload and artifact limits for adapters", () => {
    expect(MAX_EVENT_PAYLOAD_BYTES).toBe(256 * 1024);
    expect(MAX_ARTIFACT_BYTES).toBe(512 * 1024 * 1024);
    expect(jsonByteLength({ output: "hello" })).toBe(Buffer.byteLength('{"output":"hello"}', "utf8"));
  });
});
