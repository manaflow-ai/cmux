import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { closeCloudDbForTests, cloudDb } from "../db/client";
import { runVmAlertChecks } from "../services/observability/vmAlerts";
import type { AlertInput, AlertResult } from "../services/observability/alerts";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

let sql: Sql | null = null;

function databaseURL() {
  const url = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!url) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  return url;
}

beforeAll(() => {
  if (!runDbTests) return;
  sql = postgres(databaseURL(), { max: 1 });
});

afterAll(async () => {
  await closeCloudDbForTests();
  await sql?.end();
});

describe("VM alert checks", () => {
  dbTest("detects create failures, stuck provisioning VMs, and expired unrevoked leases", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

    const now = new Date("2026-07-04T12:00:00.000Z");
    const [stuckVm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id,
        billing_team_id,
        billing_plan_id,
        provider,
        image_id,
        status,
        created_at,
        provider_metadata
      )
      values (
        'user-alerts',
        'team-alerts',
        'free',
        'freestyle',
        'snapshot-alerts',
        'provisioning',
        ${new Date(now.getTime() - 25 * 60 * 1000)},
        '{"providerToken":"must-not-leak"}'::jsonb
      )
      returning id
    `;
    const [runningVm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id,
        billing_team_id,
        billing_plan_id,
        provider,
        provider_vm_id,
        image_id,
        status,
        created_at
      )
      values (
        'user-alerts',
        'team-alerts',
        'free',
        'e2b',
        'provider-alerts',
        'image-alerts',
        'running',
        ${now}
      )
      returning id
    `;

    await sql`
      insert into cloud_vm_usage_events (
        user_id,
        billing_team_id,
        billing_plan_id,
        vm_id,
        event_type,
        provider,
        image_id,
        metadata,
        created_at
      )
      values
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.create.failed', 'e2b', 'image-alerts', '{"secret":"must-not-leak"}'::jsonb, ${new Date(now.getTime() - 5 * 60 * 1000)}),
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.base.create.failed', 'freestyle', 'image-alerts', '{}'::jsonb, ${new Date(now.getTime() - 4 * 60 * 1000)}),
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.create.failed', 'daytona', 'image-alerts', '{}'::jsonb, ${new Date(now.getTime() - 3 * 60 * 1000)}),
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.create.failed', 'e2b', 'image-alerts', '{}'::jsonb, ${new Date(now.getTime() - 16 * 60 * 1000)})
    `;
    await sql`
      insert into cloud_vm_leases (vm_id, user_id, kind, token_hash, expires_at)
      select ${runningVm.id}, 'user-alerts', 'ssh', 'expired-alert-' || n, ${new Date(now.getTime() - 60 * 1000)}
      from generate_series(1, 51) as n
    `;

    const alerts: AlertInput[] = [];
    const summary = await runVmAlertChecks({
      db: cloudDb(),
      now,
      env: {
        CMUX_VM_ALERT_CREATE_FAILURES_15M: "3",
        CMUX_VM_ALERT_EXPIRED_LEASES: "50",
      },
      sendAlert: async (input): Promise<AlertResult> => {
        alerts.push(input);
        return { sent: true, status: 200 };
      },
    });

    expect(summary).toEqual({
      createFailures: { triggered: true, count: 3 },
      stuckProvisioning: { triggered: true, count: 1 },
      expiredUnrevokedLeases: { triggered: true, count: 51 },
    });
    expect(alerts.map((alert) => alert.key)).toEqual([
      "vm-create-failure-spike",
      "vm-stuck-provisioning",
      "vm-expired-unrevoked-leases",
    ]);
    expect(alerts[1]?.body).toContain(stuckVm.id);
    const alertText = JSON.stringify(alerts);
    expect(alertText).not.toContain("must-not-leak");
    expect(alertText).not.toContain("providerToken");
    expect(alertText).not.toContain("secret");
  });
});
