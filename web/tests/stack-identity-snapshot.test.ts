import { beforeEach, describe, expect, test } from "bun:test";

import {
  deleteIdentitySnapshot,
  identitySnapshotTtlMs,
  readIdentitySnapshot,
  writeIdentitySnapshot,
} from "../services/auth/identitySnapshot";
import type { AuthedUser } from "../services/vms/auth";

type Row = Record<string, unknown>;

/**
 * The narrow slice of the Drizzle query builder the snapshot store uses.
 * Faking it keeps these cases free of Postgres; `devices-route.test.ts`
 * exercises the same store against the real database.
 */
function fakeDb(initial: Row[] = []) {
  const state = { rows: [...initial], inserted: [] as Row[], deleted: [] as unknown[], failReads: false };
  const db = {
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => {
            if (state.failReads) throw new Error("database unavailable");
            return state.rows;
          },
        }),
      }),
    }),
    insert: () => ({
      values: (values: Row) => ({
        onConflictDoUpdate: async () => {
          state.inserted.push(values);
          state.rows = [values];
        },
      }),
    }),
    delete: () => ({
      where: async (condition: unknown) => {
        state.deleted.push(condition);
        state.rows = [];
      },
    }),
  };
  return { db: db as never, state };
}

const user: AuthedUser = {
  id: "user-1",
  displayName: "Test User",
  primaryEmail: "test@example.com",
  billingCustomerType: "team",
  billingTeamId: "team-a",
  selectedTeamId: "team-a",
  teams: [
    { id: "team-a", displayName: "Team A", billingPlanId: "pro", billingSeats: 3 },
    { id: "team-b", displayName: null, billingPlanId: null, billingSeats: null },
  ],
  teamIds: ["team-a", "team-b"],
  userBillingPlanId: null,
  billingPlanId: "pro",
  billingSeats: 3,
};

function storedRow(refreshedAt: Date): Row {
  return {
    userId: user.id,
    displayName: user.displayName,
    primaryEmail: user.primaryEmail,
    selectedTeamId: user.selectedTeamId,
    billingCustomerType: user.billingCustomerType,
    billingTeamId: user.billingTeamId,
    userBillingPlanId: user.userBillingPlanId,
    billingPlanId: user.billingPlanId,
    billingSeats: user.billingSeats,
    teams: user.teams,
    refreshedAt,
  };
}

describe("identity snapshot store", () => {
  test("a fresh row rebuilds the authed user, teams and all", async () => {
    const { db } = fakeDb([storedRow(new Date(Date.now() - 1_000))]);
    const read = await readIdentitySnapshot(user.id, 60_000, db);
    expect(read?.user).toEqual(user);
    expect(read?.ageMs).toBeGreaterThanOrEqual(1_000);
  });

  test("a row older than the max age does not answer", async () => {
    const { db } = fakeDb([storedRow(new Date(Date.now() - 120_000))]);
    expect(await readIdentitySnapshot(user.id, 60_000, db)).toBeNull();
  });

  test("a row stamped in the future does not answer", async () => {
    const { db } = fakeDb([storedRow(new Date(Date.now() + 120_000))]);
    expect(await readIdentitySnapshot(user.id, 60_000, db)).toBeNull();
  });

  test("a max age of zero disables the snapshot entirely", async () => {
    const { db } = fakeDb([storedRow(new Date())]);
    expect(await readIdentitySnapshot(user.id, 0, db)).toBeNull();
  });

  test("a database failure reads as no snapshot rather than throwing", async () => {
    const { db, state } = fakeDb([storedRow(new Date())]);
    state.failReads = true;
    expect(await readIdentitySnapshot(user.id, 60_000, db)).toBeNull();
  });

  test("only a complete team list is stored", async () => {
    const { db, state } = fakeDb();
    await writeIdentitySnapshot(user, { completeTeamList: false }, db);
    expect(state.inserted).toHaveLength(0);
    await writeIdentitySnapshot(user, { completeTeamList: true }, db);
    expect(state.inserted).toHaveLength(1);
    expect(state.inserted[0]?.teams).toEqual(user.teams);
  });

  test("a stored snapshot round-trips to the same authed user", async () => {
    const { db } = fakeDb();
    await writeIdentitySnapshot(user, { completeTeamList: true }, db);
    const read = await readIdentitySnapshot(user.id, 60_000, db);
    expect(read?.user).toEqual(user);
  });

  test("deleting removes the row", async () => {
    const { db, state } = fakeDb([storedRow(new Date())]);
    await deleteIdentitySnapshot(user.id, db);
    expect(state.rows).toHaveLength(0);
    expect(await readIdentitySnapshot(user.id, 60_000, db)).toBeNull();
  });
});

describe("identitySnapshotTtlMs", () => {
  test("defaults to the Stack access token lifetime", () => {
    expect(identitySnapshotTtlMs(undefined)).toBe(3_600_000);
    expect(identitySnapshotTtlMs("   ")).toBe(3_600_000);
  });

  test("honors an explicit override, including zero to disable", () => {
    expect(identitySnapshotTtlMs("90000")).toBe(90_000);
    expect(identitySnapshotTtlMs("0")).toBe(0);
  });

  test("ignores values that are not whole non-negative milliseconds", () => {
    expect(identitySnapshotTtlMs("-5")).toBe(3_600_000);
    expect(identitySnapshotTtlMs("abc")).toBe(3_600_000);
    expect(identitySnapshotTtlMs("1.5")).toBe(3_600_000);
  });
});
