import { PGlite } from "@electric-sql/pglite";
import { beforeEach, describe, expect, it } from "vitest";
import migration1 from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import migration2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import migration11 from "../../migrations/0011_cmux_vm_usage.sql?raw";

let pg: PGlite;
const migration = `${migration1}\n${migration2}\n${migration11}`;

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(migration);
});

describe("metering migration", () => {
  it("is idempotent and preserves one open interval per VM", async () => {
    await pg.exec(migration);
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
       WHERE table_schema = 'cmux_vm' AND table_name IN ('usage_intervals', 'billing_accounts', 'usage_exports') ORDER BY name`,
    );
    expect(tables.rows.map((row) => row.name)).toEqual(["cmux_vm.billing_accounts", "cmux_vm.usage_exports", "cmux_vm.usage_intervals"]);
  });
});
