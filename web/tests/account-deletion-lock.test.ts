import { describe, expect, test } from "bun:test";

import { isBlockingAccountDeletionTombstone } from "../services/account/deletionLock";

describe("account deletion tombstone lock", () => {
  test("blocks fresh nonterminal deletion tombstones", () => {
    const now = new Date("2026-07-09T10:00:00.000Z");

    expect(isBlockingAccountDeletionTombstone({
      status: "pending",
      updatedAt: new Date("2026-07-09T09:55:00.000Z"),
    }, now)).toBe(true);
  });

  test("does not block stale pending deletion tombstones", () => {
    const now = new Date("2026-07-09T10:00:00.000Z");

    expect(isBlockingAccountDeletionTombstone({
      status: "pending",
      updatedAt: new Date("2026-07-09T09:44:59.999Z"),
    }, now)).toBe(false);
  });

  test("keeps terminal deletion tombstones blocking after the lease", () => {
    const now = new Date("2026-07-09T10:00:00.000Z");

    expect(isBlockingAccountDeletionTombstone({
      status: "completed",
      updatedAt: new Date("2026-07-09T09:00:00.000Z"),
    }, now)).toBe(true);
    expect(isBlockingAccountDeletionTombstone({
      status: "cleanup_incomplete",
      updatedAt: new Date("2026-07-09T09:00:00.000Z"),
    }, now)).toBe(true);
  });
});
