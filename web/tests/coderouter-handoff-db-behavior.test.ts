import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import {
  accountDeletionUserHash,
} from "../services/account/deletionLock";
import {
  CODEROUTER_HANDOFF_LEASE_TTL_MS,
  CodeRouterHandoffEntitlementDenied,
  exchangeCoderouterHandoffLease,
  handoffLeaseHash,
  issueCoderouterHandoffLease,
  routeTokenHash,
  revokeRouteTokensForTeam,
} from "../services/coderouter/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

type HandoffFixture = {
  readonly teamId: string;
  readonly userId: string;
  readonly now: Date;
};

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 8 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

function database(): Sql {
  if (!sql) throw new Error("test database not initialized");
  return sql;
}

function fixture(): HandoffFixture {
  return {
    teamId: `handoff-team-${randomUUID()}`,
    userId: `handoff-user-${randomUUID()}`,
    now: new Date(),
  };
}

async function withFixture<T>(run: (input: HandoffFixture) => Promise<T>): Promise<T> {
  const db = database();
  const input = fixture();
  try {
    return await run(input);
  } finally {
    await db`delete from coderouter_route_tokens where team_id = ${input.teamId}`;
    await db`delete from coderouter_handoff_leases where team_id = ${input.teamId}`;
  }
}

describe("CodeRouter handoff lease database behavior", () => {
  dbTest("stores only lease and route-token hashes", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      const issued = await issueCoderouterHandoffLease(teamId, userId, now);
      const db = database();

      const [leaseColumns] = await db<Array<{ names: string[] }>>`
        select array_agg(column_name order by ordinal_position) as names
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'coderouter_handoff_leases'
      `;
      expect(leaseColumns?.names).toContain("lease_hash");
      expect(leaseColumns?.names).not.toContain("lease");

      const [constraints] = await db<Array<{ names: string[] }>>`
        select array_agg(constraint_name order by constraint_name) as names
        from information_schema.table_constraints
        where table_schema = 'public'
          and table_name = 'coderouter_handoff_leases'
      `;
      expect(constraints?.names).toContain(
        "coderouter_handoff_leases_hash_format_check",
      );
      expect(constraints?.names).toContain(
        "coderouter_handoff_leases_expiry_check",
      );

      const [stored] = await db<Array<{
        leaseHash: string;
        consumedAt: Date | null;
      }>>`
        select lease_hash as "leaseHash", consumed_at as "consumedAt"
        from coderouter_handoff_leases
        where team_id = ${teamId}
      `;
      expect(stored?.leaseHash).toBe(handoffLeaseHash(issued.lease));
      expect(stored?.leaseHash).not.toBe(issued.lease);
      expect(stored?.consumedAt).toBeNull();

      const exchanged = await exchangeCoderouterHandoffLease(issued.lease, now);
      expect(exchanged).not.toBeNull();
      const routeRows = await db<Array<{
        tokenHash: string;
        label: string;
      }>>`
        select token_hash as "tokenHash", label
        from coderouter_route_tokens
        where team_id = ${teamId}
      `;
      expect(routeRows).toHaveLength(1);
      expect(routeRows[0]?.tokenHash).toBe(routeTokenHash(exchanged!.token));
      expect(routeRows[0]?.label).toBe("native-handoff");

      const routeColumns = await db<Array<{ name: string }>>`
        select column_name as name
        from information_schema.columns
        where table_schema = 'public'
          and table_name = 'coderouter_route_tokens'
      `;
      expect(routeColumns.map((column) => column.name)).not.toContain("token");
    });
  });

  dbTest("permits one atomic concurrent exchange", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      const issued = await issueCoderouterHandoffLease(teamId, userId, now);
      const results = await Promise.all([
        exchangeCoderouterHandoffLease(issued.lease, new Date(now)),
        exchangeCoderouterHandoffLease(issued.lease, new Date(now)),
      ]);
      const successfulExchange = results.find((result) => result !== null);
      expect(successfulExchange).not.toBeNull();
      expect(results.filter((result) => result === null)).toHaveLength(1);

      const [consumed] = await database()<Array<{ consumedAt: Date | null }>>`
        select consumed_at as "consumedAt"
        from coderouter_handoff_leases
        where team_id = ${teamId}
      `;
      expect(consumed?.consumedAt).not.toBeNull();
    });
  });

  dbTest("keeps identity and entitlement failures non-consuming", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      const issued = await issueCoderouterHandoffLease(teamId, userId, now);
      const delayedNow = new Date(now.getTime() + 1_000);
      expect(
        await exchangeCoderouterHandoffLease(
          issued.lease,
          now,
          { stackUserId: "different-user" },
        ),
      ).toBeNull();

      const [afterIdentityFailure] = await database()<Array<{
        consumedAt: Date | null;
      }>>`
        select consumed_at as "consumedAt"
        from coderouter_handoff_leases
        where team_id = ${teamId}
      `;
      expect(afterIdentityFailure?.consumedAt).toBeNull();

      expect(
        await exchangeCoderouterHandoffLease(
          issued.lease,
          delayedNow,
          {},
          async () => false,
        ),
      ).toBeNull();
      expect(
        await exchangeCoderouterHandoffLease(
          issued.lease,
          delayedNow,
          {},
          async () => true,
        ),
      ).not.toBeNull();
    });
  });

  dbTest("rechecks entitlement in the issuance transaction", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      let transactionDbSeen = false;
      const issued = await issueCoderouterHandoffLease(
        teamId,
        userId,
        now,
        async (identity, tx) => {
          transactionDbSeen = typeof tx.select === "function";
          return identity.teamId === teamId && identity.stackUserId === userId;
        },
      );
      expect(transactionDbSeen).toBe(true);

      await expect(issueCoderouterHandoffLease(
        teamId,
        userId,
        now,
        async () => false,
      )).rejects.toBeInstanceOf(CodeRouterHandoffEntitlementDenied);

      const hashes = await database()<Array<{ leaseHash: string }>>`
        select lease_hash as "leaseHash"
        from coderouter_handoff_leases
        where team_id = ${teamId}
      `;
      expect(hashes.map((row) => row.leaseHash)).toEqual([
        handoffLeaseHash(issued.lease),
      ]);
    });
  });

  dbTest("blocks mint and exchange after account deletion tombstone", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      const issued = await issueCoderouterHandoffLease(teamId, userId, now);
      await database()`
        insert into account_deletion_tombstones (
          user_id_hash,
          user_id,
          status,
          updated_at
        ) values (
          ${accountDeletionUserHash(userId)},
          ${userId},
          'pending',
          ${now}
        )
      `;
      try {
        await expect(
          issueCoderouterHandoffLease(teamId, userId, now),
        ).rejects.toThrow();
        expect(
          await exchangeCoderouterHandoffLease(issued.lease, now),
        ).toBeNull();
      } finally {
        await database()`
          delete from account_deletion_tombstones
          where user_id_hash = ${accountDeletionUserHash(userId)}
        `;
      }
    });
  });

  dbTest("does not retain a lease when route-token creation fails", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      const issued = await issueCoderouterHandoffLease(teamId, userId, now);
      await database()`
        alter table coderouter_route_tokens
        add constraint coderouter_handoff_test_route_token_failure
        check (label <> 'native-handoff')
      `;
      try {
        await expect(
          exchangeCoderouterHandoffLease(issued.lease, now),
        ).rejects.toThrow();
        const [row] = await database()<Array<{ consumedAt: Date | null }>>`
          select consumed_at as "consumedAt"
          from coderouter_handoff_leases
          where team_id = ${teamId}
        `;
        expect(row?.consumedAt).toBeNull();
      } finally {
        await database()`
          alter table coderouter_route_tokens
          drop constraint coderouter_handoff_test_route_token_failure
        `;
      }
    });
  });

  dbTest("rejects expired leases without consuming them", async () => {
    await withFixture(async ({ teamId, userId }) => {
      const issued = await issueCoderouterHandoffLease(
        teamId,
        userId,
        new Date(Date.now() - CODEROUTER_HANDOFF_LEASE_TTL_MS - 60 * 60_000),
      );
      expect(
        await exchangeCoderouterHandoffLease(
          issued.lease,
          new Date(),
        ),
      ).toBeNull();

      const [row] = await database()<Array<{ consumedAt: Date | null }>>`
        select consumed_at as "consumedAt"
        from coderouter_handoff_leases
        where team_id = ${teamId}
      `;
      expect(row?.consumedAt).toBeNull();
    });
  });

  dbTest("invalidates pending leases during billing revocation", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      const pending = await issueCoderouterHandoffLease(teamId, userId, now);
      await revokeRouteTokensForTeam(teamId, now);
      expect(
        await exchangeCoderouterHandoffLease(pending.lease, now),
      ).toBeNull();

      const race = await issueCoderouterHandoffLease(
        teamId,
        userId,
        new Date(now.getTime() + 1_000),
      );
      await Promise.all([
        exchangeCoderouterHandoffLease(
          race.lease,
          new Date(now.getTime() + 1_000),
        ),
        revokeRouteTokensForTeam(
          teamId,
          new Date(now.getTime() + 1_000),
        ),
      ]);
      const racedRouteRows = await database()<Array<{
        revokedAt: Date | null;
      }>>`
        select revoked_at as "revokedAt"
        from coderouter_route_tokens
        where team_id = ${teamId}
      `;
      expect(racedRouteRows.every((row) => row.revokedAt !== null)).toBe(true);
    });
  });

  dbTest("opportunistically cleans leases beyond the retention window", async () => {
    await withFixture(async ({ teamId, userId, now }) => {
      await database()`
        delete from coderouter_handoff_leases
        where expires_at < ${new Date(now.getTime() - 10 * 60_000)}
      `;
      const stale = await issueCoderouterHandoffLease(
        teamId,
        userId,
        new Date(now.getTime() - 20 * 60_000),
      );
      const fresh = await issueCoderouterHandoffLease(teamId, userId, now);
      const retainedHashes = await database()<Array<{ leaseHash: string }>>`
        select lease_hash as "leaseHash"
        from coderouter_handoff_leases
        where team_id = ${teamId}
      `;
      expect(retainedHashes.map((row) => row.leaseHash)).not.toContain(
        handoffLeaseHash(stale.lease),
      );
      expect(retainedHashes.map((row) => row.leaseHash)).toContain(
        handoffLeaseHash(fresh.lease),
      );
    });
  });
});
