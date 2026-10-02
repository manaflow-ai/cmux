export const CHECKPOINT_OPS = {
  create: "git.checkpoint.create",
  get: "git.checkpoint.get",
  list: "git.checkpoint.list",
  pin: "git.checkpoint.pin",
  unpin: "git.checkpoint.unpin",
} as const;

export type CheckpointTarget = { cwd: string; sessionId?: string; [key: string]: unknown };
export type Checkpoint = {
  checkpoint_id: string; repository_id: string; worktree_id: string; ref: string; object_id: string; revision: string;
  complete: boolean; skipped: Array<{ path: string; code: string; bytes?: number }>; skipped_total: number;
  created_at: string; expires_at: string | null;
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
  repository_id: string; worktree_id: string; checkpoints: Checkpoint[]; next_cursor: string | null;
  candidates?: CheckpointCandidate[]; limits: CheckpointLimits;
};
export type MutationEnvelope<T> = { result: T; revision: string; replayed: boolean };
export type CheckpointCatalog = { catalog_sha256: string; operations: string[] };

export function supportsCheckpointCatalog(_catalog: unknown, _expectedSha?: string): boolean { return false; }
export function checkpointRecord(value: unknown): Checkpoint { return value as Checkpoint; }
export function checkpointList(value: unknown): CheckpointList { return value as CheckpointList; }
export function mutationEnvelope<T>(value: unknown): MutationEnvelope<T> { return value as MutationEnvelope<T>; }

export type CheckpointErrorCode =
  | "resource.not_found" | "idempotency.conflict" | "operation.unsupported" | "revision.conflict"
  | "mutation.indeterminate" | "validation.invalid" | "operation.failed";
export class CheckpointRpcError extends Error {
  readonly code: CheckpointErrorCode;
  readonly reason?: string;
  constructor(code: CheckpointErrorCode, message = code, reason?: string) { super(message); this.code = code; this.reason = reason; }
}
