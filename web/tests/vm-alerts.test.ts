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
    await sql`truncate cloud_vm_alert_states, cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;

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
        'freestyle',
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
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.create.failed', 'freestyle', 'image-alerts', '{"secret":"must-not-leak"}'::jsonb, ${new Date(now.getTime() - 5 * 60 * 1000)}),
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.base.create.failed', 'freestyle', 'image-alerts', '{}'::jsonb, ${new Date(now.getTime() - 4 * 60 * 1000)}),
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.create.failed', 'freestyle', 'image-alerts', '{}'::jsonb, ${new Date(now.getTime() - 3 * 60 * 1000)}),
        ('user-alerts', 'team-alerts', 'free', ${runningVm.id}, 'vm.create.failed', 'freestyle', 'image-alerts', '{}'::jsonb, ${new Date(now.getTime() - 16 * 60 * 1000)})
    `;
    await sql`
      insert into cloud_vm_leases (vm_id, user_id, kind, token_hash, expires_at)
      select ${runningVm.id}, 'user-alerts', 'preview', 'expired-preview-alert-' || n, ${new Date(now.getTime() - 60 * 1000)}
      from generate_series(1, 51) as n
    `;
    await sql`
      insert into cloud_vm_leases (
        vm_id, user_id, kind, token_hash, provider_identity_handle, expires_at
      )
      select ${runningVm.id}, 'user-alerts', 'ssh', 'expired-identity-alert-' || n,
        'provider-identity-alert-' || n, ${new Date(now.getTime() - 60 * 1000)}
      from generate_series(1, 51) as n
    `;
    await sql`
      insert into cloud_vm_leases (
        vm_id, user_id, kind, token_hash, provider_identity_handle, expires_at
      )
      values (
        ${runningVm.id}, 'user-alerts', 'ssh', 'expired-empty-identity-alert', '',
        ${new Date(now.getTime() - 60 * 1000)}
      )
    `;

    const alerts: AlertInput[] = [];
    const run = (runNow = now) => runVmAlertChecks({
      db: cloudDb(),
      now: runNow,
      env: {
        CMUX_VM_ALERT_CREATE_FAILURES_15M: "3",
        CMUX_VM_ALERT_EXPIRED_LEASES: "50",
      },
      sendAlert: async (input): Promise<AlertResult> => {
        alerts.push(input);
        return { sent: true, configured: true, status: 200 };
      },
    });
    const summary = await run();

    expect(summary).toEqual({
      createFailures: { triggered: true, count: 3 },
      stuckProvisioning: { triggered: true, count: 1 },
      expiredUnrevokedLeases: { triggered: true, count: 51 },
      alertSink: { configured: false, droppedAlerts: 0 },
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

    await run();
    expect(alerts).toHaveLength(3);
    await run(new Date(now.getTime() + 24 * 60 * 60 * 1000 + 1));
    expect(alerts).toHaveLength(5);
  });

  dbTest("retries a failed Slack delivery after the durable delivery lease expires", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_alert_states, cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const now = new Date("2026-07-04T12:00:00.000Z");
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status
      )
      values ('user-alert-retry', 'team-alert-retry', 'free', 'freestyle',
        'provider-alert-retry', 'snapshot-alert-retry', 'running')
      returning id
    `;
    await sql`
      insert into cloud_vm_leases (
        vm_id, user_id, kind, token_hash, provider_identity_handle, expires_at
      )
      select ${vm.id}, 'user-alert-retry', 'ssh', 'retry-identity-' || n,
        'retry-provider-identity-' || n, ${new Date(now.getTime() - 60 * 1000)}
      from generate_series(1, 51) as n
    `;

    let attempts = 0;
    const run = (runNow: Date) => runVmAlertChecks({
      db: cloudDb(),
      now: runNow,
      env: { CMUX_VM_ALERT_EXPIRED_LEASES: "50" },
      sendAlert: async (): Promise<AlertResult> => {
        attempts += 1;
        return attempts === 1
          ? { sent: false, configured: true, status: 503 }
          : { sent: true, configured: true, status: 200 };
      },
    });

    await run(now);
    await run(new Date(now.getTime() + 5 * 60 * 1000 + 1));
    expect(attempts).toBe(2);
  });

  dbTest("does not page the create-failure spike for reconciliation housekeeping", async () => {
    if (!sql) throw new Error("test database not initialized");
    await sql`truncate cloud_vm_alert_states, cloud_vm_billing_grants, cloud_vm_usage_events, cloud_vm_leases, cloud_vms restart identity cascade`;
    const now = new Date("2026-07-04T12:00:00.000Z");
    const [vm] = await sql<{ id: string }[]>`
      insert into cloud_vms (
        user_id, billing_team_id, billing_plan_id, provider, provider_vm_id, image_id, status
      )
      values ('user-alert-housekeeping', 'team-alert-housekeeping', 'free', 'freestyle',
        'provider-alert-housekeeping', 'snapshot-alert-housekeeping', 'running')
      returning id
    `;
    await sql`
      insert into cloud_vm_usage_events (
        user_id, billing_team_id, billing_plan_id, vm_id, event_type, provider, image_id, metadata, created_at
      )
      select 'user-alert-housekeeping', 'team-alert-housekeeping', 'free', ${vm.id},
        'vm.create.failed', 'freestyle', 'snapshot-alert-housekeeping',
        case when n <= 3 then '{"operation":"create_abandoned"}'::jsonb else '{}'::jsonb end,
        ${new Date(now.getTime() - 60 * 1000)}
      from generate_series(1, 5) as n
    `;
    const alerts: AlertInput[] = [];
    const summary = await runVmAlertChecks({
      db: cloudDb(),
      now,
      env: { CMUX_VM_ALERT_CREATE_FAILURES_15M: "3" },
      sendAlert: async (input): Promise<AlertResult> => {
        alerts.push(input);
        return { sent: true, configured: true, status: 200 };
      },
    });
    expect(summary.createFailures).toEqual({ triggered: false, count: 2 });
    expect(alerts).toEqual([]);
  });
});
