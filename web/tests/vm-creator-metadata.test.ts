import { describe, expect, test } from "bun:test";
import { getTableName, type SQL } from "drizzle-orm";
import { PgDialect } from "drizzle-orm/pg-core";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { currentCloudDbQuerySignal } from "../db/queryScope";
import { stackIdentitySnapshots } from "../db/schema";
import {
  VmRepository,
  type CloudVmRow,
  type VmRepositoryShape,
} from "../services/vms/repository";
import {
  creatorFor,
  creatorUserIds,
  readCreatorDisplayNames,
  readCreatorNames,
  withCallerName,
} from "../services/vms/creators";
import { listUserVms } from "../services/vms/workflows";

/**
 * `/api/vm` lists by owner team, so on a team every member sees every member's
 * machines, and until this change the payload carried no author at all. These
 * cases pin the pieces that turn a row's account id into something a person can
 * read in the Cloud sidebar.
 */

function creatorRow(overrides: Partial<CloudVmRow> = {}): CloudVmRow {
  const now = new Date();
  return {
    id: "00000000-0000-4000-8000-0000000000aa",
    userId: "user-creator",
    billingTeamId: "team-shared",
    billingPlanId: "free",
    provider: "freestyle",
    providerVmId: "vm-creator",
    displayName: null,
    slug: "brave-blue-otter",
    imageId: "snapshot-test",
    imageVersion: null,
    status: "running",
    idempotencyKey: "creator-metadata",
    createdAt: now,
    updatedAt: now,
    destroyedAt: null,
    failureCode: null,
    failureMessage: null,
    providerMetadata: {},
    ownerTeamId: "team-shared",
    coderouterPoolId: null,
    ...overrides,
  } as CloudVmRow;
}

type CreatorDb = NonNullable<Parameters<typeof readCreatorDisplayNames>[1]["db"]>;

type CapturedQuery = {
  calls: number;
  projection?: Record<string, unknown>;
  table?: unknown;
  where?: SQL;
};

/**
 * The three calls `readCreatorDisplayNames` makes, recording each argument.
 *
 * A fake that ignores its arguments would pass just as happily against a read
 * of the wrong table, a filter on the wrong column, no filter at all (every
 * identity snapshot in the database), or a `select()` with no projection
 * (pulling the stored email into process memory). Those are the properties
 * this module's design note argues about, so the tests have to hold them.
 */
function fakeSelectDb(
  rows: readonly { userId: string; displayName: string | null }[],
  captured: CapturedQuery,
) {
  return {
    select: (projection: Record<string, unknown>) => {
      captured.calls += 1;
      captured.projection = projection;
      return {
        from: (table: unknown) => {
          captured.table = table;
          return {
            where: (condition: SQL) => {
              captured.where = condition;
              return Promise.resolve([...rows]);
            },
          };
        },
      };
    },
  } as unknown as CreatorDb;
}

function throwingSelectDb(captured: CapturedQuery = { calls: 0 }) {
  return {
    select: () => {
      captured.calls += 1;
      throw new Error("identity snapshots unavailable");
    },
  } as unknown as CreatorDb;
}

