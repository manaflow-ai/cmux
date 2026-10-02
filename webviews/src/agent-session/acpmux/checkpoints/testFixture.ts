import type { Checkpoint, CheckpointList, CheckpointTarget } from "./protocol";
import type { CheckpointPersistence } from "./client";

export const target: CheckpointTarget = { cwd: "/repo", sessionId: "session-1" };
export const checkpoint: Checkpoint = {
  checkpoint_id: "cp-1",
  repository_id: "repo-1",
  worktree_id: "worktree-1",
  ref: "refs/cmux/checkpoints/worktree-1/cp-1",
  object_id: "0123456789abcdef0123456789abcdef01234567",
  revision: "1",
  complete: true,
  skipped: [],
  skipped_total: 0,
  created_at: "2026-10-02T00:00:00.000Z",
  expires_at: null,
  base: { head: null, branch: null, detached: true },
  coverage: { included: 1, omitted: 0, unavailable: 0 },
  included: { tracked: 1, untracked: 0, staged_entries: 0 },
  bytes: { logical: 2, newly_stored: 2 },
  limits: { max_bytes: 100, max_files: 10, max_untracked_file_bytes: 10000000 },
  pins: [],
};
export const list: CheckpointList = {
  repository_id: "repo-1",
  worktree_id: "worktree-1",
  checkpoints: [],
  next_cursor: null,
  candidates: [{ path: "draft.txt", bytes: 5, eligible: true }],
  limits: { max_bytes: 100, max_files: 10, max_untracked_file_bytes: 10000000 },
};

export class MemoryPersistence implements CheckpointPersistence {
  values = new Map<string, unknown>();
  async get(key: string) {
    return this.values.get(key);
  }
  async set(key: string, value: unknown) {
    this.values.set(key, value);
  }
  async delete(key: string) {
    this.values.delete(key);
  }
}

