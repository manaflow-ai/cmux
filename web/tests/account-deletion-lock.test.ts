import { describe, expect, test } from "bun:test";

import type { cloudDb } from "../db/client";
import {
  ACCOUNT_ANALYTICS_FORWARD_LEASE_MS,
  isBlockingAccountDeletionTombstone,
  withAccountDeletionAnalyticsForwardLease,
} from "../services/account/deletionLock";

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

  test("starts an analytics forward lease after advisory locks are acquired", async () => {
    let now = new Date("2026-07-09T10:00:00.000Z");
    let insertedExpiresAt: Date | undefined;
    const tx = {
      execute: async () => {
        now = new Date("2026-07-09T10:00:45.000Z");
      },
      select: () => ({
        from: () => ({ where: async () => [] }),
      }),
      delete: () => ({ where: async () => undefined }),
      insert: () => ({
        values: async (values: readonly { readonly expiresAt: Date }[]) => {
          insertedExpiresAt = values[0]?.expiresAt;
        },
      }),
    };
    const db = {
      transaction: async (operation: (transaction: typeof tx) => Promise<unknown>) =>
        await operation(tx),
    } as unknown as ReturnType<typeof cloudDb>;

    await withAccountDeletionAnalyticsForwardLease(
      db,
      ["user-after-lock"],
      async () => "forwarded",
      () => true,
      () => now,
    );

    expect(insertedExpiresAt?.getTime()).toBe(
      now.getTime() + ACCOUNT_ANALYTICS_FORWARD_LEASE_MS,
    );
  });
});
