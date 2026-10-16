import { afterAll, beforeAll, expect, mock, test } from "bun:test";
import { randomUUID } from "node:crypto";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import type { VmPrincipalRow } from "../services/vms/vmPrincipalContract";

const enabled = process.env.CMUX_DB_TEST === "1";
const dbTest = enabled ? test : test.skip;
const id = randomUUID();
const suffix = id.replaceAll("-", "");
const audit = `cmux_resource_audit_${suffix}`;
const auditFunction = `${audit}_fn`;
let sql: Sql;
let principalRow: VmPrincipalRow | null = null;
let active = false;

const principal = await import("../services/vms/vmPrincipal");
const authenticate = principal.requireVmPrincipal;
mock.module("../services/vms/vmPrincipal", () => ({
  ...principal,
  requireVmPrincipal: ((request: Request, deps?: Parameters<typeof authenticate>[1]) => active && principalRow
    ? Promise.resolve({ ok: true as const, principal: { vm: principalRow, userId: principalRow.userId, teamId: "resource-test" } })
    : authenticate(request, deps)) as typeof authenticate,
}));
const { POST } = await import("../app/api/vm/resource-usage/self/route");

beforeAll(async () => {
  if (!enabled) return;
  sql = postgres(process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL!, { max: 5 });
  await sql`insert into cloud_vms (id,user_id,provider,provider_vm_id,image_id,status,provider_metadata)
    values (${id},'resource-test','freestyle',${`provider-${id}`},'sh-test','running','{"networkId":"preserved"}'::jsonb)`;
  // Count actual durable row changes, not attempted SQL calls. Identifier and
  // predicate values are generated UUIDs scoped to this test's isolated DB.
  await sql.unsafe(`create table ${audit} (written integer)`);
  await sql.unsafe(`create function ${auditFunction}() returns trigger language plpgsql as $$ begin
    if NEW.id = '${id}'::uuid and NEW.provider_metadata->'cmuxResourceUsage' is distinct from OLD.provider_metadata->'cmuxResourceUsage' then
      insert into ${audit} values (1);
    end if; return NEW; end $$`);
  await sql.unsafe(`create trigger ${audit} after update of provider_metadata on cloud_vms for each row execute function ${auditFunction}()`);
  principalRow = await principal.loadCloudVmRow(id);
  if (!principalRow) throw new Error("Missing test VM");
});

afterAll(async () => {
  active = false;
  if (!enabled || !sql) return;
  await sql.unsafe(`drop trigger if exists ${audit} on cloud_vms`);
  await sql.unsafe(`drop function if exists ${auditFunction}()`);
  await sql.unsafe(`drop table if exists ${audit}`);
  await sql`delete from cloud_vms where id = ${id}`;
  await closeCloudDbForTests();
  await sql.end();
});

dbTest("concurrent authenticated reports make one durable write per VM window", async () => {
  active = true;
  try {
    // Every request has the same pre-write principal snapshot, reproducing
    // concurrent auth reads before the first update has committed.
    const responses = await Promise.all(Array.from({ length: 8 }, (_, cpuPercent) => POST(new Request(
      "https://cmux.test/api/vm/resource-usage/self",
      { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ cpuPercent }) },
    ))));
    expect(responses.map(response => response.status)).toEqual(Array(8).fill(204));
    const [writes] = await sql`select count(*)::int as count from ${sql(audit)}`;
    expect(writes.count).toBe(1);
    const [row] = await sql`select provider_metadata from cloud_vms where id = ${id}`;
    expect(row.provider_metadata.networkId).toBe("preserved");
    expect(row.provider_metadata.cmuxResourceUsage.providerVmId).toBe(`provider-${id}`);
  } finally { active = false; }
});
