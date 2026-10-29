import { describe, expect, test } from "bun:test";

import {
  captureServerEvent,
  isSecurePosthogHost,
  isAllowedPosthogHost,
  serverAnalyticsEnabled,
  serverEventPayload,
  SERVER_EVENT_LIB,
  STACK_TEAM_GROUP,
  type ServerEventTask,
} from "../services/analytics/serverEvents";

type Sent = { url: string; body: Record<string, unknown> };

function collector(responses: number[] = [200]) {
  const sent: Sent[] = [];
  const deferred: Array<() => Promise<void>> = [];
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
      defer: (task: ServerEventTask) => {
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
    expect(serverEventPayload({ event: "x", distinctId: "person@example.com" })).toBeNull();
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
  test("does not start the fetch before the deferred callback runs", async () => {
    const calls: string[] = [];
    const deferred: Array<() => Promise<void>> = [];
    const fetchImpl = (async (input: string | URL | Request) => {
      calls.push(String(input));
      return new Response(null, { status: 200 });
    }) as unknown as typeof fetch;
    const delivery = captureServerEvent(
      { event: "cloud_vm_created", distinctId: "user-1" },
      {
        fetch: fetchImpl,
        env: { CMUX_SERVER_ANALYTICS_FORCE: "1" },
        defer: (task: ServerEventTask) => deferred.push(task),
        now: () => new Date("2026-09-03T00:00:00.000Z"),
      },
    );

    expect(calls).toHaveLength(0);
    expect(deferred).toHaveLength(1);
    await deferred[0]!();
    await delivery;
    expect(calls).toHaveLength(1);
  });

  test("posts to /capture/ and defers the task past the response", async () => {
    const collected = collector();
    const delivery = captureServerEvent({ event: "cloud_vm_created", distinctId: "user-1" }, collected.dependencies);
    expect(collected.sent).toHaveLength(0);
    expect(collected.deferred).toHaveLength(1);
    await collected.deferred[0]!();
    await delivery;
    expect(collected.sent).toHaveLength(1);
    expect(collected.sent[0]!.url).toMatch(/\/capture\/$/);
    expect(collected.sent[0]!.body).toMatchObject({ event: "cloud_vm_created", distinct_id: "user-1" });
  });

  test("retries once on a transient status and never rejects", async () => {
    const collected = collector([503, 200]);
    const first = captureServerEvent({ event: "x", distinctId: "user-1" }, collected.dependencies);
    await collected.deferred.shift()!();
    await first;
    expect(collected.sent).toHaveLength(2);
    const failing = collector([503, 503]);
    const failingDelivery = captureServerEvent({ event: "x", distinctId: "user-1" }, failing.dependencies);
    await failing.deferred[0]!();
    await expect(failingDelivery).resolves.toBeUndefined();
    expect(failing.sent).toHaveLength(2);
    const rejected = collector([400]);
    const rejectedDelivery = captureServerEvent({ event: "x", distinctId: "user-1" }, rejected.dependencies);
    await rejected.deferred[0]!();
    await rejectedDelivery;
    expect(rejected.sent).toHaveLength(1);
  });

  test("rejects a non-HTTPS PostHog host before fetching", async () => {
    const collected = collector();
    const delivery = captureServerEvent(
      { event: "x", distinctId: "user-1" },
      {
        ...collected.dependencies,
        env: { CMUX_SERVER_ANALYTICS_FORCE: "1", POSTHOG_HOST: "http://posthog.invalid" },
      },
    );
    expect(collected.deferred).toHaveLength(1);
    await collected.deferred[0]!();
    await delivery;
    expect(collected.sent).toHaveLength(0);
  });

  test("does not follow an HTTP redirect from the PostHog host", async () => {
    let calls = 0;
    let redirectTargetCalls = 0;
    const deferred: Array<() => Promise<void>> = [];
    const origin = "https://posthog.example/capture/";
    const redirectTarget = "http://posthog.invalid/capture/";
    const fetchImpl = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
      calls += 1;
      if (String(input) === redirectTarget) {
        redirectTargetCalls += 1;
        return new Response(null, { status: 200 });
      }
      expect(String(input)).toBe(origin);
      expect(init?.redirect).toBe("error");
      const redirect = new Response(null, {
        status: 307,
        headers: { location: redirectTarget },
      });
      if (init?.redirect === "error") throw new TypeError("redirect rejected");
      return fetchImpl(redirect.headers.get("location")!, init);
    }) as unknown as typeof fetch;
    const delivery = captureServerEvent(
      { event: "x", distinctId: "user-1" },
      {
        fetch: fetchImpl,
        env: { CMUX_SERVER_ANALYTICS_FORCE: "1", POSTHOG_HOST: "https://posthog.example" },
        defer: (task) => deferred.push(task),
        now: () => new Date("2026-09-03T00:00:00.000Z"),
      },
    );

    await deferred[0]!();
    await delivery;
    // `deliver` retries transport failures, but both attempts stay on the
    // validated origin. The redirect target must never receive a request.
    expect(calls).toBe(2);
    expect(redirectTargetCalls).toBe(0);
  });

  test("a failing defer hook cannot reject the best-effort sender", async () => {
    const collected = collector();
    await expect(captureServerEvent(
      { event: "x", distinctId: "user-1" },
      { ...collected.dependencies, defer: () => { throw new Error("request scope closed"); } },
    )).resolves.toBeUndefined();
    expect(collected.sent).toHaveLength(1);
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

  test("accepts HTTPS hosts and rejects other URL schemes", () => {
    expect(isSecurePosthogHost("https://r.cmux.com")).toBe(true);
    expect(isSecurePosthogHost("http://r.cmux.com")).toBe(false);
    expect(isSecurePosthogHost("not a URL")).toBe(false);
  });

  test("allows HTTP only for the explicit loopback smoke harness", () => {
    expect(isAllowedPosthogHost("http://127.0.0.1:4318", { CMUX_SERVER_ANALYTICS_SMOKE: "1" })).toBe(true);
    expect(isAllowedPosthogHost("http://[::1]:4318", { CMUX_SERVER_ANALYTICS_SMOKE: "1" })).toBe(true);
    expect(isAllowedPosthogHost("http://127.0.0.1:4318", {})).toBe(false);
    expect(isAllowedPosthogHost("http://posthog.example", { CMUX_SERVER_ANALYTICS_SMOKE: "1" })).toBe(false);
  });
});
