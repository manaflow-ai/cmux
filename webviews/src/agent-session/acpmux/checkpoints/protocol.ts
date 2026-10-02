export const CHECKPOINT_OPS = {
  create: "git.checkpoint.create",
  get: "git.checkpoint.get",
  list: "git.checkpoint.list",
  pin: "git.checkpoint.pin",
  unpin: "git.checkpoint.unpin",
} as const;

export type CheckpointTarget = {
  cwd: string;
  sessionId?: string;
  hostKind?: "local" | "cloud";
  [key: string]: unknown;
};
export type Checkpoint = {
  checkpoint_id: string;
  repository_id: string;
  worktree_id: string;
  ref: string;
  object_id: string;
  revision: string;
  complete: boolean;
  skipped: Array<{ path: string; code: string; bytes?: number }>;
  skipped_total: number;
  created_at: string;
  expires_at: string | null;
  base: { head: string | null; branch: string | null; detached: boolean };
  coverage: { included: number; omitted: number; unavailable: number };
  included: { tracked: number; untracked: number; staged_entries: number };
  bytes: { logical: number; newly_stored: number };
  limits: { max_bytes: number; max_files: number; max_untracked_file_bytes: number };
  pins: Array<{ pin_id: string; reason: string }>;
};
export type CheckpointCandidate = { path: string; bytes: number; eligible: boolean; reason?: string };
export type CheckpointLimits = { max_bytes: number; max_files: number; max_untracked_file_bytes: number };
export type CheckpointList = {
  repository_id: string;
  worktree_id: string;
  checkpoints: Checkpoint[];
  next_cursor: string | null;
  candidates?: CheckpointCandidate[];
  limits: CheckpointLimits;
};
export type MutationEnvelope<T> = { result: T; revision: string; replayed: boolean };
export type CheckpointCatalog = { catalog_sha256: string; operations: string[] };
export type CheckpointCapability = { checkpoints: boolean };

function object(value: unknown, message = "Invalid checkpoint response."): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(message);
  return value as Record<string, unknown>;
}
function text(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) throw new Error(`Invalid checkpoint ${field}.`);
  return value;
}
function nonnegative(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)
    throw new Error(`Invalid checkpoint ${field}.`);
  return value;
}
function revision(value: unknown): string {
  if (typeof value !== "string" || !/^(?:0|[1-9]\d*)$/.test(value)) throw new Error("Invalid checkpoint revision.");
  return value;
}
function limits(value: unknown): CheckpointLimits {
  const raw = object(value);
  return {
    max_bytes: nonnegative(raw.max_bytes, "limits"),
    max_files: nonnegative(raw.max_files, "limits"),
    max_untracked_file_bytes: nonnegative(raw.max_untracked_file_bytes, "limits"),
  };
}
function checkpoint(value: unknown): Checkpoint {
  const raw = object(value);
  const base = object(raw.base);
  const coverage = object(raw.coverage);
  const included = object(raw.included);
  const bytes = object(raw.bytes);
  if (
    typeof raw.complete !== "boolean" ||
    (raw.expires_at !== null && typeof raw.expires_at !== "string") ||
    typeof base.detached !== "boolean"
  )
    throw new Error("Invalid checkpoint response.");
  if (base.head !== null && typeof base.head !== "string") throw new Error("Invalid checkpoint base.");
  if (base.branch !== null && typeof base.branch !== "string") throw new Error("Invalid checkpoint base.");
  if (!Array.isArray(raw.skipped) || raw.skipped.length > nonnegative(raw.skipped_total, "skipped_total"))
    throw new Error("Invalid checkpoint skip accounting.");
  const skipped = raw.skipped.map((entry) => {
    const item = object(entry);
    const result = { path: text(item.path, "skip"), code: text(item.code, "skip") } as {
      path: string;
      code: string;
      bytes?: number;
    };
    if (item.bytes !== undefined) result.bytes = nonnegative(item.bytes, "skip bytes");
    return result;
  });
  return {
    checkpoint_id: text(raw.checkpoint_id, "id"),
    repository_id: text(raw.repository_id, "repository"),
    worktree_id: text(raw.worktree_id, "worktree"),
    ref: text(raw.ref, "ref"),
    object_id: text(raw.object_id, "object"),
    revision: revision(raw.revision),
    complete: raw.complete,
    skipped,
    skipped_total: nonnegative(raw.skipped_total, "skipped_total"),
    created_at: text(raw.created_at, "created_at"),
    expires_at: raw.expires_at,
    base: { head: base.head as string | null, branch: base.branch as string | null, detached: base.detached },
    coverage: {
      included: nonnegative(coverage.included, "coverage"),
      omitted: nonnegative(coverage.omitted, "coverage"),
      unavailable: nonnegative(coverage.unavailable, "coverage"),
    },
    included: {
      tracked: nonnegative(included.tracked, "included"),
      untracked: nonnegative(included.untracked, "included"),
      staged_entries: nonnegative(included.staged_entries, "included"),
    },
    bytes: { logical: nonnegative(bytes.logical, "bytes"), newly_stored: nonnegative(bytes.newly_stored, "bytes") },
    limits: limits(raw.limits),
    pins: Array.isArray(raw.pins)
      ? raw.pins.map((pin) => {
          const item = object(pin);
          return { pin_id: text(item.pin_id, "pin"), reason: text(item.reason, "pin") };
        })
      : (() => {
          throw new Error("Invalid checkpoint pins.");
        })(),
  };
}

