// Database-backed tests of the real relay admission policy behind
// POST /api/relay/allow: the route tests fake the admission, so the
// revokedAt filter and the account-deletion tombstone rule are proven here
// against Postgres. Gated like tests/iroh-db-behavior.test.ts.

import { afterAll, beforeAll, beforeEach, describe, test, expect } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import { accountDeletionUserHash } from "../services/account/deletionLock";
import { relayAllowAdmission } from "../services/relay/allow";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function requiredSql(): Sql {
  if (!sql) throw new Error("sql not initialized");
  return sql;
}

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  sql = postgres(databaseURL, { max: 4 });
});

beforeEach(async () => {
  if (!sql) return;
  await sql`
    truncate
      iroh_relay_token_issuances,
      iroh_pair_grant_issuances,
      iroh_registration_challenges,
      iroh_endpoint_bindings,
      account_deletion_tombstones
    restart identity cascade
  `;
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

async function insertBinding(input: {
  readonly userId: string;
  readonly endpointId: string;
  readonly revokedAt?: Date;
}): Promise<void> {
  await requiredSql()`
    insert into iroh_endpoint_bindings (
      user_id, device_uuid, app_instance_id, tag, platform, endpoint_id,
      identity_generation, revoked_at, revoked_reason
    ) values (
      ${input.userId}, ${randomUUID()}, ${randomUUID()}, 'stable', 'mac',
      ${input.endpointId}, 1,
      ${input.revokedAt ?? null},
      ${input.revokedAt ? "user_requested" : null}
    )
  `;
}

describe("relay allow admission database policy", () => {
  dbTest("allows an active binding", async () => {
    const endpointId = "11".repeat(32);
    await insertBinding({ userId: "user-allow-active", endpointId });
    expect(await relayAllowAdmission(endpointId)).toBe("allow");
  });

  dbTest("denies an unknown endpoint", async () => {
    expect(await relayAllowAdmission("22".repeat(32))).toBe("deny");
  });

  dbTest("denies a revoked binding", async () => {
    const endpointId = "33".repeat(32);
    await insertBinding({
      userId: "user-allow-revoked",
      endpointId,
      revokedAt: new Date(),
    });
    expect(await relayAllowAdmission(endpointId)).toBe("deny");
  });

  dbTest("denies an active binding while account deletion is in progress", async () => {
    const endpointId = "44".repeat(32);
    const userId = "user-allow-deleting";
    await insertBinding({ userId, endpointId });
    await requiredSql()`
      insert into account_deletion_tombstones (user_id_hash, user_id, status, updated_at)
      values (${accountDeletionUserHash(userId)}, ${userId}, 'pending', now())
    `;
    expect(await relayAllowAdmission(endpointId)).toBe("deny");
  });

  dbTest("readmits after the tombstone records a terminal failed deletion", async () => {
    const endpointId = "55".repeat(32);
    const userId = "user-allow-deletion-failed";
    await insertBinding({ userId, endpointId });
    await requiredSql()`
      insert into account_deletion_tombstones (user_id_hash, user_id, status, updated_at)
      values (${accountDeletionUserHash(userId)}, ${userId}, 'failed', now())
    `;
    expect(await relayAllowAdmission(endpointId)).toBe("allow");
  });
});
