import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import postgres, { type Sql } from "postgres";
import { DEVICE_DELIVERY_LEASE_MS } from "../services/apns/deviceDeliveryLease";
import { PUSH_SEND_LEASE_MS } from "../services/apns/rateLimit";
import { APNS_DEFAULT_MAX_DELIVERY_DURATION_MS } from "../services/apns/sender";
import { accountDeletionUserHash } from "../services/account/deletionLock";

const envKeys = [
  "SKIP_ENV_VALIDATION",
  "VERCEL",
  "CMUX_APNS_KEY_P8",
  "CMUX_APNS_KEY_ID",
  "CMUX_APNS_TEAM_ID",
] as const;
const originalEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]])) as Record<
  (typeof envKeys)[number],
  string | undefined
>;
// Capture real implementations BY VALUE: bun's mock.module can mutate an
// already-loaded namespace in place, so calling through a captured namespace
// object at delegation time can recurse into the mock itself.
const dbClientModule = await import("../db/client");
const realCloudDb = dbClientModule.cloudDb;
const realCloseCloudDbForTests = dbClientModule.closeCloudDbForTests;
const realCreateAwsRdsIamPool = dbClientModule.createAwsRdsIamPool;
const runDbTests = process.env.CMUX_DB_TEST === "1";
const dbTest = runDbTests ? test : test.skip;

process.env.SKIP_ENV_VALIDATION = "1";
process.env.VERCEL = "1";
process.env.CMUX_APNS_KEY_P8 = "test-key";
process.env.CMUX_APNS_KEY_ID = "test-key-id";
process.env.CMUX_APNS_TEAM_ID = "test-team-id";

const getUser = mock(async () => ({
  id: "user-1",
  displayName: null,
  primaryEmail: null,
  selectedTeam: null,
}));
const checkRateLimit = mock(async () => ({ rateLimited: true, error: null }));
const cloudDb = mock(() => {
  throw new Error("cloudDb should not be reached for invalid JSON");
});
let useStubDb = false;
let sql: Sql | null = null;
let scriptedSendOutcomes: Array<Array<{
  targetId?: string;
  deviceToken: string;
  status: number;
  reason?: string;
  retryAfterSeconds?: number;
  prune: boolean;
}>> = [];
let beforeNextSend: (() => Promise<void>) | null = null;
let failIfSendReceivesAbortedSignal = false;
const sendApnsNotificationReliably = mock(
  async (...args: unknown[]) => {
    const hook = beforeNextSend;
    beforeNextSend = null;
    if (hook) await hook();
    const options = args[3] as { readonly signal?: AbortSignal } | undefined;
    if (failIfSendReceivesAbortedSignal && options?.signal?.aborted) {
      throw options.signal.reason ?? new DOMException("Aborted", "AbortError");
    }
    const scripted = scriptedSendOutcomes.shift();
    if (scripted) return scripted;
    const targets = args[1] as readonly { deviceToken: string }[];
    return targets.map((target) => ({
      deviceToken: target.deviceToken,
      status: 200,
      prune: false,
    }));
  },
);

mock.module("../app/lib/stack", () => ({
  getStackServerApp: () => ({ getUser }),
  isStackConfigured: () => true,
  stackServerApp: { getUser },
}));

mock.module("@vercel/firewall", () => ({
  checkRateLimit,
}));

mock.module("../db/client", () => ({
  createAwsRdsIamPool: realCreateAwsRdsIamPool,
  closeCloudDbForTests: realCloseCloudDbForTests,
  cloudDb: (() =>
    useStubDb
      ? (cloudDb() as unknown as ReturnType<typeof realCloudDb>)
      : realCloudDb()) as typeof realCloudDb,
}));

const pushRoute = await import("../app/api/notifications/push/route");

beforeAll(() => {
  useStubDb = true;
  if (!runDbTests) return;
  const databaseURL = process.env.DIRECT_DATABASE_URL ?? process.env.DATABASE_URL;
  if (!databaseURL) {
    throw new Error("DATABASE_URL is required when CMUX_DB_TEST=1");
  }
  sql = postgres(databaseURL, { max: 1 });
});

