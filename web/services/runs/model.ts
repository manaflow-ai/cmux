import { createHash, randomUUID } from "node:crypto";

export const RUN_STATUSES = ["queued", "running", "cancelling", "succeeded", "failed", "cancelled"] as const;
export type RunStatus = (typeof RUN_STATUSES)[number];

export const ATTEMPT_STATUSES = ["queued", "leased", "running", "succeeded", "failed", "cancelled", "expired"] as const;
export type AttemptStatus = (typeof ATTEMPT_STATUSES)[number];

export type RunEventKind =
  | "run.created"
  | "attempt.queued"
  | "attempt.started"
  | "attempt.heartbeat"
  | "attempt.output"
  | "attempt.artifact"
  | "attempt.succeeded"
  | "attempt.failed"
  | "run.cancel_requested"
  | "run.completed";

export const RUN_EVENT_KINDS = ["run.created", "attempt.queued", "attempt.started", "attempt.heartbeat", "attempt.output", "attempt.artifact", "attempt.succeeded", "attempt.failed", "run.cancel_requested", "run.completed"] as const;

export function isRunEventKind(value: unknown): value is RunEventKind {
  return typeof value === "string" && (RUN_EVENT_KINDS as readonly string[]).includes(value);
}

export type ImmutableRunSource = {
  readonly repository?: string;
  readonly ref?: string;
  readonly commit?: string;
  readonly archiveDigest?: string;
};

export type RunCursor = { readonly sequence: number; readonly eventId?: string };

export const DEFAULT_LEASE_TTL_MS = 60_000;
/** Completed cloud terminals stay available for a bounded attach window. */
export const DEFAULT_TERMINAL_RETENTION_MS = 10 * 60_000;
/** Attach tickets are deliberately shorter lived than the retained terminal. */
export const DEFAULT_ATTACH_TICKET_TTL_MS = 2 * 60_000;
/** Reaper workers fence one another while provider teardown is in flight. */
export const TERMINAL_CLEANUP_LEASE_MS = 60_000;
export const MAX_EVENT_PAYLOAD_BYTES = 256 * 1024;
export const MAX_ARTIFACT_BYTES = 512 * 1024 * 1024;
export const ALLOWED_RUN_RECIPES = ["parallel-review"] as const;
export type RunRecipe = (typeof ALLOWED_RUN_RECIPES)[number];

export function newId(): string {
  return randomUUID();
}

export function encodeRunCursor(cursor: RunCursor): string {
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64url");
}

export function decodeRunCursor(value: string | null | undefined): RunCursor | null {
  if (!value) return null;
  try {
    const parsed: unknown = JSON.parse(Buffer.from(value, "base64url").toString("utf8"));
    if (!parsed || typeof parsed !== "object") return null;
    const sequence = (parsed as { sequence?: unknown }).sequence;
    const eventId = (parsed as { eventId?: unknown }).eventId;
    if (!Number.isSafeInteger(sequence) || (eventId !== undefined && typeof eventId !== "string")) return null;
    return { sequence: sequence as number, ...(eventId ? { eventId } : {}) };
  } catch {
    return null;
  }
}

export function artifactDigest(bytes: Uint8Array): string {
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

export function isArtifactDigest(value: unknown): value is string {
  return typeof value === "string" && /^sha256:[0-9a-f]{64}$/i.test(value);
}

export function verifyArtifactDigest(bytes: Uint8Array, expected: string): boolean {
  return isArtifactDigest(expected) && artifactDigest(bytes).toLowerCase() === expected.toLowerCase();
}

export function assertArtifactDigest(bytes: Uint8Array, expected: string): void {
  if (!verifyArtifactDigest(bytes, expected)) throw new Error("artifact digest mismatch");
}

export function leaseIsValid(leaseUntil: Date | null | undefined, now = Date.now()): boolean {
  return leaseUntil !== null && leaseUntil !== undefined && leaseUntil.getTime() > now;
}

export function jsonByteLength(value: unknown): number {
  return Buffer.byteLength(JSON.stringify(value), "utf8");
}

export function boundedLimit(value: string | null | undefined, fallback = 100): number {
  const parsed = value === null || value === undefined || value === "" ? fallback : Number(value);
  return Number.isSafeInteger(parsed) ? Math.max(1, Math.min(parsed, 500)) : fallback;
}

