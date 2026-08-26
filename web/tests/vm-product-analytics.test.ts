import { describe, expect, test } from "bun:test";

import {
  captureVmAnalyticsEvent,
  captureVmLimitHit,
  captureVmUsageEvents,
  captureVmWakeCompleted,
  sanitizedVmEventProperties,
  vmAnalyticsEnabled,
} from "../services/vms/productAnalytics";

const enabledEnv = { VERCEL_ENV: "production" } as const;

type CapturedRequest = { url: string; body: Record<string, unknown> };

function recordingFetch(captured: CapturedRequest[]): typeof fetch {
  return ((url: string | URL | Request, init?: RequestInit) => {
    captured.push({
      url: String(url),
      body: JSON.parse(String(init?.body)) as Record<string, unknown>,
    });
    return Promise.resolve(new Response("{}", { status: 200 }));
  }) as typeof fetch;
}

async function settled(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 0));
}

describe("vm product analytics transport", () => {
  test("swallows a rejecting transport", async () => {
    const failingFetch = (() =>
      Promise.reject(new Error("posthog unreachable"))) as unknown as typeof fetch;
    await expect(
      captureVmAnalyticsEvent(
        { event: "vm.created", distinctId: "user-1" },
        { fetchImpl: failingFetch, env: enabledEnv },
      ),
    ).resolves.toBeUndefined();
  });

  test("swallows a transport that throws synchronously", async () => {
    const throwingFetch = (() => {
      throw new Error("fetch exploded");
    }) as unknown as typeof fetch;
    await expect(
      captureVmAnalyticsEvent(
        { event: "vm.created", distinctId: "user-1" },
        { fetchImpl: throwingFetch, env: enabledEnv },
      ),
    ).resolves.toBeUndefined();
  });

  test("does nothing when analytics is not enabled", async () => {
    const captured: CapturedRequest[] = [];
    await captureVmAnalyticsEvent(
      { event: "vm.created", distinctId: "user-1" },
      { fetchImpl: recordingFetch(captured), env: {} },
    );
    expect(captured).toHaveLength(0);
    expect(vmAnalyticsEnabled({})).toBe(false);
    expect(vmAnalyticsEnabled({ VERCEL_ENV: "production" })).toBe(true);
    expect(vmAnalyticsEnabled({ CMUX_VM_ANALYTICS_FORCE: "1" })).toBe(true);
    expect(
      vmAnalyticsEnabled({ VERCEL_ENV: "production", CMUX_VM_ANALYTICS_DISABLED: "1" }),
    ).toBe(false);
  });

  test("sends the event with identity and scrubbed properties", async () => {
    const captured: CapturedRequest[] = [];
    await captureVmAnalyticsEvent(
      {
        event: "vm.created",
        distinctId: "user-1",
        properties: { provider: "freestyle" },
      },
      { fetchImpl: recordingFetch(captured), env: enabledEnv },
    );
    expect(captured).toHaveLength(1);
    expect(captured[0]!.url.endsWith("/capture/")).toBe(true);
    const body = captured[0]!.body;
    expect(body.event).toBe("vm.created");
    expect(body.distinct_id).toBe("user-1");
    const properties = body.properties as Record<string, unknown>;
    expect(properties.provider).toBe("freestyle");
    expect(properties.$geoip_disable).toBe(true);
    expect(typeof properties.$insert_id).toBe("string");
  });
});

describe("vm event property sanitizer", () => {
  test("keeps bounded scalars and drops everything sensitive or structured", () => {
    expect(
      sanitizedVmEventProperties({
        transport: "websocket",
        requireDaemon: true,
        port: 3000,
        snapshotId: null,
        token: "secret-value",
        cmuxToken: "secret-value",
        sshCredential: "secret-value",
        leaseId: "lease-123",
        apiKey: "secret-value",
        command: "curl https://internal | sh",
        commandLength: 24,
        nested: { deep: "object" },
        list: [1, 2, 3],
        big: "x".repeat(500),
      }),
    ).toEqual({
      transport: "websocket",
      requireDaemon: true,
      port: 3000,
      snapshotId: null,
      commandLength: 24,
      big: "x".repeat(200),
    });
  });
});