afterAll(async () => {
  useStubDb = false;
  await realCloseCloudDbForTests();
  await sql?.end();
  for (const key of envKeys) {
    const value = originalEnv[key];
    if (typeof value === "undefined") {
      delete process.env[key];
    } else {
      process.env[key] = value;
    }
  }
});

beforeEach(async () => {
  // Re-assert the env each test rather than relying only on the module-top-level
  // assignment. bun runs every test file in one process, and other suites
  // (e.g. vm-route-auth) capture+restore process.env.VERCEL, so depending on
  // file load order they can delete VERCEL before these tests run — which made
  // the route skip rate-limiting and flaked this suite in CI.
  process.env.SKIP_ENV_VALIDATION = "1";
  process.env.VERCEL = "1";
  process.env.CMUX_APNS_KEY_P8 = "test-key";
  process.env.CMUX_APNS_KEY_ID = "test-key-id";
  process.env.CMUX_APNS_TEAM_ID = "test-team-id";
  getUser.mockClear();
  checkRateLimit.mockClear();
  checkRateLimit.mockResolvedValue({ rateLimited: true, error: null });
  cloudDb.mockClear();
  sendApnsNotificationReliably.mockClear();
  scriptedSendOutcomes = [];
  beforeNextSend = null;
  failIfSendReceivesAbortedSignal = false;
  useStubDb = true;
  if (sql) {
    await sql`
      delete from account_deletion_tombstones
      where user_id = 'user-1'
    `;
  }
});

