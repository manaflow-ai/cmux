import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import postgres, { type Sql } from "postgres";

import { closeCloudDbForTests } from "../db/client";
import {
  DEVICE_RETENTION_MAX_AGE_MS,
  pruneStaleDeviceRegistryRows,
} from "../services/devices/retention";

const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

const originalCronSecret = process.env.CRON_SECRET;

const route = await import("../app/api/internal/devices/retention/route");

let sql: Sql | null = null;

const TEAM_ID = "retention-team";
const USER_ID = "retention-user";
// One day past the retention window, so rows are unambiguously stale even
// against clock skew between the test process and the database.
const STALE_MS = DEVICE_RETENTION_MAX_AGE_MS + 24 * 60 * 60 * 1_000;

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

beforeEach(async () => {
  if (!sql) return;
  await sql`truncate devices, device_app_instances restart identity cascade`;
});

afterEach(() => {
  restoreEnv("CRON_SECRET", originalCronSecret);
});

async function insertDevice(input: {
  readonly deviceUuid: string;
  readonly lastSeenAgoMs: number;
  readonly manual?: boolean;
}): Promise<string> {
  if (!sql) throw new Error("test database not initialized");
  const labels = input.manual ? { manual: true } : {};
  const [{ id }] = await sql<{ id: string }[]>`
    insert into devices (team_id, device_uuid, user_id, platform, labels, last_seen_at)
    values (
      ${TEAM_ID},
      ${input.deviceUuid},
      ${USER_ID},
      'mac',
      ${sql.json(labels)},
      now() - make_interval(secs => ${input.lastSeenAgoMs / 1_000})
    )
    returning id
  `;
  return id;
}

async function insertInstance(input: {
  readonly deviceId: string;
  readonly tag: string;
  readonly lastSeenAgoMs: number;
}): Promise<void> {
  if (!sql) throw new Error("test database not initialized");
  await sql`
    insert into device_app_instances (device_id, team_id, tag, last_seen_at)
    values (
      ${input.deviceId},
      ${TEAM_ID},
      ${input.tag},
      now() - make_interval(secs => ${input.lastSeenAgoMs / 1_000})
    )
  `;
}

