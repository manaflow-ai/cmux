import { createHash } from "node:crypto";

/** Run artifacts are small JSON receipts. Binary exports have a separate owner. */
export const MAX_RUN_RECEIPT_JSON_BYTES = 8 * 1024 * 1024;

export class RunArtifactIntegrityError extends Error {
  constructor() {
    super("Run artifact content is unavailable or has invalid integrity metadata");
    this.name = "RunArtifactIntegrityError";
  }
}

export interface StoredRunArtifactContent {
  readonly payload: Record<string, unknown>;
  readonly digest: string;
  readonly sizeBytes: number;
}

/**
 * Serialize JSON to one deterministic byte representation before hashing and after JSONB reads.
 * JSONB reorders object keys; using insertion-order JSON.stringify for a digest breaks downloads.
 * The initial round trip also applies JSON's ordinary toJSON/undefined/number normalization.
 */
export function canonicalRunArtifact(payload: Record<string, unknown>): {
  readonly body: string;
  readonly digest: string;
  readonly sizeBytes: number;
} {
  let body: string;
  try {
    const normalized = JSON.stringify(payload);
    if (!normalized || Buffer.byteLength(normalized, "utf8") > MAX_RUN_RECEIPT_JSON_BYTES)
      throw new RunArtifactIntegrityError();
    body = JSON.stringify(JSON.parse(normalized), (_key, value: unknown) =>
      value && typeof value === "object" && !Array.isArray(value)
        ? Object.fromEntries(Object.entries(value).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0))
        : value,
    );
  } catch {
    throw new RunArtifactIntegrityError();
  }
  const sizeBytes = Buffer.byteLength(body, "utf8");
  if (sizeBytes > MAX_RUN_RECEIPT_JSON_BYTES) throw new RunArtifactIntegrityError();
  return { body, digest: "sha256:" + createHash("sha256").update(body, "utf8").digest("hex"), sizeBytes };
}

/** Verify persisted metadata against the exact bytes returned to the caller. */
export function runArtifactResponse(artifact: StoredRunArtifactContent): Response {
  const encoded = canonicalRunArtifact(artifact.payload);
  if (artifact.digest !== encoded.digest || artifact.sizeBytes !== encoded.sizeBytes)
    throw new RunArtifactIntegrityError();
  const base64 = createHash("sha256").update(encoded.body, "utf8").digest("base64");
  return new Response(encoded.body, {
    status: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "content-length": String(encoded.sizeBytes),
      "content-digest": `sha-256=:${base64}:`,
      "cache-control": "private, no-store",
      "x-content-type-options": "nosniff",
    },
  });
}
