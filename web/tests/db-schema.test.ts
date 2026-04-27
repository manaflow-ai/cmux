import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

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
  dbTest("applies migrations and enforces create idempotency by user", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id,
        provider,
        provider_vm_id,
        image_id,
        image_version,
        status,
        idempotency_key
      )
      values (
        'user-1',
        'e2b',
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
        insert into cloud_vms (user_id, provider, image_id, status, idempotency_key)
        values ('user-1', 'e2b', 'cmuxd-ws:test', 'provisioning', 'idem-1')
      `;
    } catch (err) {
      duplicateError = err;
    }
    expect((duplicateError as { code?: string } | undefined)?.code).toBe("23505");

    await sql`
      insert into cloud_vms (user_id, provider, image_id, status, idempotency_key)
      values ('user-2', 'e2b', 'cmuxd-ws:test', 'provisioning', 'idem-1')
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
      values ('user-1', ${vm.id}, 'vm.created', 'e2b', 'cmuxd-ws:test', '{"source":"test"}'::jsonb)
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
