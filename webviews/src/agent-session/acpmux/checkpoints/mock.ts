import {
  CHECKPOINT_CAPABILITY_OP,
  CHECKPOINT_OPS,
  type Checkpoint,
  type CheckpointLimits,
  type MutationEnvelope,
} from "./protocol";

/** What a checkpoint records of a session's repository (mockGit.ts answers it, and throws outside one). */
export type MockCheckpointRepository = { root: string; head: string; branch: string; changedFiles: number };

const LIMITS: CheckpointLimits = { max_bytes: 134_217_728, max_files: 1_000, max_untracked_file_bytes: 10_000_000 };

function failure(code: string, reason?: string): never {
  throw Object.assign(new Error(reason ?? code), { code, ...(reason ? { details: { reason } } : {}) });
}

/**
 * The mock daemon's checkpoint owner, in the session host's shapes (protocol.ts): it reports support, lists,
 * creates, reads and pins records per repository, and replays a mutation's first reply for its idempotency key.
 * Never used by a live daemon.
 */
export class MockCheckpoints {
  private records = new Map<string, Checkpoint[]>();
  private replies = new Map<string, MutationEnvelope<Checkpoint>>();
  private made = 0;
  private revision = 0;
  constructor(private repository: (sessionId: string) => MockCheckpointRepository) {}

  answer(sessionId: string, method: string, params: Record<string, unknown>): unknown {
    if (method === CHECKPOINT_CAPABILITY_OP) return { checkpoints: true };
    const repo = this.repository(sessionId);
    const kept = this.records.get(repo.root) ?? [];
    switch (method) {
      case CHECKPOINT_OPS.list:
        return {
          ...this.ids(repo),
          checkpoints: structuredClone(kept),
          next_cursor: null,
          ...(params.include_candidates === true ? { candidates: [] } : {}),
          limits: LIMITS,
        };
      case CHECKPOINT_OPS.get: {
        const found =
          typeof params.idempotency_key === "string"
            ? this.replies.get(this.replyKey(repo, CHECKPOINT_OPS.create, params.idempotency_key))?.result
            : kept.find((record) => record.checkpoint_id === params.checkpoint_id);
        return structuredClone(found ?? failure("resource.not_found"));
      }
      case CHECKPOINT_OPS.create:
        return this.mutate(repo, method, params, () => {
          const record = this.capture(repo);
          this.records.set(repo.root, [record, ...kept]);
          return record;
        });
      case CHECKPOINT_OPS.pin:
      case CHECKPOINT_OPS.unpin:
        return this.mutate(repo, method, params, () => {
          const record = kept.find((entry) => entry.checkpoint_id === params.checkpoint_id);
          if (!record) failure("resource.not_found");
          const others = record.pins.filter((pin) => pin.pin_id !== params.pin_id);
          record.pins =
            method === CHECKPOINT_OPS.pin
              ? [...others, { pin_id: String(params.pin_id), reason: String(params.reason ?? "manual") }]
              : others;
          record.revision = String(Number(record.revision) + 1);
          return record;
        });
      default:
        return failure("operation.unsupported");
    }
  }

  private ids(repo: MockCheckpointRepository) {
    return { repository_id: `mock-repository:${repo.root}`, worktree_id: `mock-worktree:${repo.root}` };
  }

  private replyKey(repo: MockCheckpointRepository, method: string, key: unknown): string {
    return `${repo.root}\u0000${method}\u0000${String(key)}`;
  }

  private mutate(
    repo: MockCheckpointRepository,
    method: string,
    params: Record<string, unknown>,
    write: () => Checkpoint,
  ): MutationEnvelope<Checkpoint> {
    if (typeof params.idempotency_key !== "string" || !params.idempotency_key) failure("validation.invalid");
    const id = this.replyKey(repo, method, params.idempotency_key);
    const first = this.replies.get(id);
    if (first) return { ...structuredClone(first), replayed: true };
    this.revision += 1;
    const reply = { result: structuredClone(write()), revision: String(this.revision), replayed: false };
    this.replies.set(id, reply);
    return structuredClone(reply);
  }

  private capture(repo: MockCheckpointRepository): Checkpoint {
    this.made += 1;
    const checkpointId = `mock-checkpoint-${this.made}`;
    const created = new Date();
    return {
      checkpoint_id: checkpointId,
      ...this.ids(repo),
      ref: `refs/cmux/checkpoints/${checkpointId}`,
      object_id: this.made.toString(16).padStart(40, "0"),
      revision: "1",
      complete: true,
      skipped: [],
      skipped_total: 0,
      created_at: created.toISOString(),
      expires_at: new Date(created.getTime() + 7 * 86_400_000).toISOString(),
      base: { head: repo.head, branch: repo.branch, detached: false },
      coverage: { included: repo.changedFiles, omitted: 0, unavailable: 0 },
      included: { tracked: repo.changedFiles, untracked: 0, staged_entries: 0 },
      bytes: { logical: 0, newly_stored: 0 },
      limits: LIMITS,
      pins: [],
    };
  }
}