/** v1.1 capability negotiation is an injectable native call, not a runtime catalog read. */
export function supportsCheckpointCapability(value: unknown): boolean {
  return !!value && typeof value === "object" && (value as { checkpoints?: unknown }).checkpoints === true;
}
/** Kept as a pure parser helper for generated catalog consumers; UI gating uses capabilities(). */
export function supportsCheckpointCatalog(value: unknown, expectedSha?: string): boolean {
  const raw = value as { catalog_sha256?: unknown; operations?: unknown } | null;
  return (
    !!raw &&
    typeof raw.catalog_sha256 === "string" &&
    (!expectedSha || raw.catalog_sha256 === expectedSha) &&
    Array.isArray(raw.operations) &&
    Object.values(CHECKPOINT_OPS).every((operation) => (raw.operations as unknown[]).includes(operation))
  );
}

export function checkpointRecord(value: unknown): Checkpoint {
  return checkpoint(value);
}
export function checkpointList(value: unknown): CheckpointList {
  const raw = object(value);
  if (!Array.isArray(raw.checkpoints) || (raw.next_cursor !== null && typeof raw.next_cursor !== "string"))
    throw new Error("Invalid checkpoint list.");
  const result: CheckpointList = {
    repository_id: text(raw.repository_id, "repository"),
    worktree_id: text(raw.worktree_id, "worktree"),
    checkpoints: raw.checkpoints.map(checkpoint),
    next_cursor: raw.next_cursor as string | null,
    limits: limits(raw.limits),
  };
  if (raw.candidates !== undefined) {
    if (!Array.isArray(raw.candidates)) throw new Error("Invalid checkpoint candidates.");
    result.candidates = raw.candidates.map((candidate) => {
      const item = object(candidate);
      if (typeof item.eligible !== "boolean") throw new Error("Invalid checkpoint candidate.");
      const value = {
        path: text(item.path, "candidate"),
        bytes: nonnegative(item.bytes, "candidate bytes"),
        eligible: item.eligible,
      } as CheckpointCandidate;
      if (item.reason !== undefined) value.reason = text(item.reason, "candidate reason");
      return value;
    });
  }
  return result;
}
export function mutationEnvelope<T>(value: unknown): MutationEnvelope<T> {
  const raw = object(value);
  if (typeof raw.replayed !== "boolean") throw new Error("Invalid checkpoint mutation.");
  return { result: raw.result as T, revision: revision(raw.revision), replayed: raw.replayed };
}

export type CheckpointErrorCode =
  | "resource.not_found"
  | "idempotency.conflict"
  | "operation.unsupported"
  | "revision.conflict"
  | "mutation.indeterminate"
  | "validation.invalid"
  | "operation.failed";
export class CheckpointRpcError extends Error {
  readonly code: CheckpointErrorCode | string;
  readonly reason?: string;
  readonly details?: unknown;
  readonly retryable?: boolean;
  readonly origin?: "native" | "session_host";
  readonly uncertain: boolean;
  constructor(
    input:
      | { code?: unknown; userMessage?: unknown; details?: unknown; retryable?: unknown; origin?: unknown }
      | CheckpointErrorCode,
    message?: string,
    reason?: string,
  ) {
    const reply =
      typeof input === "string"
        ? { code: input, userMessage: message, details: undefined, retryable: undefined, origin: undefined }
        : input;
    super(
      typeof reply.userMessage === "string" ? reply.userMessage : (message ?? String(reply.code ?? "Request failed")),
    );
    this.name = "CheckpointRpcError";
    this.code = typeof reply.code === "string" ? reply.code : "operation.failed";
    this.reason =
      reason ??
      (reply.details &&
      typeof reply.details === "object" &&
      typeof (reply.details as { reason?: unknown }).reason === "string"
        ? (reply.details as { reason: string }).reason
        : undefined);
    this.details = reply.details;
    this.retryable = typeof reply.retryable === "boolean" ? reply.retryable : undefined;
    this.origin = reply.origin === "native" || reply.origin === "session_host" ? reply.origin : undefined;
    this.uncertain = this.origin === "native" ? this.code === "native.timed_out" : this.origin === undefined;
  }
}
