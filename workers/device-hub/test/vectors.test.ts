import { describe, expect, it } from "vitest";
import vectors from "../../../schemas/device-hub/test-vectors.json";
import { canonicalJson, decisionMessage, requestDigest, validateRequest } from "../src/approvals";
import { canonicalRequest, lowSHex, sha256Hex, verifyDeviceSignature } from "../src/crypto";

// The shared vectors (schemas/device-hub/test-vectors.json) the Swift and Rust
// clients test against too: the hub must read every one the same way.

const enc = new TextEncoder();

describe("shared device hub test vectors", () => {
  const key = vectors.key.signingKey;

  it("signs requests over the same canonical string, high-S included", async () => {
    for (const v of vectors.requestSigning) {
      expect(await canonicalRequest(v.method, v.pathAndQuery, v.ts, enc.encode(v.body))).toBe(v.canonical);
      expect(v.body ? await sha256Hex(v.body) : "").toBe(v.bodySha256);
      expect(await verifyDeviceSignature(key, v.sig, v.canonical)).toBe(true);
      expect(await verifyDeviceSignature(key, v.sigHighS, v.canonical)).toBe(true);
      expect(lowSHex(v.sig)).toBe(v.lowSHex);
      expect(lowSHex(v.sigHighS)).toBe(v.lowSHex);
    }
  });

  it("writes canonical JSON byte for byte", async () => {
    for (const v of vectors.canonicalJson) {
      expect(canonicalJson(v.value)).toBe(v.canonical);
      expect(await sha256Hex(v.canonical)).toBe(v.sha256);
    }
  });

  it("takes the vector request's digest", async () => {
    const request = vectors.approvalRequest.request as Record<string, unknown>;
    expect(await requestDigest(request)).toBe(request.digest);
    // Its times are fixed in 2026; check it as if it were being asked then.
    const v = await validateRequest(request, (request.created_ms as number) + 1000);
    expect(v.digest).toBe(request.digest);
  });

  it("verifies every decision signature", async () => {
    const digest = vectors.approvalRequest.request.digest;
    for (const d of vectors.approvalDecisions) {
      expect(decisionMessage(digest, d.decision as "once")).toBe(d.message);
      expect(await verifyDeviceSignature(key, d.sig, d.message)).toBe(true);
      expect(await verifyDeviceSignature(key, d.sigHighS, d.message)).toBe(true);
      // A signature over one decision never carries another.
      const other = d.decision === "deny" ? "once" : "deny";
      expect(await verifyDeviceSignature(key, d.sig, decisionMessage(digest, other))).toBe(false);
    }
  });
});
