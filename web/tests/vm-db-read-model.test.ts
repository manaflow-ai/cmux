import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests } from "../db/client";
import { loadUserVmDbSummary } from "../services/vms/dbReadModel";

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
  await closeCloudDbForTests();
  await sql?.end();
});

describe("VM DB read model", () => {
  dbTest("returns per-user VM and usage counts from Postgres", async () => {
    if (!sql) throw new Error("test database not initialized");

    await sql`truncate cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const [runningVm] = await sql<{ id: string }[]>`
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
        'user-db-read-model',
        'e2b',
        'read-model-provider-vm-1',
        'cmuxd-ws:test',
        '2026-04-25.1',
        'running',
        'read-model-idem-1'
      )
      returning id
    `;
    await sql`
      insert into cloud_vms (user_id, provider, provider_vm_id, image_id, status, idempotency_key)
      values
        ('user-db-read-model', 'freestyle', 'read-model-provider-vm-2', 'sc-test', 'failed', 'read-model-idem-2'),
        ('other-user', 'e2b', 'read-model-provider-vm-other', 'cmuxd-ws:test', 'running', 'read-model-idem-other')
    `;
    await sql`
      insert into cloud_vm_usage_events (user_id, vm_id, event_type, provider, image_id, metadata)
      values
        (
          'user-db-read-model',
          ${runningVm.id},
          'vm.created',
          'e2b',
          'cmuxd-ws:test',
          '{"source":"read-model-test"}'::jsonb
        ),
        (
          'user-db-read-model',
          ${runningVm.id},
          'vm.attach',
          'e2b',
          'cmuxd-ws:test',
          '{"source":"read-model-test"}'::jsonb
        ),
        (
          'other-user',
          null,
          'vm.created',
          'e2b',
          'cmuxd-ws:test',
          '{"source":"read-model-test"}'::jsonb
        )
    `;

    await expect(loadUserVmDbSummary("user-db-read-model")).resolves.toEqual({
      cloudVms: {
        total: 2,
        byStatus: {
          failed: 1,
          running: 1,
        },
      },
      usageEvents: {
        total: 2,
      },
    });
  });
});
