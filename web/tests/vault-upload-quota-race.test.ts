import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { eq, sql as drizzleSql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "../db/schema";
import { closeCloudDbForTests } from "../db/client";
import { vaultUploadGrants } from "../db/schema";
import {
  reserveVaultUploadGrants,
  type VaultGrantItem,
  type VaultReservationOutcome,
} from "../services/vault/usage";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  return url;
}

function openDb() {
  const client = postgres(databaseURL(), { max: 1 });
  return { client, db: drizzle({ client, schema }) };
}

type TestDb = ReturnType<typeof openDb>;

let dbA: TestDb | null = null;
let dbB: TestDb | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  dbA = openDb();
  dbB = openDb();
});

afterAll(async () => {
  await closeCloudDbForTests();
  await dbA?.client.end();
  await dbB?.client.end();
});

describe("vault upload quota reservations", () => {
  dbTest("races two near-quota batches; exactly one reserves", async () => {
    if (!dbA || !dbB) throw new Error("test database not initialized");
    await truncateVaultTables(dbA);

    const now = new Date("2026-07-01T12:00:00Z");
    const userId = "vault-race-user";
    const bytes = 1_000;
    const commonParams = {
      userId,
      maxUploadBytes: bytes,
      maxUserBytes: bytes,
      now,
      grantTtlMs: 24 * 60 * 60 * 1000,
    };
    const hooks = { afterQuotaRead: () => delay(150) };

    const [a, b] = await Promise.all([
      reserveVaultUploadGrants(
        dbA.db,
        {
          ...commonParams,
          items: [grantItem({ agentSessionId: "race-a", sha256: "sha-a", compressedSizeBytes: bytes })],
        },
        hooks,
      ),
      reserveVaultUploadGrants(
        dbB.db,
        {
          ...commonParams,
          items: [grantItem({ agentSessionId: "race-b", sha256: "sha-b", compressedSizeBytes: bytes })],
        },
        hooks,
      ),
    ]);

    expect([a, b].filter((outcomes) => outcomes.some((outcome) => outcome.kind === "granted"))).toHaveLength(1);
    expect([a, b].filter((outcomes) => hasQuotaExceeded(outcomes))).toHaveLength(1);
    expect(await grantStats(dbA, userId)).toEqual({ count: 1, bytes });
  });

  dbTest("idempotent retry of an existing object key does not double-count under the lock", async () => {
    if (!dbA) throw new Error("test database not initialized");
    await truncateVaultTables(dbA);

    const now = new Date("2026-07-01T12:00:00Z");
    const userId = "vault-idempotent-user";
    const bytes = 1_000;
    const item = grantItem({ agentSessionId: "retry-session", sha256: "retry-sha", compressedSizeBytes: bytes });
    const params = {
      userId,
      items: [item],
      maxUploadBytes: bytes,
      maxUserBytes: bytes,
      now,
      grantTtlMs: 24 * 60 * 60 * 1000,
    };

    expect(await reserveVaultUploadGrants(dbA.db, params)).toMatchObject([{ kind: "granted" }]);
    expect(await reserveVaultUploadGrants(dbA.db, params)).toMatchObject([{ kind: "granted" }]);
    expect(await grantStats(dbA, userId)).toEqual({ count: 1, bytes });
  });
});

function grantItem(input: {
  agentSessionId: string;
  sha256: string;
  compressedSizeBytes: number;
}): VaultGrantItem {
  return {
    agent: "codex",
    agentSessionId: input.agentSessionId,
    sha256: input.sha256,
    relPath: `.cmux/sessions/${input.agentSessionId}.jsonl`,
    cwd: "/tmp/cmux-vault-test",
    compressedSizeBytes: input.compressedSizeBytes,
  };
}

async function truncateVaultTables(db: TestDb): Promise<void> {
  await db.client`truncate vault_upload_grants, vault_snapshots, vault_sessions restart identity cascade`;
}

async function grantStats(db: TestDb, userId: string): Promise<{ count: number; bytes: number }> {
  const [row] = await db.db
    .select({
      count: drizzleSql<number>`count(*)::int`,
      bytes: drizzleSql<number>`coalesce(sum(${vaultUploadGrants.compressedSizeBytes}), 0)::double precision`,
    })
    .from(vaultUploadGrants)
    .where(eq(vaultUploadGrants.userId, userId));
  return { count: row?.count ?? 0, bytes: row?.bytes ?? 0 };
}

function hasQuotaExceeded(outcomes: readonly VaultReservationOutcome[]): boolean {
  return outcomes.some((outcome) => outcome.kind === "error" && outcome.error === "quota_exceeded");
}

async function delay(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}