describe("notifications push route", () => {
  test("budgets enough platform and lease time for the bounded APNs retry loop", () => {
    expect(pushRoute.maxDuration * 1_000)
      .toBeGreaterThan(APNS_DEFAULT_MAX_DELIVERY_DURATION_MS);
    expect(PUSH_SEND_LEASE_MS)
      .toBeGreaterThan(pushRoute.maxDuration * 1_000);
    expect(DEVICE_DELIVERY_LEASE_MS)
      .toBeGreaterThan(pushRoute.maxDuration * 1_000);
    expect(pushRoute.DEFAULT_PUSH_TTL_SECONDS * 1_000)
      .toBeGreaterThan(PUSH_SEND_LEASE_MS);
  });

  test("uses the database user limiter as the only in-code limiter", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: true, error: "blocked" });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: "{",
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_json" });
    expect(checkRateLimit).not.toHaveBeenCalled();
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("rejects an invalid target namespace before DB access", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "dev.cmux.ios.invalid_target",
        },
        body: JSON.stringify({ title: "Agent", body: "Done" }),
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "invalid_target_namespace",
    });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  test("a missing target namespace is treated as legacy, not rejected", async () => {
    // Macs older than the namespace rollout (0.64.x) never send the header.
    // Rejecting them kills phone push forwarding for the whole legacy fleet,
    // so a header-less request must proceed to delivery instead of 400ing.
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({ title: "Agent", body: "Done" }),
      }),
    );

    expect(response.status).not.toBe(400);
    expect(cloudDb).toHaveBeenCalled();
  });

  dbTest("a header-less legacy Mac fans out to every registered iOS token", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production'),
        ('user-1', ${"b".repeat(64)}, 'ios', 'dev.cmux.app.beta', 'production'),
        ('user-1', ${"c".repeat(64)}, 'ios', 'dev.cmux.ios.tsgate', 'sandbox')
    `;

    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId: "7f1f7a48-9f38-4a0f-9a71-a4c14f0f6d59",
        }),
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(response.status).toBe(200);
    const targets = (
      (sendApnsNotificationReliably as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls[0]?.[1] as Array<{
        deviceToken: string;
        bundleId: string;
        environment: string;
      }>
    );
    // Pre-namespace reach: every token the account registered, each keeping
    // its own bundle topic AND environment, exactly like delivery before the
    // namespace header existed.
    expect(targets).toHaveLength(3);
    expect(
      new Set(targets.map((target) => `${target.bundleId}|${target.environment}`)),
    ).toEqual(new Set([
      "com.cmux.app|production",
      "dev.cmux.app.beta|production",
      "dev.cmux.ios.tsgate|sandbox",
    ]));
  });

  test("an explicitly empty target namespace is rejected, not legacy", async () => {
    checkRateLimit.mockResolvedValue({ rateLimited: false, error: null });
    const response = await pushRoute.POST(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "",
        },
        body: JSON.stringify({ title: "Agent", body: "Done" }),
      }),
    );

    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: "invalid_target_namespace",
    });
    expect(cloudDb).not.toHaveBeenCalled();
  });

  dbTest("delivers to BETA without selecting INTERNAL tokens", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    const sharedToken = "a".repeat(64);
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${sharedToken}, 'ios', 'dev.cmux.app.beta', 'production'),
        ('user-1', ${sharedToken}, 'ios', 'dev.cmux.app.internal', 'production')
    `;

    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "dev.cmux.app.beta",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId: "ca04d429-a0a8-42ed-a5ef-74589bf5db28",
        }),
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(response.status).toBe(200);
    const targets = (
      (sendApnsNotificationReliably as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls[0]?.[1] as Array<{
        targetId: string;
        deviceToken: string;
        bundleId: string;
        environment: string;
      }>
    );
    expect(targets).toHaveLength(1);
    expect(targets[0]).toMatchObject({
      deviceToken: sharedToken,
      bundleId: "dev.cmux.app.beta",
      environment: "production",
    });
    expect(typeof targets[0]?.targetId).toBe("string");
  });

  test("keeps correlation on unexpected failures after payload parsing", async () => {
    const correlationId = "db86fe5c-71f8-43bd-92e3-9347df3aab5c";
    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "private terminal output",
          correlationId,
        }),
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(response.status).toBe(500);
    expect(response.headers.get("x-cmux-push-correlation-id"))
      .toBe(correlationId);
    const body = await response.json();
    expect(body).toEqual({
      error: "push_internal_error",
      correlationId,
    });
    expect(JSON.stringify(body)).not.toContain("private terminal output");
    expect(JSON.stringify(body)).not.toContain("cloudDb should not be reached");
  });

  dbTest("persists partial outcomes and retries only the unresolved token", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production'),
        ('user-1', ${"b".repeat(64)}, 'ios', 'com.cmux.app', 'production')
    `;

    scriptedSendOutcomes = [
      [
        {
          deviceToken: "a".repeat(64),
          status: 200,
          prune: false,
        },
        {
          deviceToken: "b".repeat(64),
          status: 503,
          reason: "ServiceUnavailable",
          prune: false,
        },
      ],
      [
        {
          deviceToken: "b".repeat(64),
          status: 200,
          prune: false,
        },
      ],
    ];

    const correlationId = "4d02de48-a21d-4ba1-97b5-42e9400ee09b";
    const expirationEpochSeconds = Math.floor(Date.now() / 1000) + 120;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    const partial = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(partial.status).toBe(200);
    expect(await partial.json()).toMatchObject({
      sent: 1,
      devices: 2,
      transientFailures: 1,
      correlationId,
    });
    await sql`
      update notification_send_events
      set retry_not_before = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;

    let releaseRetry!: () => void;
    let markRetryStarted!: () => void;
    const retryStarted = new Promise<void>((resolve) => {
      markRetryStarted = resolve;
    });
    const retryReleased = new Promise<void>((resolve) => {
      releaseRetry = resolve;
    });
    beforeNextSend = async () => {
      markRetryStarted();
      await retryReleased;
    };

    const recoveredPromise = pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    await retryStarted;
    const concurrent = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(concurrent.status).toBe(409);
    expect(await concurrent.json()).toMatchObject({
      error: "push_event_in_progress",
      correlationId,
    });
    releaseRetry();
    const recovered = await recoveredPromise;
    expect(recovered.status).toBe(200);
    expect(await recovered.json()).toMatchObject({
      sent: 2,
      devices: 2,
      transientFailures: 0,
      correlationId,
    });
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(2);
    const retryTargets = (
      (sendApnsNotificationReliably as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls[1]?.[1] as Array<{ deviceToken: string }>
    );
    expect(retryTargets.map((target) => target.deviceToken))
      .toEqual(["b".repeat(64)]);

    const [stored] = await sql<{ total: number }[]>`
      select count(*)::int as total
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    expect(stored?.total).toBe(1);
    const [persisted] = await sql<{
      initialTargets: string;
      outcomes: string;
    }[]>`
      select
        coalesce(initial_targets::text, '') as "initialTargets",
        coalesce(result_outcomes::text, '') as outcomes
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    expect(persisted?.initialTargets).not.toContain("a".repeat(64));
    expect(persisted?.initialTargets).not.toContain("b".repeat(64));
    expect(persisted?.outcomes).not.toContain("a".repeat(64));
    expect(persisted?.outcomes).not.toContain("b".repeat(64));
  });

  dbTest("an unconfigured provider releases the claim for an honest retry", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    const correlationId = "d0c5aeef-950a-477e-bbd2-a656229f44be";
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
        }),
      },
    );
    const first = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
      null,
    );
    const second = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
      null,
    );

    expect(first.status).toBe(503);
    expect(second.status).toBe(503);
    expect(await first.json()).toMatchObject({
      error: "push_service_not_configured",
    });
    expect(await second.json()).toMatchObject({
      error: "push_service_not_configured",
    });
  });

  dbTest("clamps a persisted provider backoff to the event TTL and returns its remaining Retry-After", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    scriptedSendOutcomes = [[{
      deviceToken: "a".repeat(64),
      status: 503,
      reason: "ServiceUnavailable",
      retryAfterSeconds: 900,
      prune: false,
    }]];
    const correlationId = "2103504c-c64e-4017-941f-7703033da85c";
    const expirationEpochSeconds = Math.floor(Date.now() / 1_000) + 1_800;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    const first = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(first.status).toBe(200);
    const firstBody = await first.json() as { retryAfterSeconds?: number };
    expect(firstBody).toMatchObject({ transientFailures: 1 });
    expect(firstBody.retryAfterSeconds ?? 0).toBeGreaterThanOrEqual(30);
    const [retryWindow] = await sql<{
      retryNotBefore: Date;
      expiresAt: Date;
    }[]>`
      select
        retry_not_before as "retryNotBefore",
        expires_at as "expiresAt"
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    if (!retryWindow) throw new Error("retry window was not persisted");
    expect(
      retryWindow.expiresAt.getTime() - retryWindow.retryNotBefore.getTime(),
    ).toBeGreaterThanOrEqual(APNS_DEFAULT_MAX_DELIVERY_DURATION_MS + 1_000);

    const deferred = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(deferred.status).toBe(409);
    const deferredRetryAfter = Number(deferred.headers.get("retry-after"));
    expect(deferredRetryAfter).toBeGreaterThan(0);
    expect(deferredRetryAfter).toBeLessThanOrEqual(
      firstBody.retryAfterSeconds ?? 0,
    );
    expect(await deferred.json()).toEqual({
      error: "push_event_in_progress",
      correlationId,
    });
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(1);
  });

  dbTest("finalizes a deferred transient outcome when its event expires", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    scriptedSendOutcomes = [[{
      deviceToken: "a".repeat(64),
      status: 503,
      reason: "ServiceUnavailable",
      retryAfterSeconds: 60,
      prune: false,
    }]];
    const correlationId = "530f66c4-095c-4648-8de5-852eac34b578";
    const expirationEpochSeconds = Math.floor(Date.now() / 1_000) + 120;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    const first = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(await first.json()).toMatchObject({ transientFailures: 1 });
    await sql`
      update notification_send_events
      set expires_at = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;

    const replay = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(replay.status).toBe(200);
    expect(replay.headers.get("x-cmux-push-replayed")).toBe("true");
    expect(await replay.json()).toMatchObject({
      devices: 1,
      transientFailures: 0,
      permanentFailures: 1,
      correlationId,
    });
    expect(replay.headers.get("retry-after")).toBeNull();
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(1);

    const [stored] = await sql<{
      summary: {
        transientFailures: number;
        permanentFailures: number;
        retryAfterSeconds?: number;
      };
      outcomes: Array<{
        status: number;
        reason?: string;
        retryAfterSeconds?: number;
        prune: boolean;
      }>;
      retryNotBefore: Date | null;
    }[]>`
      select
        result_summary as summary,
        result_outcomes as outcomes,
        retry_not_before as "retryNotBefore"
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    expect(stored?.summary).toMatchObject({
      transientFailures: 0,
      permanentFailures: 1,
    });
    expect(stored?.summary.retryAfterSeconds).toBeUndefined();
    expect(stored?.outcomes[0]).toMatchObject({
      status: 0,
      reason: "event_expired",
      prune: false,
    });
    expect(stored?.outcomes[0]?.retryAfterSeconds).toBeUndefined();
    expect(stored?.retryNotBefore).toBeNull();
  });

  dbTest("expires provider backoff that cannot fit before the event TTL", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    scriptedSendOutcomes = [[{
      deviceToken: "a".repeat(64),
      status: 503,
      reason: "ServiceUnavailable",
      retryAfterSeconds: 900,
      prune: false,
    }]];
    const correlationId = "95e94601-0974-44ef-95b9-607e031345e1";
    const expirationEpochSeconds = Math.floor(Date.now() / 1_000) + 45;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    const first = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(first.status).toBe(200);
    expect(await first.json()).toMatchObject({
      transientFailures: 0,
      permanentFailures: 1,
      correlationId,
    });
    expect(first.headers.get("retry-after")).toBeNull();

    const replay = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(replay.status).toBe(200);
    expect(await replay.json()).toMatchObject({
      transientFailures: 0,
      permanentFailures: 1,
      correlationId,
    });
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(1);
  });

  dbTest("durable APNs delivery is not cancelled by a client abort", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"b".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    const controller = new AbortController();
    const correlationId = "878aa598-9658-40e1-a8dd-d11885a8c0c8";
    failIfSendReceivesAbortedSignal = true;
    beforeNextSend = async () => {
      controller.abort(new DOMException("client left", "AbortError"));
    };

    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
        }),
        signal: controller.signal,
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      sent: 1,
      transientFailures: 0,
      correlationId,
    });
    const [record] = await sql<{ leaseUntil: Date | null }[]>`
      select lease_until as "leaseUntil"
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    expect(record?.leaseUntil).toBeNull();
  });

  dbTest("takes over a stale retry lease without resending a recorded success", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production'),
        ('user-1', ${"b".repeat(64)}, 'ios', 'com.cmux.app', 'production')
    `;
    scriptedSendOutcomes = [
      [
        {
          deviceToken: "a".repeat(64),
          status: 200,
          prune: false,
        },
        {
          deviceToken: "b".repeat(64),
          status: 503,
          reason: "ServiceUnavailable",
          prune: false,
        },
      ],
      [
        {
          deviceToken: "b".repeat(64),
          status: 200,
          prune: false,
        },
      ],
    ];
    const correlationId = "527e7ed5-b70d-45d8-a78e-fd032ae61ff5";
    const expirationEpochSeconds = Math.floor(Date.now() / 1000) + 120;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    await sql`
      update notification_send_events
      set
        lease_until = now() - interval '1 second',
        retry_not_before = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;

    const recovered = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(await recovered.json()).toMatchObject({
      sent: 2,
      devices: 2,
      transientFailures: 0,
    });
    const retryTargets = (
      (sendApnsNotificationReliably as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls[1]?.[1] as Array<{ deviceToken: string }>
    );
    expect(retryTargets.map((target) => target.deviceToken))
      .toEqual(["b".repeat(64)]);
  });

  dbTest("reuses the persisted event expiration when the client omitted it", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    scriptedSendOutcomes = [
      [{
        deviceToken: "a".repeat(64),
        status: 503,
        reason: "ServiceUnavailable",
        prune: false,
      }],
      [{
        deviceToken: "a".repeat(64),
        status: 200,
        prune: false,
      }],
    ];
    const correlationId = "c622f143-bbdb-4ec5-a1fd-fd3e8e541417";
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
        }),
      },
    );

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    await sql`
      update notification_send_events
      set
        expires_at = date_trunc('second', now()) + interval '30 seconds',
        lease_until = now() - interval '1 second',
        retry_not_before = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    const [stored] = await sql<{ expiration: number }[]>`
      select extract(epoch from expires_at)::int as expiration
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    const retryPayload = (
      (sendApnsNotificationReliably as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls[1]?.[2] as {
        expirationEpochSeconds: number;
      }
    );
    expect(retryPayload.expirationEpochSeconds).toBe(stored?.expiration);
  });

  dbTest("stale takeover without a summary keeps the claimed expiration", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    const correlationId = "0eb814aa-5b3b-4776-a4e8-f45f57c4f51f";
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
        }),
      },
    );
    beforeNextSend = async () => {
      throw new Error("simulated worker loss");
    };

    const interrupted = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(interrupted.status).toBe(500);
    expect(interrupted.headers.get("x-cmux-push-correlation-id"))
      .toBe(correlationId);
    expect(await interrupted.json()).toEqual({
      error: "push_internal_error",
      correlationId,
    });
    await sql`
      update notification_send_events
      set
        expires_at = date_trunc('second', now()) + interval '30 seconds',
        lease_until = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    const [stored] = await sql<{ expiration: number }[]>`
      select extract(epoch from expires_at)::int as expiration
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    scriptedSendOutcomes = [[{
      deviceToken: "a".repeat(64),
      status: 200,
      prune: false,
    }]];

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    const retryPayload = (
      (sendApnsNotificationReliably as unknown as {
        mock: { calls: unknown[][] };
      }).mock.calls[1]?.[2] as {
        expirationEpochSeconds: number;
      }
    );
    expect(retryPayload.expirationEpochSeconds).toBe(stored?.expiration);
  });

  dbTest("a frozen empty recipient set excludes devices registered later", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    const correlationId = "7e278f1d-4f9d-4d1e-9695-55db39373319";
    const expirationEpochSeconds = Math.floor(Date.now() / 1_000) + 120;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    await sql`
      update notification_send_events
      set
        result_summary = null,
        result_outcomes = null,
        lease_until = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"c".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;

    const recovered = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(await recovered.json()).toMatchObject({
      sent: 0,
      devices: 0,
    });
    expect(sendApnsNotificationReliably).not.toHaveBeenCalled();
  });

  dbTest("a changed topic or environment is not the frozen target", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    scriptedSendOutcomes = [[{
      deviceToken: "a".repeat(64),
      status: 503,
      reason: "ServiceUnavailable",
      prune: false,
    }]];
    const correlationId = "58f663e4-72f4-4904-82da-02c45bcb576f";
    const expirationEpochSeconds = Math.floor(Date.now() / 1_000) + 120;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    await sql`
      update device_tokens
      set bundle_id = 'dev.cmux.ios.push1', environment = 'sandbox'
      where user_id = 'user-1' and device_token = ${"a".repeat(64)}
    `;
    await sql`
      update notification_send_events
      set retry_not_before = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;

    const reconciled = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(await reconciled.json()).toMatchObject({
      sent: 0,
      devices: 1,
      transientFailures: 0,
      permanentFailures: 1,
    });
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(1);
  });

  dbTest("freezes recipients and terminally resolves a device removed before retry", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production'),
        ('user-1', ${"b".repeat(64)}, 'ios', 'com.cmux.app', 'production')
    `;
    scriptedSendOutcomes = [[
      { deviceToken: "a".repeat(64), status: 200, prune: false },
      {
        deviceToken: "b".repeat(64),
        status: 503,
        reason: "ServiceUnavailable",
        prune: false,
      },
    ]];
    const correlationId = "8c797e1a-797a-47cc-a995-30cffdfbe423";
    const expirationEpochSeconds = Math.floor(Date.now() / 1000) + 120;
    const request = () => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId,
          expirationEpochSeconds,
        }),
      },
    );

    await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    await sql`delete from device_tokens where device_token = ${"b".repeat(64)}`;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"c".repeat(64)}, 'ios', 'com.cmux.app', 'production')
    `;
    await sql`
      update notification_send_events
      set retry_not_before = now() - interval '1 second'
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;

    const reconciled = await pushRoute.sendPushWithTransport(
      request(),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(await reconciled.json()).toMatchObject({
      sent: 1,
      devices: 2,
      transientFailures: 0,
      permanentFailures: 1,
      correlationId,
    });
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(1);

    const [stored] = await sql<{
      outcomes: Array<{
        targetId: string;
        status: number;
        reason?: string;
        prune: boolean;
      }>;
    }[]>`
      select result_outcomes as outcomes
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    const removed = stored?.outcomes.find(
      (result) => result.reason === "target_no_longer_registered",
    );
    expect(removed).toMatchObject({
      status: 404,
      reason: "target_no_longer_registered",
      prune: false,
    });
    expect(removed?.targetId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
    );
    expect(JSON.stringify(stored?.outcomes)).not.toContain("b".repeat(64));
    expect(JSON.stringify(stored?.outcomes)).not.toContain("c".repeat(64));
  });

  dbTest("binds a correlation id to one content-safe logical payload fingerprint", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production')
    `;
    const correlationId = "f57948e6-4456-4057-8820-b56af13faee9";
    const expirationEpochSeconds = Math.floor(Date.now() / 1000) + 120;
    const makeRequest = (body: Record<string, unknown>) => new Request(
      "https://cmux.test/api/notifications/push",
      {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          correlationId,
          expirationEpochSeconds,
          ...body,
        }),
      },
    );
    const original = {
      title: "agent",
      body: "secret original body",
      notificationId: "notice-1",
    };

    expect((await pushRoute.sendPushWithTransport(
      makeRequest(original),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    )).status).toBe(200);
    const replay = await pushRoute.sendPushWithTransport(
      makeRequest(original),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(replay.status).toBe(200);
    expect(replay.headers.get("x-cmux-push-replayed")).toBe("true");

    const changedBody = await pushRoute.sendPushWithTransport(
      makeRequest({ ...original, body: "different secret body" }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(changedBody.status).toBe(409);
    expect(
      changedBody.headers.get("x-cmux-push-correlation-id"),
    ).toBe(correlationId);
    expect(await changedBody.json()).toEqual({
      error: "correlation_payload_mismatch",
      correlationId,
    });
    const changedKind = await pushRoute.sendPushWithTransport(
      makeRequest({
        kind: "dismiss",
        title: "",
        body: "",
        notificationIds: ["notice-1"],
        badgeCount: 0,
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(changedKind.status).toBe(409);
    expect(sendApnsNotificationReliably).toHaveBeenCalledTimes(1);

    const [stored] = await sql<{
      fingerprint: string;
      rowText: string;
    }[]>`
      select
        payload_fingerprint as fingerprint,
        row_to_json(notification_send_events)::text as "rowText"
      from notification_send_events
      where user_id = 'user-1' and correlation_id = ${correlationId}
    `;
    expect(stored?.fingerprint).toMatch(/^[a-f0-9]{64}$/);
    expect(stored?.rowText).not.toContain("secret original body");
    expect(stored?.rowText).not.toContain("different secret body");
  });

  dbTest("delivers to healthy rows and removes an impossible stored environment", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values
        ('user-1', ${"a".repeat(64)}, 'ios', 'com.cmux.app', 'production'),
        ('user-1', ${"b".repeat(64)}, 'ios', 'com.cmux.app', 'corrupt')
    `;
    scriptedSendOutcomes = [[
      { deviceToken: "a".repeat(64), status: 200, prune: false },
      {
        deviceToken: "b".repeat(64),
        status: 400,
        reason: "invalid_stored_environment",
        prune: true,
      },
    ]];

    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId: "e9228cf1-bf4e-4f1a-9a89-2962d1882c4d",
        }),
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(await response.json()).toMatchObject({
      sent: 1,
      devices: 2,
      pruned: 1,
      permanentFailures: 1,
    });
    const registered = await sql<{ deviceToken: string }[]>`
      select device_token as "deviceToken"
      from device_tokens
      where user_id = 'user-1'
    `;
    expect(registered).toEqual([{ deviceToken: "a".repeat(64) }]);
  });

  dbTest("does not prune a token whose routing identity changed during delivery", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    scriptedSendOutcomes = [[{
      deviceToken: "a".repeat(64),
      status: 410,
      reason: "Unregistered",
      prune: true,
    }]];
    const testSql = sql;
    beforeNextSend = async () => {
      await testSql`
        update device_tokens
        set bundle_id = 'dev.cmux.ios.push1', environment = 'sandbox'
        where user_id = 'user-1' and device_token = ${"a".repeat(64)}
      `;
    };

    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId: "faef4983-0ce5-4543-822b-0af2f4495386",
        }),
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ pruned: 0 });
    const [registered] = await sql<{
      bundleId: string;
      environment: string;
    }[]>`
      select bundle_id as "bundleId", environment
      from device_tokens
      where user_id = 'user-1' and device_token = ${"a".repeat(64)}
    `;
    expect(registered).toEqual({
      bundleId: "dev.cmux.ios.push1",
      environment: "sandbox",
    });
  });

  dbTest("a pending account deletion fences new phone delivery claims", async () => {
    if (!sql) throw new Error("test database not initialized");
    useStubDb = false;
    await sql`
      truncate device_tokens, notification_send_events,
        account_deletion_tombstones restart identity cascade
    `;
    await sql`
      insert into device_tokens (
        user_id, device_token, platform, bundle_id, environment
      ) values (
        'user-1',
        ${"a".repeat(64)},
        'ios',
        'com.cmux.app',
        'production'
      )
    `;
    await sql`
      insert into account_deletion_tombstones (
        user_id_hash, user_id, status, updated_at
      ) values (
        ${accountDeletionUserHash("user-1")},
        'user-1',
        'pending',
        now()
      )
    `;

    const response = await pushRoute.sendPushWithTransport(
      new Request("https://cmux.test/api/notifications/push", {
        method: "POST",
        headers: {
          authorization: "Bearer access-token",
          "x-stack-refresh-token": "refresh-token",
          "x-cmux-ios-target-namespace": "com.cmux.app",
        },
        body: JSON.stringify({
          title: "agent",
          body: "done",
          correlationId: "a6e884c3-fc14-49c0-8ccb-b12a42b104ea",
        }),
      }),
      sendApnsNotificationReliably as Parameters<
        typeof pushRoute.sendPushWithTransport
      >[1],
    );

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "account_deletion_in_progress",
      correlationId: "a6e884c3-fc14-49c0-8ccb-b12a42b104ea",
    });
    expect(sendApnsNotificationReliably).not.toHaveBeenCalled();
    const [token] = await sql<{
      deliveryLeaseUntil: Date | null;
      deliveryLeaseToken: string | null;
    }[]>`
      select
        delivery_lease_until as "deliveryLeaseUntil",
        delivery_lease_token as "deliveryLeaseToken"
      from device_tokens
      where user_id = 'user-1'
    `;
    expect(token).toEqual({
      deliveryLeaseUntil: null,
      deliveryLeaseToken: null,
    });
  });
});
