import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { getTableConfig, PgDialect } from "drizzle-orm/pg-core";
import postgres, { type Sql } from "postgres";
import { cloudVmObservedDestroyCleanups, cloudVms } from "../db/schema";
import {
  OBSERVED_DESTROY_CLEANUP_CANDIDATE_PREDICATE,
  OBSERVED_DESTROY_OUTBOX_CANDIDATE_PREDICATE,
} from "../services/vms/repository";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

beforeAll(() => {
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

afterAll(async () => {
  await sql?.end();
});

describe("Cloud VM database schema", () => {
  test("declares the ordered partial index used by observed-destroy cleanup", () => {
    const index = getTableConfig(cloudVms).indexes.find(
      (candidate) => candidate.config.name === "cloud_vms_observed_destroy_cleanup_idx",
    );
    expect(index?.config.columns.map((column) => "name" in column ? column.name : null)).toEqual(["updated_at", "id"]);
    expect(index?.config.where).toBeDefined();

    const migration = readFileSync(new URL(
      "../db/migrations/20260928120000_cloud_vm_observed_destroy_cleanup_index/migration.sql",
      import.meta.url,
    ), "utf8").replace(/\s+/g, " ");
    expect(migration).toContain(
      'ON "cloud_vms" ("updated_at", "id") WHERE "status" = \'destroyed\' AND "provider_metadata" ? \'cmuxObservedDestroyCleanup\'',
    );
    expect(migration).toContain(
      'jsonb_typeof("provider_metadata"->\'cmuxObservedDestroyCleanup\') = \'object\'',
    );
    expect(migration).toContain(
      '"provider_metadata"->\'cmuxObservedDestroyCleanup\' @> \'{"modelPlane":true}\'::jsonb',
    );
  });

  test("compiles observed-destroy candidates with literal partial-index predicates", () => {
    const compiled = new PgDialect().sqlToQuery(OBSERVED_DESTROY_CLEANUP_CANDIDATE_PREDICATE);
    const normalized = compiled.sql.replace(/\s+/g, " ").trim();

    expect(compiled.params).toEqual([]);
    expect(normalized).toContain(`"cloud_vms"."status" = 'destroyed'`);
    expect(normalized).toContain(
      `"cloud_vms"."provider_metadata" ? 'cmuxObservedDestroyCleanup'`,
    );
  });

  test("keeps transferred cleanup independent from account-owned rows and ordered for retry", () => {
    const config = getTableConfig(cloudVmObservedDestroyCleanups);
    expect(config.foreignKeys).toHaveLength(0);
    const index = config.indexes.find(
      (candidate) => candidate.config.name === "cloud_vm_observed_destroy_cleanups_updated_idx",
    );
    expect(index?.config.columns.map((column) => "name" in column ? column.name : null)).toEqual([
      "updated_at",
      "vm_id",
    ]);
    expect(index?.config.where).toBeDefined();
    expect(config.checks.map((check) => check.name)).toContain(
      "cloud_vm_observed_destroy_cleanups_pending_step",
    );

    const migration = readFileSync(new URL(
      "../db/migrations/20260928123000_cloud_vm_observed_destroy_cleanup_outbox/migration.sql",
      import.meta.url,
    ), "utf8").replace(/\s+/g, " ");
    expect(migration).toContain(
      'CREATE INDEX "cloud_vm_observed_destroy_cleanups_updated_idx" ON "cloud_vm_observed_destroy_cleanups" ("updated_at", "vm_id") WHERE coalesce(',
    );
    expect(migration).toContain('jsonb_typeof("cleanup") = \'object\'');
    expect(migration).toContain(
      '("cleanup" - \'modelPlane\' - \'homeVolume\') = \'{}\'::jsonb',
    );
    expect(migration).toContain(
      'CONSTRAINT "cloud_vm_observed_destroy_cleanups_pending_step" CHECK ( coalesce(',
    );
    expect(migration).not.toContain("REFERENCES");
  });

  test("filters malformed legacy outbox rows before the bounded oldest-first scan", () => {
    const compiled = new PgDialect().sqlToQuery(OBSERVED_DESTROY_OUTBOX_CANDIDATE_PREDICATE);
    const normalized = compiled.sql.replace(/\s+/g, " ").trim();

    expect(compiled.params).toEqual([]);
    expect(normalized).toContain(
      `coalesce( jsonb_typeof("cloud_vm_observed_destroy_cleanups"."cleanup") = 'object'`,
    );
    expect(normalized).toContain(
      `("cloud_vm_observed_destroy_cleanups"."cleanup" - 'modelPlane' - 'homeVolume') = '{}'::jsonb`,
    );
    expect(normalized).toContain(
      `not ("cloud_vm_observed_destroy_cleanups"."cleanup" ? 'modelPlane') or "cloud_vm_observed_destroy_cleanups"."cleanup"->'modelPlane' = 'true'::jsonb`,
    );
    expect(normalized).toContain(
      `length(btrim("cloud_vm_observed_destroy_cleanups"."cleanup"->>'homeVolume')) > 0`,
    );
    expect(normalized).toEndWith(
      `), false )`,
    );
  });

  dbTest("rejects malformed transferred cleanup rows", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_observed_destroy_cleanups`;
    const malformed = [
      null,
      "collision",
      [],
      {},
      { modelPlane: false },
      { homeVolume: "   " },
      { homeVolume: "volume", modelPlane: false },
      { homeVolume: "volume", junk: true },
      { modelPlane: true, junk: "retained" },
      { modelPlane: true, homeVolume: "" },
    ];

    for (const [index, cleanup] of malformed.entries()) {
      let insertError: unknown;
      try {
        await sql`
          insert into cloud_vm_observed_destroy_cleanups (vm_id, provider, cleanup)
          values (
            ${`00000000-0000-4000-8000-${String(180 + index).padStart(12, "0")}`},
            'freestyle', ${sql.json(cleanup as never)}
          )
        `;
      } catch (error) {
        insertError = error;
      }
      expect((insertError as { code?: string } | undefined)?.code).toBe("23514");
    }
  });

  dbTest("applies migrations and enforces create idempotency by account owner", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id,
        billing_team_id,
        provider,
        provider_vm_id,
        image_id,
        image_version,
        status,
        idempotency_key
      )
      values (
        'user-1',
        'team-1',
        'freestyle',
        'provider-vm-1',
        'cmuxd-ws:test',
        '2026-04-24.1',
        'running',
        'idem-1'
      )
      returning id
    `;

    let duplicateError: unknown;
    try {
      await sql`
        insert into cloud_vms (user_id, billing_team_id, provider, image_id, status, idempotency_key)
        values ('user-2', 'team-1', 'freestyle', 'cmuxd-ws:test', 'provisioning', 'idem-1')
      `;
    } catch (err) {
      duplicateError = err;
    }
    expect((duplicateError as { code?: string } | undefined)?.code).toBe("23505");

    await sql`
      insert into cloud_vms (user_id, billing_team_id, provider, image_id, status, idempotency_key)
      values ('user-1', 'team-2', 'freestyle', 'cmuxd-ws:test', 'provisioning', 'idem-1')
    `;

    await sql`
      insert into cloud_vms (user_id, provider, image_id, status)
      values
        ('user-1', 'freestyle', 'sc-test', 'provisioning'),
        ('user-1', 'freestyle', 'sc-test', 'provisioning')
    `;

    await sql`
      insert into cloud_vm_leases (vm_id, user_id, kind, token_hash, expires_at)
      values (${vm.id}, 'user-1', 'pty', 'token-hash-1', now() + interval '5 minutes')
    `;
    await sql`
      insert into cloud_vm_usage_events (user_id, vm_id, event_type, provider, image_id, metadata)
      values ('user-1', ${vm.id}, 'vm.created', 'freestyle', 'cmuxd-ws:test', '{"source":"test"}'::jsonb)
    `;

    await sql`delete from cloud_vms where id = ${vm.id}`;

    const [{ leaseCount }] = await sql<{ leaseCount: string }[]>`
      select count(*)::text as "leaseCount" from cloud_vm_leases where vm_id = ${vm.id}
    `;
    expect(leaseCount).toBe("0");

    const [{ usageVmId }] = await sql<{ usageVmId: string | null }[]>`
      select vm_id::text as "usageVmId" from cloud_vm_usage_events where event_type = 'vm.created'
    `;
    expect(usageVmId).toBeNull();
  });
});