describe("device registry retention route", () => {
  test("does not expose the secret env var name when the cron secret is missing", async () => {
    delete process.env.CRON_SECRET;

    const response = await route.POST(
      new Request("https://cmux.test/api/internal/devices/retention", {
        method: "POST",
      }),
    );

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ error: "service_unavailable" });
  });

  test("requires the configured cron secret before pruning", async () => {
    process.env.CRON_SECRET = "cron-secret";

    const response = await route.POST(
      new Request("https://cmux.test/api/internal/devices/retention", {
        method: "POST",
        headers: { authorization: "Bearer wrong" },
      }),
    );

    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unauthorized" });
  });

  test("rejects out-of-range retention budgets before touching the database", async () => {
    await expect(
      pruneStaleDeviceRegistryRows({ now: new Date(), maxRows: 0 }),
    ).rejects.toThrow("invalid device retention maxRows");
    await expect(
      pruneStaleDeviceRegistryRows({ now: new Date(), maxDurationMs: 60_000 }),
    ).rejects.toThrow("invalid device retention maxDurationMs");
  });

  dbTest("prunes stale instances and the devices they empty, sparing fresh rows", async () => {
    if (!sql) throw new Error("test database not initialized");

    // Stale device whose only instance is stale: both go in one run.
    const staleDevice = await insertDevice({
      deviceUuid: "11111111-1111-4111-8111-111111111111",
      lastSeenAgoMs: STALE_MS,
    });
    await insertInstance({ deviceId: staleDevice, tag: "stable", lastSeenAgoMs: STALE_MS });

    // Device seen long ago but with a fresh instance (an always-on Mac whose
    // device row lastSeenAt lags): the fresh instance and its device survive.
    const laggingDevice = await insertDevice({
      deviceUuid: "22222222-2222-4222-8222-222222222222",
      lastSeenAgoMs: STALE_MS,
    });
    await insertInstance({ deviceId: laggingDevice, tag: "stable", lastSeenAgoMs: 0 });
    await insertInstance({ deviceId: laggingDevice, tag: "old-dev", lastSeenAgoMs: STALE_MS });

    // Fresh device with no instances (mid-registration): untouched.
    await insertDevice({
      deviceUuid: "33333333-3333-4333-8333-333333333333",
      lastSeenAgoMs: 0,
    });

    const result = await pruneStaleDeviceRegistryRows({ now: new Date() });

    // Removed: stale device's instance + its emptied device row + the lagging
    // device's stale old-dev instance.
    expect(result.byCategory.staleInstances).toBe(2);
    expect(result.byCategory.staleDevices).toBe(1);
    expect(result.rowsProcessed).toBe(3);
    expect(result.budgetExhausted).toBeNull();
    expect(result.backlog).toBe(false);

    const remainingDevices = await sql<{ device_uuid: string }[]>`
      select device_uuid from devices order by device_uuid
    `;
    expect(remainingDevices.map((row) => row.device_uuid)).toEqual([
      "22222222-2222-4222-8222-222222222222",
      "33333333-3333-4333-8333-333333333333",
    ]);
    const [{ total }] = await sql<{ total: number }[]>`
      select count(*)::int as total from device_app_instances
    `;
    expect(total).toBe(1);
  });

  dbTest("never touches manual remotes, however stale", async () => {
    if (!sql) throw new Error("test database not initialized");

    // Manual remotes have no registration heartbeat; staleness is their
    // steady state, not a deletion signal.
    const manualDevice = await insertDevice({
      deviceUuid: "44444444-4444-4444-8444-444444444444",
      lastSeenAgoMs: STALE_MS,
      manual: true,
    });
    await insertInstance({ deviceId: manualDevice, tag: "default", lastSeenAgoMs: STALE_MS });
    await insertDevice({
      deviceUuid: "55555555-5555-4555-8555-555555555555",
      lastSeenAgoMs: STALE_MS,
      manual: true,
    });

    const result = await pruneStaleDeviceRegistryRows({ now: new Date() });

    expect(result.rowsProcessed).toBe(0);
    expect(result.backlog).toBe(false);
    const [{ total }] = await sql<{ total: number }[]>`select count(*)::int as total from devices`;
    expect(total).toBe(2);
  });

  dbTest("stops at the row budget and reports the backlog", async () => {
    if (!sql) throw new Error("test database not initialized");

    const device = await insertDevice({
      deviceUuid: "66666666-6666-4666-8666-666666666666",
      lastSeenAgoMs: STALE_MS,
    });
    for (let i = 0; i < 3; i++) {
      await insertInstance({ deviceId: device, tag: `tag-${i}`, lastSeenAgoMs: STALE_MS });
    }

    const result = await pruneStaleDeviceRegistryRows({ now: new Date(), maxRows: 2 });

    expect(result.rowsProcessed).toBe(2);
    expect(result.budgetExhausted).toBe("rows");
    expect(result.backlog).toBe(true);

    // The next run drains the remainder (instance + emptied device row).
    const drain = await pruneStaleDeviceRegistryRows({ now: new Date() });
    expect(drain.byCategory.staleInstances).toBe(1);
    expect(drain.byCategory.staleDevices).toBe(1);
    expect(drain.backlog).toBe(false);
  });

  dbTest("responds with the retention summary under the cron secret", async () => {
    if (!sql) throw new Error("test database not initialized");
    process.env.CRON_SECRET = "cron-secret";

    await insertDevice({
      deviceUuid: "77777777-7777-4777-8777-777777777777",
      lastSeenAgoMs: STALE_MS,
    });

    const response = await route.POST(
      new Request("https://cmux.test/api/internal/devices/retention", {
        method: "POST",
        headers: { authorization: "Bearer cron-secret" },
      }),
    );

    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      ok: boolean;
      retention: { rowsProcessed: number; byCategory: Record<string, number> };
    };
    expect(body.ok).toBe(true);
    expect(body.retention.byCategory.staleDevices).toBe(1);

    const [{ total }] = await sql<{ total: number }[]>`select count(*)::int as total from devices`;
    expect(total).toBe(0);
  });
});

function restoreEnv(key: string, value: string | undefined): void {
  if (typeof value === "undefined") {
    delete process.env[key];
  } else {
    process.env[key] = value;
  }
}
