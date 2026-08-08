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

describe("devbox database schema", () => {
  dbTest("enforces one active devbox per user and frees the slot on release", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`truncate cloud_devboxes, cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const insertVm = (providerVmId: string) => sql!<{ id: string }[]>`
      insert into cloud_vms (user_id, billing_team_id, provider, provider_vm_id, image_id, status)
      values ('user-1', 'team-1', 'daytona', ${providerVmId}, 'cmuxd-ws:test', 'running')
      returning id
    `;

    const [vm1] = await insertVm("sandbox-1");
    const [vm2] = await insertVm("sandbox-2");
    if (!vm1 || !vm2) throw new Error("VM fixture insert failed");

    const [claim] = await sql<{ id: string }[]>`
      insert into cloud_devboxes (user_id, vm_id, volume_id, volume_name)
      values ('user-1', ${vm1.id}, 'vol-1', 'cmux-devbox-abc')
      returning id
    `;
    expect(claim?.id).toBeTruthy();

    // Second active claim for the same user must hit the partial unique index.
    let duplicateError: unknown;
    try {
      await sql`
        insert into cloud_devboxes (user_id, vm_id, volume_id, volume_name)
        values ('user-1', ${vm2.id}, 'vol-1', 'cmux-devbox-abc')
      `;
    } catch (err) {
      duplicateError = err;
    }
    expect((duplicateError as { code?: string } | undefined)?.code).toBe("23505");

    // A different user is unaffected by user-1's claim.
    const [vm3] = await sql<{ id: string }[]>`
      insert into cloud_vms (user_id, billing_team_id, provider, provider_vm_id, image_id, status)
      values ('user-2', 'team-2', 'daytona', 'sandbox-3', 'cmuxd-ws:test', 'running')
      returning id
    `;
    if (!vm3) throw new Error("VM fixture insert failed");
    const [otherClaim] = await sql<{ id: string }[]>`
      insert into cloud_devboxes (user_id, vm_id, volume_id, volume_name)
      values ('user-2', ${vm3.id}, 'vol-2', 'cmux-devbox-def')
      returning id
    `;
    expect(otherClaim?.id).toBeTruthy();

    // Releasing the claim frees the slot; the released row stays for audit.
    await sql`
      update cloud_devboxes set released_at = now() where user_id = 'user-1' and released_at is null
    `;
    const [reclaim] = await sql<{ id: string }[]>`
      insert into cloud_devboxes (user_id, vm_id, volume_id, volume_name)
      values ('user-1', ${vm2.id}, 'vol-1', 'cmux-devbox-abc')
      returning id
    `;
    expect(reclaim?.id).toBeTruthy();

    const [{ total }] = await sql<{ total: string }[]>`
      select count(*)::text as total from cloud_devboxes where user_id = 'user-1'
    `;
    expect(Number(total)).toBe(2);
  });
});
