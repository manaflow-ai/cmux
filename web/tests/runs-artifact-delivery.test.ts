import { createHash } from "node:crypto";
import { describe, expect, test } from "bun:test";
import { canonicalRunArtifact, runArtifactResponse, RunArtifactIntegrityError } from "../services/runs/legacy/artifactContent";

const digest = (bytes: Uint8Array) => "sha256:" + createHash("sha256").update(bytes).digest("hex");

describe("Run receipt artifact delivery", () => {
  test("canonical JSON retains the same digest across JSONB-style key reordering", () => {
    const first = { z: { beta: 2, alpha: [{ y: 3, x: 1 }] }, a: 4 };
    const reordered = { a: 4, z: { alpha: [{ x: 1, y: 3 }], beta: 2 } };
    const expected = '{"a":4,"z":{"alpha":[{"x":1,"y":3}],"beta":2}}';
    const left = canonicalRunArtifact(first);
    const right = canonicalRunArtifact(reordered);
    expect(left.body).toBe(expected);
    expect(right).toEqual(left);
    expect(left.digest).toBe(digest(Buffer.from(expected, "utf8")));
    expect(left.sizeBytes).toBe(Buffer.byteLength(expected, "utf8"));
  });

  test("serves the exact stored representation after executor teardown", async () => {
    const artifact = canonicalRunArtifact({ receipt: "completed", inputs: ["a", "b"], status: 0 });
    const response = runArtifactResponse({ ...artifact, payload: { status: 0, inputs: ["a", "b"], receipt: "completed" } });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    const bytes = Buffer.from(await response.arrayBuffer());
    expect(bytes.toString("utf8")).toBe(artifact.body);
    expect(digest(bytes)).toBe(artifact.digest);
    expect(bytes.byteLength).toBe(artifact.sizeBytes);
    expect(response.headers.get("content-digest")).toBe(
      "sha-256=:" + createHash("sha256").update(bytes).digest("base64") + ":",
    );
  });

  test("refuses legacy or corrupted JSONB digest and byte-count claims", () => {
    const payload = { z: 1, a: 2 };
    const canonical = canonicalRunArtifact(payload);
    const legacyDigest = digest(Buffer.from(JSON.stringify(payload)));
    expect(legacyDigest).not.toBe(canonical.digest);
    for (const metadata of [
      { ...canonical, digest: legacyDigest },
      { ...canonical, digest: "sha256:" + "0".repeat(64) },
      { ...canonical, sizeBytes: canonical.sizeBytes + 1 },
    ]) {
      expect(() => runArtifactResponse({ payload, digest: metadata.digest, sizeBytes: metadata.sizeBytes }))
        .toThrow(RunArtifactIntegrityError);
    }
  });

  test("bounds JSON receipts before publication", () => {
    const huge = { value: "x".repeat(8 * 1024 * 1024) };
    expect(() => canonicalRunArtifact(huge)).toThrow(RunArtifactIntegrityError);
  });
});
