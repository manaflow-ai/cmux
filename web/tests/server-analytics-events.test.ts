import { describe, expect, test } from "bun:test";

import {
  captureServerEvent,
  serverAnalyticsEnabled,
  serverEventPayload,
  SERVER_EVENT_LIB,
  STACK_TEAM_GROUP,
} from "../services/analytics/serverEvents";

type Sent = { url: string; body: Record<string, unknown> };

function collector(responses: number[] = [200]) {
  const sent: Sent[] = [];
  const deferred: Promise<unknown>[] = [];
  let call = 0;
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    sent.push({ url: String(input), body: JSON.parse(String(init?.body)) as Record<string, unknown> });
    const status = responses[Math.min(call, responses.length - 1)];
    call += 1;
    return new Response(null, { status });
  }) as unknown as typeof fetch;
  return {
    sent,
    deferred,
    dependencies: {
      fetch: fetchImpl,
      env: { CMUX_SERVER_ANALYTICS_FORCE: "1" },
      defer: (task: Promise<unknown>) => {
        deferred.push(task);
      },
      now: () => new Date("2026-09-03T00:00:00.000Z"),
    },
  };
}

describe("server event payload", () => {
  test("keys the event on the Stack user id and the stack_team group", () => {
    const payload = serverEventPayload({
      event: "cloud_vm_created",
      distinctId: "user-1",
      teamId: "team-1",
      properties: { vm_id: "vm-1", plan_id: "pro", dropped: null, also_dropped: undefined },
      set: { billing_plan: "pro" },
      setOnce: { cloud_vm_first_created_at: "2026-09-03T00:00:00.000Z" },
      insertId: "cloud_vm_created:vm-1",
    }, new Date("2026-09-03T00:00:00.000Z"));
    expect(payload).toMatchObject({
      event: "cloud_vm_created",
      distinct_id: "user-1",
      timestamp: "2026-09-03T00:00:00.000Z",
    });
    const properties = payload!.properties as Record<string, unknown>;
    expect(properties).toMatchObject({
      vm_id: "vm-1",
      plan_id: "pro",
      $lib: SERVER_EVENT_LIB,
      $insert_id: "cloud_vm_created:vm-1",
      $geoip_disable: true,
      $groups: { [STACK_TEAM_GROUP]: "team-1" },
      $set: { billing_plan: "pro" },
      $set_once: { cloud_vm_first_created_at: "2026-09-03T00:00:00.000Z" },
    });
    expect("dropped" in properties).toBe(false);
    expect("also_dropped" in properties).toBe(false);
  });

  test("an event without a person is dropped", () => {
    expect(serverEventPayload({ event: "x", distinctId: "   " })).toBeNull();
  });

  test("no team means no group, and empty $set blocks are omitted", () => {
    const payload = serverEventPayload({ event: "x", distinctId: "user-1", teamId: null });
    const properties = payload!.properties as Record<string, unknown>;
    expect("$groups" in properties).toBe(false);
    expect("$set" in properties).toBe(false);
    expect("$set_once" in properties).toBe(false);
    expect(typeof properties.$insert_id).toBe("string");
  });

  test("long strings are bounded", () => {
    const payload = serverEventPayload({ event: "x", distinctId: "u", properties: { text: "a".repeat(2_000) } });
    expect(String((payload!.properties as Record<string, unknown>).text)).toHaveLength(500);
  });
});

describe("server event delivery", () => {
  test("posts to /capture/ and defers the task past the response", async () => {
    const collected = collector();
    await captureServerEvent({ event: "cloud_vm_created", distinctId: "user-1" }, collected.dependencies);
    expect(collected.sent).toHaveLength(1);
    expect(collected.sent[0].url).toMatch(/\/capture\/$/);
    expect(collected.sent[0].body).toMatchObject({ event: "cloud_vm_created", distinct_id: "user-1" });
    expect(collected.deferred).toHaveLength(1);
  });

  test("retries once on a transient status and never rejects", async () => {
    const collected = collector([503, 200]);
    await captureServerEvent({ event: "x", distinctId: "user-1" }, collected.dependencies);
    expect(collected.sent).toHaveLength(2);
    const failing = collector([503, 503]);
    await expect(captureServerEvent({ event: "x", distinctId: "user-1" }, failing.dependencies)).resolves.toBeUndefined();
    expect(failing.sent).toHaveLength(2);
    const rejected = collector([400]);
    await captureServerEvent({ event: "x", distinctId: "user-1" }, rejected.dependencies);
    expect(rejected.sent).toHaveLength(1);
  });

  test("is off outside production unless forced", async () => {
    const collected = collector();
    await captureServerEvent(
      { event: "x", distinctId: "user-1" },
      { ...collected.dependencies, env: { VERCEL_ENV: "preview" } },
    );
    expect(collected.sent).toHaveLength(0);
    expect(serverAnalyticsEnabled({ VERCEL_ENV: "production" })).toBe(true);
    expect(serverAnalyticsEnabled({ VERCEL_ENV: "preview" })).toBe(false);
    expect(serverAnalyticsEnabled({ CMUX_SERVER_ANALYTICS_FORCE: "1" })).toBe(true);
  });

  test("a test run without an injected fetch never reaches the transport", async () => {
    // process.env in bun test carries the test markers, and no fetch is injected here.
    await expect(captureServerEvent({ event: "x", distinctId: "user-1" }, {
      env: { ...process.env, CMUX_SERVER_ANALYTICS_FORCE: "1" },
    })).resolves.toBeUndefined();
  });
});
