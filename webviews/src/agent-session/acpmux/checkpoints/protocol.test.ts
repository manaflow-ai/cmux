import { describe, expect, test } from "bun:test";
import { checkpointList, mutationEnvelope, supportsCheckpointCapability, type Checkpoint } from "./protocol";

const checkpoint: Checkpoint = {
  checkpoint_id: "cp-1",
  repository_id: "repo-1",
  worktree_id: "worktree-1",
  ref: "refs/cmux/checkpoints/worktree-1/cp-1",
  object_id: "0123456789abcdef0123456789abcdef01234567",
  revision: "1",
  complete: false,
  skipped: [{ path: "notes.bin", code: "over_limit", bytes: 10000001 }],
  skipped_total: 1,
  created_at: "2026-10-02T00:00:00.000Z",
  expires_at: null,
  base: { head: "0123456789abcdef0123456789abcdef01234567", branch: "main", detached: false },
  coverage: { included: 2, omitted: 1, unavailable: 0 },
  included: { tracked: 2, untracked: 0, staged_entries: 1 },
  bytes: { logical: 10, newly_stored: 10 },
  limits: { max_bytes: 100, max_files: 10, max_untracked_file_bytes: 10000000 },
  pins: [],
};

describe("checkpoint protocol", () => {
  test("requires a true checkpoint capability from the native connection", () => {
    expect(supportsCheckpointCapability({ checkpoints: true })).toBe(true);
    expect(supportsCheckpointCapability({ checkpoints: false })).toBe(false);
    expect(supportsCheckpointCapability(undefined)).toBe(false);
    expect(supportsCheckpointCapability({ checkpoints: "true" })).toBe(false);
  });

  test("accepts decimal revisions and rejects malformed mutation envelopes", () => {
    expect(mutationEnvelope({ result: checkpoint, revision: "42", replayed: true }).revision).toBe("42");
    expect(() => mutationEnvelope({ result: checkpoint, revision: 42, replayed: false })).toThrow();
    expect(() => mutationEnvelope({ result: checkpoint, revision: "01", replayed: false })).toThrow();
  });

  test("rejects a checkpoint missing bounded skip accounting", () => {
    const malformed = { ...checkpoint, skipped_total: undefined };
    expect(() =>
      checkpointList({ repository_id: "repo-1", worktree_id: "worktree-1", checkpoints: [malformed] }),
    ).toThrow();
  });
});