describe("cloud machine creator metadata", () => {
  test("creatorUserIds dedupes accounts and drops rows with no author", () => {
    const ids = creatorUserIds([
      { createdByUserId: "user-a" },
      { createdByUserId: "user-b" },
      { createdByUserId: "user-a" },
      { createdByUserId: "  " },
      { createdByUserId: null },
    ]);
    expect(ids.sort()).toEqual(["user-a", "user-b"]);
  });

  test("creatorUserIds returns nothing when no row has an author", () => {
    expect(creatorUserIds([{ createdByUserId: null }])).toEqual([]);
  });

  test("readCreatorDisplayNames maps accounts to names and skips blank ones", async () => {
    const captured: CapturedQuery = { calls: 0 };
    const names = await readCreatorDisplayNames(
      ["user-a", "user-b", "user-c"],
      {
        teamId: "team-shared",
        db: fakeSelectDb([
          { userId: "user-a", displayName: "Ada Lovelace" },
          { userId: "user-b", displayName: "   " },
          { userId: "user-c", displayName: null },
        ], captured),
      },
    );
    expect(names.get("user-a")).toBe("Ada Lovelace");
    expect(names.has("user-b")).toBe(false);
    expect(names.has("user-c")).toBe(false);
  });

  test("readCreatorDisplayNames reads only the names of the accounts it was asked about", async () => {
    const captured: CapturedQuery = { calls: 0 };
    await readCreatorDisplayNames(["user-a", "user-b"], {
      teamId: "team-shared",
      db: fakeSelectDb([], captured),
    });
    // Only the display name, so the snapshot's stored email never leaves the
    // database, and only this table.
    expect(Object.keys(captured.projection ?? {}).sort()).toEqual(["displayName", "userId"]);
    expect(getTableName(captured.table as never)).toBe(getTableName(stackIdentitySnapshots));
    // Filtered to the accounts in this caller's own list. Without the filter
    // the map would be every identity snapshot in the database.
    const query = new PgDialect().sqlToQuery(captured.where as SQL);
    expect(query.sql).toContain("user_id");
    expect(query.params.slice(0, 2)).toEqual(["user-a", "user-b"]);
    // And to accounts that are still members of the owning team, so someone
    // who left stops publishing their name to it.
    expect(query.sql).toContain('"teams" @> ');
    expect(query.params[2]).toBe(JSON.stringify([{ id: "team-shared" }]));
  });

  test("readCreatorDisplayNames does not query for an empty account list", async () => {
    // The throwing fake alone cannot show this: without the guard the call
    // would enter the try, throw, and be swallowed into the same empty map.
    const captured: CapturedQuery = { calls: 0 };
    const names = await readCreatorDisplayNames([], {
      teamId: "team-shared",
      db: throwingSelectDb(captured),
    });
    expect(names.size).toBe(0);
    expect(captured.calls).toBe(0);
  });

  test("readCreatorDisplayNames reads nothing without an owning team", async () => {
    const captured: CapturedQuery = { calls: 0 };
    const names = await readCreatorDisplayNames(["user-a"], {
      teamId: null,
      db: throwingSelectDb(captured),
    });
    expect(names.size).toBe(0);
    expect(captured.calls).toBe(0);
  });

  test("readCreatorDisplayNames degrades to no names when the read fails", async () => {
    // A machine list without authors is what shipped before this, so a broken
    // snapshot read must never take the whole list down with it.
    const failures: unknown[] = [];
    const names = await readCreatorDisplayNames(["user-a"], {
      teamId: "team-shared",
      db: throwingSelectDb(),
      onFailure: (error) => failures.push(error),
    });
    expect(names.size).toBe(0);
    // Reported, so an empty map from a broken read is not mistaken for a
    // team where nobody has set a name.
    expect(failures).toHaveLength(1);
  });

  test("readCreatorDisplayNames keeps the empty-map fallback when reporting throws", async () => {
    const names = await readCreatorDisplayNames(["user-a"], {
      teamId: "team-shared",
      db: throwingSelectDb(),
      onFailure: () => {
        throw new Error("span closed");
      },
    });
    expect(names.size).toBe(0);
  });

  test("readCreatorDisplayNames gives up on a stalled read and cancels it", async () => {
    // A stalled snapshot read must not hold the machine list. The query runs
    // under a signal the driver cancels on, and the wait ends at the deadline
    // even if the cancellation itself never settles the query.
    let querySignal: AbortSignal | undefined;
    const stalledDb = {
      select: () => ({
        from: () => ({
          where: () => {
            querySignal = currentCloudDbQuerySignal();
            return new Promise(() => undefined);
          },
        }),
      }),
    } as unknown as CreatorDb;
    const names = await readCreatorDisplayNames(["user-a"], {
      teamId: "team-shared",
      db: stalledDb,
      timeoutMs: 10,
    });
    expect(names.size).toBe(0);
    expect(querySignal?.aborted).toBe(true);
  });

  test("creatorFor publishes the account id with its name", () => {
    const creator = creatorFor(
      { createdByUserId: "user-a" },
      new Map([["user-a", "Ada Lovelace"]]),
    );
    expect(creator).toEqual({ userId: "user-a", displayName: "Ada Lovelace" });
  });

  test("creatorFor reports an unnamed account rather than showing its id as a name", () => {
    const creator = creatorFor({ createdByUserId: "user-a" }, new Map());
    expect(creator).toEqual({ userId: "user-a", displayName: null });
  });

  test("creatorFor returns nothing rather than a nameless author for a blank id", () => {
    // `cloud_vms.user_id` is NOT NULL and has been since the table was created,
    // so this is the shape of a partially built entry, not of an old row.
    expect(creatorFor({ createdByUserId: null }, new Map())).toBeNull();
    expect(creatorFor({ createdByUserId: "  " }, new Map())).toBeNull();
    expect(creatorFor({}, new Map())).toBeNull();
  });

  test("withCallerName prefers the session's own name over the snapshot's", () => {
    // A lease revoke deletes the caller's snapshot row. Their own machines
    // should not go anonymous on them while the rest of the team still reads
    // fine, and the session's copy is the fresher one either way.
    const names = withCallerName(
      new Map([["user-a", "Stale Name"]]),
      { id: "user-a", displayName: "Ada Lovelace" },
    );
    expect(names.get("user-a")).toBe("Ada Lovelace");
  });

  test("withCallerName leaves the map alone when the session has no name", () => {
    const names = withCallerName(new Map(), { id: "user-a", displayName: "  " });
    expect(names.size).toBe(0);
  });

  test("readCreatorNames never queries for the caller's own name", async () => {
    // The session already has it, so a team list of only the caller's
    // machines costs no snapshot read.
    const captured: CapturedQuery = { calls: 0 };
    const names = await readCreatorNames({
      userIds: ["user-a"],
      teamId: "team-shared",
      caller: { id: "user-a", displayName: "Ada Lovelace" },
      db: throwingSelectDb(captured),
    });
    expect(names.get("user-a")).toBe("Ada Lovelace");
    expect(captured.calls).toBe(0);
  });

  test("readCreatorNames still reads the caller's snapshot when the session has no name", async () => {
    const captured: CapturedQuery = { calls: 0 };
    await readCreatorNames({
      userIds: ["user-a"],
      teamId: "team-shared",
      caller: { id: "user-a", displayName: "  " },
      db: fakeSelectDb([], captured),
    });
    expect(captured.calls).toBe(1);
  });

  test("listUserVms carries each machine's owning team", async () => {
    const repo = {
      listUserVms: () => Effect.succeed([creatorRow()]),
    } as unknown as VmRepositoryShape;
    const entries = await Effect.runPromise(
      listUserVms("user-creator", "team-shared").pipe(
        Effect.provide(Layer.succeed(VmRepository, repo)),
      ),
    );
    expect(entries.map((entry) => entry.ownerTeamId)).toEqual(["team-shared"]);
  });

  test("listUserVms carries the account that made each machine", async () => {
    const rows = [
      creatorRow({ providerVmId: "vm-one", userId: "user-a" }),
      creatorRow({
        id: "00000000-0000-4000-8000-0000000000ab",
        providerVmId: "vm-two",
        userId: "user-b",
      }),
    ];
    const repo = {
      listUserVms: () => Effect.succeed(rows),
    } as unknown as VmRepositoryShape;
    const entries = await Effect.runPromise(
      listUserVms("user-a", "team-shared").pipe(
        Effect.provide(Layer.succeed(VmRepository, repo)),
      ),
    );
    expect(entries.map((entry) => entry.createdByUserId)).toEqual([
      "user-a",
      "user-b",
    ]);
  });
});
