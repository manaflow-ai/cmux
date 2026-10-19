import { PGlite } from "@electric-sql/pglite";
import { beforeEach, describe, expect, it } from "vitest";
import { Effect, Layer } from "effect";
import migration1 from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import migration2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import migration11 from "../../migrations/0011_cmux_vm_usage.sql?raw";
import { MeteringLedger } from "../../src/metering/ledger.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { meteringLayer } from "../../src/metering/live.ts";
import { Entitlements, entitlementsFromPolicyLayer } from "../../src/proofs/tenant-may-create.ts";
import { tenantPolicyLayer } from "../../src/policy.ts";
import { TenantId } from "../../src/lib/ids.ts";

let pg: PGlite;
const migration = `${migration1}\n${migration2}\n${migration11}`;

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(migration);
});

describe("metering migration", () => {
  it("preserves one open interval per VM and creates the billing tables", async () => {
    await pg.query(
      `INSERT INTO cmux_vm.usage_intervals
        (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, vcpus, memory_mb, storage_mb, compute_billed, source)
       VALUES ('team_a', 'freestyle', '*', 'up-1', 'vm_00000000000000000000000000', '2026-10-18T00:00:00Z', 4, 8192, 32768, true, 'api')`,
    );
    await expect(
      pg.query(
        `INSERT INTO cmux_vm.usage_intervals
          (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, vcpus, memory_mb, storage_mb, compute_billed, source)
         VALUES ('team_a', 'freestyle', '*', 'up-1', 'vm_00000000000000000000000000', '2026-10-18T00:05:00Z', 4, 8192, 32768, true, 'api')`,
      ),
    ).rejects.toThrow();
    const tables = await pg.query<{ name: string }>(
      `SELECT table_schema || '.' || table_name AS name FROM information_schema.tables
       WHERE table_schema = 'cmux_vm' AND table_name IN ('usage_intervals', 'billing_accounts', 'usage_exports', 'usage_adjustments') ORDER BY name`,
    );
    expect(tables.rows.map((row) => row.name)).toEqual(["cmux_vm.billing_accounts", "cmux_vm.usage_adjustments", "cmux_vm.usage_exports", "cmux_vm.usage_intervals"]);
  });

  it("does not race an API interval newer than a reconcile run and closes deleted rows", async () => {
    const sql = Layer.succeed(SqlClient, {
      query: (operation, text, params) => Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
    });
    await pg.query("INSERT INTO cmux_vm.resources (cmux_id, tenant_id, kind, upstream_id, created_by, provider, region) VALUES ('vm_00000000000000000000000000', 'team_a', 'vm', 'up-race', 'user:test', 'freestyle', '*')");
    await pg.query(`INSERT INTO cmux_vm.usage_intervals (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, vcpus, memory_mb, storage_mb, compute_billed, source) VALUES ('team_a', 'freestyle', '*', 'up-race', 'vm_00000000000000000000000000', now() + interval '10 seconds', 4, 8192, 32768, true, 'api')`);
    const metering = meteringLayer({ markupBps: 0 }).pipe(Layer.provide(sql));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.reconcile(new Date(), () => Effect.succeed({ kind: "present" as const, vm: { state: "running", vcpus: 4, memoryMb: 8192, storageMb: 32768 } }))), metering));
    const openCount = await pg.query<{ count: string }>("SELECT count(*)::text AS count FROM cmux_vm.usage_intervals WHERE ended_at IS NULL");
    expect(openCount.rows[0]?.count).toBe("1");
    await pg.query("UPDATE cmux_vm.resources SET deleted_at = now() WHERE cmux_id = 'vm_00000000000000000000000000'");
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.reconcile(new Date(), () => Effect.succeed({ kind: "unavailable" as const }))), metering));
    const closed = await pg.query<{ count: string }>("SELECT count(*)::text AS count FROM cmux_vm.usage_intervals WHERE ended_at IS NOT NULL");
    expect(closed.rows[0]?.count).toBe("1");
  });

  it("entitles a production tenant only after billing activation", async () => {
    const sql = Layer.succeed(SqlClient, {
      query: (operation, text, params) => Effect.tryPromise({ try: async () => (await pg.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
    });
    await pg.query("INSERT INTO cmux_vm.billing_accounts (tenant_id, stripe_customer_id, status, activated_at) VALUES ('team_a', 'cus_test', 'active', '2026-10-18T00:00:00Z')");
    const policy = tenantPolicyLayer({ environment: "production" });
    const metering = meteringLayer({ markupBps: 0 }).pipe(Layer.provide(sql));
    const layer = entitlementsFromPolicyLayer.pipe(Layer.provide(policy), Layer.provide(metering));
    const allowed = await Effect.runPromise(Effect.provide(Effect.flatMap(Entitlements, (entitlements) => entitlements.mayCreate(TenantId.make("team_a"))), layer));
    expect(allowed).toBe(true);
    await pg.query("UPDATE cmux_vm.billing_accounts SET status = 'inactive' WHERE tenant_id = 'team_a'");
    const denied = await Effect.runPromise(Effect.provide(Effect.flatMap(Entitlements, (entitlements) => entitlements.mayCreate(TenantId.make("team_a"))), layer));
    expect(denied).toBe(false);
  });
});