describe("usage-event chokepoint mirror", () => {
  test("forwards the persisted eventType with provider/image/plan context", async () => {
    const captured: CapturedRequest[] = [];
    captureVmUsageEvents(
      [
        {
          userId: "user-1",
          billingTeamId: "team-1",
          billingPlanId: "pro",
          vmId: "row-1",
          eventType: "vm.create.credit.reserved",
          provider: "freestyle",
          imageId: "cmux-base",
          metadata: { itemId: "vm-create", amount: 1 },
        },
      ],
      { fetchImpl: recordingFetch(captured), env: enabledEnv },
    );
    await settled();
    expect(captured).toHaveLength(1);
    const body = captured[0]!.body;
    expect(body.event).toBe("vm.create.credit.reserved");
    expect(body.distinct_id).toBe("user-1");
    const properties = body.properties as Record<string, unknown>;
    expect(properties.provider).toBe("freestyle");
    expect(properties.image).toBe("cmux-base");
    expect(properties.plan_id).toBe("pro");
    expect(properties.team_scoped).toBe(true);
    expect(properties.amount).toBe(1);
  });

  test("marks vm.attach as reattach when a session id was requested", async () => {
    const captured: CapturedRequest[] = [];
    captureVmUsageEvents(
      [
        {
          userId: "user-1",
          eventType: "vm.attach",
          metadata: { transport: "websocket", requestedSessionId: "session-1" },
        },
        {
          userId: "user-1",
          eventType: "vm.attach",
          metadata: { transport: "websocket", requestedSessionId: null },
        },
      ],
      { fetchImpl: recordingFetch(captured), env: enabledEnv },
    );
    await settled();
    expect(captured).toHaveLength(2);
    expect((captured[0]!.body.properties as Record<string, unknown>).reattach).toBe(true);
    expect((captured[1]!.body.properties as Record<string, unknown>).reattach).toBe(false);
  });

  test("never throws, even on hostile metadata and a broken transport", async () => {
    const throwingFetch = (() => {
      throw new Error("fetch exploded");
    }) as unknown as typeof fetch;
    const cyclic: Record<string, unknown> = {};
    cyclic.self = cyclic;
    expect(() =>
      captureVmUsageEvents(
        [{ userId: "user-1", eventType: "vm.created", metadata: cyclic }],
        { fetchImpl: throwingFetch, env: enabledEnv },
      ),
    ).not.toThrow();
    await settled();
  });
});

describe("wake latency", () => {
  test("vm.wake.completed rounds the latency and keeps the triggering verb", async () => {
    const captured: CapturedRequest[] = [];
    captureVmWakeCompleted(
      {
        userId: "user-1",
        provider: "freestyle",
        source: "attach",
        durationMs: 1234.56,
        reserved: false,
      },
      { fetchImpl: recordingFetch(captured), env: enabledEnv },
    );
    await settled();
    expect(captured).toHaveLength(1);
    expect(captured[0]!.body.event).toBe("vm.wake.completed");
    expect(captured[0]!.body.distinct_id).toBe("user-1");
    const properties = captured[0]!.body.properties as Record<string, unknown>;
    expect(properties.provider).toBe("freestyle");
    expect(properties.source).toBe("attach");
    expect(properties.duration_ms).toBe(1235);
    expect(properties.reserved).toBe(false);
  });
});

describe("paywall funnel", () => {
  test("vm.limit_hit carries the upgrade prompt flag", async () => {
    const captured: CapturedRequest[] = [];
    captureVmLimitHit(
      { userId: "user-1", planId: "free", limit: 3, upgradeShown: true, phase: "create" },
      { fetchImpl: recordingFetch(captured), env: enabledEnv },
    );
    await settled();
    expect(captured).toHaveLength(1);
    expect(captured[0]!.body.event).toBe("vm.limit_hit");
    const properties = captured[0]!.body.properties as Record<string, unknown>;
    expect(properties.plan_id).toBe("free");
    expect(properties.limit).toBe(3);
    expect(properties.upgrade_shown).toBe(true);
    expect(properties.phase).toBe("create");
  });
});
