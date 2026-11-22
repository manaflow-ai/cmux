import { describe, expect, mock, test } from "bun:test";

import {
  __test as analyticsTest,
  captureCoderouterEvent,
  captureCoderouterRawBatch,
} from "../services/coderouter/analytics";
import {
  __test as usageTest,
  isStreamingResponse,
} from "../services/coderouter/responseUsage";

const config = () => ({
  ingestHost: "https://posthog.test",
  projectKey: "phc_cmux_test",
});

function collector() {
  const bodies: string[] = [];
  const urls: string[] = [];
  const posthogFetch = mock(async (...args: unknown[]) => {
    urls.push(String(args[0]));
    bodies.push(String((args[1] as RequestInit | undefined)?.body));
    return new Response(null, { status: 200 });
  });
  const deferred: Promise<unknown>[] = [];
  const dependencies = {
    fetch: posthogFetch as typeof fetch,
    defer: (task: Promise<unknown>) => deferred.push(task),
    enabled: () => true,
    config,
  };
  return {
    bodies,
    urls,
    deferred,
    dependencies,
  };
}

describe("coderouter analytics", () => {
  test("does not send model usage to PostHog", async () => {
    const captured = collector();
    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        userId: "stack-user-raw",
        teamId: "team-raw",
        properties: {
          provider: "codex",
          model: "gpt-5.6-terra-private-customer-label",
          input_tokens: 8,
          cached_input_tokens: 3,
          output_tokens: 2,
          total_tokens: 10,
          prompt: "secret prompt",
          response_body: "secret output",
          route_token: "crt_secret",
          email: "buyer@example.com",
          provider_account_id: "acct_secret",
          url: "https://private.example/path?token=secret",
          headers: "authorization secret",
        },
      },
      captured.dependencies,
    );

    await Promise.all(captured.deferred);
    expect(captured.urls).toEqual([]);
    expect(captured.bodies).toEqual([]);
  });

  test("keys ops events by the Stack user and forwards only the closed schema", async () => {
    const captured = collector();
    captureCoderouterEvent(
      {
        event: "coderouter_account_added",
        userId: "raw-stack-user-id",
        teamId: "raw-team-id",
        properties: {
          provider: "codex",
          source: "native_api",
          already_exists: false,
          account_id: "raw-account-id",
          label: "Personal account",
          command_args: "--token raw-token",
          local_path: "/Users/private/project",
          error: "a raw free-form error",
        },
      },
      captured.dependencies,
    );

    await Promise.all(captured.deferred);
    const payload = JSON.parse(captured.bodies[0]!) as {
      api_key: string;
      batch: Array<{
        distinct_id: string;
        properties: Record<string, unknown>;
      }>;
    };
    const event = payload.batch[0]!;
    expect(payload.api_key).toBe("phc_cmux_test");
    expect(event.distinct_id).toBe("raw-stack-user-id");
    expect(event.properties).toMatchObject({
      provider: "codex",
      source: "native_api",
      already_exists: false,
      user_id: "raw-stack-user-id",
      team_id: "raw-team-id",
      $geoip_disable: true,
    });
    expect(Object.keys(event.properties).sort()).toEqual([
      "$geoip_disable",
      "$insert_id",
      "already_exists",
      "product",
      "provider",
      "schema_version",
      "service_version",
      "source",
      "team_id",
      "user_id",
    ]);
    expect(captured.bodies[0]).not.toContain("raw-account-id");
    expect(captured.bodies[0]).not.toContain("Personal account");
    expect(captured.bodies[0]).not.toContain("raw-token");
    expect(captured.bodies[0]).not.toContain("/Users/private/project");
    expect(captured.bodies[0]).not.toContain("free-form error");
  });

  test("keeps handoff analytics enum-only even when callers provide token-shaped fields", async () => {
    const captured = collector();
    captureCoderouterEvent(
      {
        event: "coderouter_handoff_lease_issued",
        userId: "raw-user",
        teamId: "raw-team",
        properties: {
          authorization_mode: "native_stack",
          lease: "crh_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
          token: "crt_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN",
        },
      },
      captured.dependencies,
    );
    captureCoderouterEvent(
      {
        event: "coderouter_handoff_lease_exchanged",
        userId: "raw-user",
        teamId: "raw-team",
        properties: {
          authorization_mode: "lease",
          lease: "crh_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
          route_token: "crt_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN",
        },
      },
      captured.dependencies,
    );

    await Promise.all(captured.deferred);
    expect(captured.bodies).toHaveLength(2);
    for (const body of captured.bodies) {
      expect(body).not.toContain("crh_");
      expect(body).not.toContain("crt_");
      const event = JSON.parse(body).batch[0];
      expect(event.distinct_id).toBe("raw-user");
      expect(event.properties.team_id).toBe("raw-team");
    }
  });

  test("fails closed for usage and ops when the project key is missing", () => {
    const defer = mock(() => {});
    const dependencies = {
      fetch,
      defer,
      enabled: () => true,
      config: () => null,
    };

    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        teamId: "team-1",
        properties: { provider: "codex", total_tokens: 10 },
      },
      dependencies,
    );
    captureCoderouterEvent(
      {
        event: "coderouter_auth_rejected",
        properties: { surface: "responses", reason: "invalid_route_token" },
      },
      dependencies,
    );

    expect(defer).not.toHaveBeenCalled();
  });

  test("drops zero-token completions and unauthenticated events keep no person", async () => {
    const captured = collector();
    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        userId: "stack-user-1",
        teamId: "team-1",
        properties: { provider: "codex", total_tokens: 0 },
      },
      captured.dependencies,
    );
    captureCoderouterEvent(
      {
        event: "coderouter_auth_rejected",
        properties: { surface: "responses", reason: "invalid_route_token", request_id: "must-not-leak" },
      },
      captured.dependencies,
    );
    await Promise.all(captured.deferred);
    expect(captured.bodies).toHaveLength(1);
    const event = JSON.parse(captured.bodies[0]!).batch[0];
    expect(event.event).toBe("coderouter_auth_rejected");
    expect(event.distinct_id).toBe("coderouter-server");
    expect(event.properties).toMatchObject({
      surface: "responses",
      reason: "invalid_route_token",
      $process_person_profile: false,
    });
    expect(captured.bodies[0]).not.toContain("must-not-leak");
  });

  test("keeps token and VM usage out of PostHog", () => {
    expect(
      analyticsTest.eventProperties("coderouter_auth_rejected", {
        surface: "responses",
        reason: "vm_mismatch",
      }),
    ).toEqual({ surface: "responses", reason: "vm_mismatch" });
    const captured = collector();
    captureCoderouterEvent({ event: "coderouter_model_request_completed", userId: "u", teamId: "t", properties: { total_tokens: 10, vm_id: "vm-1" } }, captured.dependencies);
    expect(captured.bodies).toHaveLength(0);
  });

  test("captures API-key lifecycle properties without forwarding raw input", async () => {
    const cases = [
      {
        event: "coderouter_api_key_created" as const,
        properties: { label: "private label" },
        expected: {},
      },
      {
        event: "coderouter_api_key_revoked" as const,
        properties: { self: true },
        expected: { self: true },
      },
      {
        event: "coderouter_api_key_listed" as const,
        properties: { key_count: 4 },
        expected: { key_count_bucket: "4-10" },
      },
      {
        event: "coderouter_api_key_revoked" as const,
        properties: { self: "invalid" },
        expected: { self: false },
      },
      {
        event: "coderouter_api_key_listed" as const,
        properties: { key_count: -1 },
        expected: { key_count_bucket: "0" },
      },
    ];

    for (const input of cases) {
      const { expected, ...captureInput } = input;
      const captured = collector();
      captureCoderouterEvent(
        { ...captureInput, userId: "stack-user-id", teamId: "team-id" },
        captured.dependencies,
      );
      await Promise.all(captured.deferred);
      const event = JSON.parse(captured.bodies[0]!).batch[0];
      expect(event.properties).toMatchObject({
        ...input.expected,
        user_id: "stack-user-id",
        team_id: "team-id",
      });
      expect(event.properties).not.toHaveProperty("label");
    }
  });

  test("drops API-key lifecycle events without a user identity", () => {
    const captured = collector();
    captureCoderouterEvent(
      { event: "coderouter_api_key_created", properties: {} },
      captured.dependencies,
    );
    expect(captured.deferred).toHaveLength(0);
  });

  test("rejects invalid enum values and bounds numeric dimensions", () => {
    expect(
      analyticsTest.eventProperties("coderouter_auth_rejected", {
        surface: "https://private.example/path",
        reason: "raw explanation",
      }),
    ).toBeNull();
    expect(
      analyticsTest.eventProperties("coderouter_account_status_viewed", {
        account_count: Number.POSITIVE_INFINITY,
        duration_ms: -1,
      }),
    ).toMatchObject({ account_count_bucket: "0", latency_bucket: "unknown" });
  });

  test("does not calculate or transmit PostHog token costs", () => {
    const captured = collector();
    captureCoderouterEvent({ event: "coderouter_model_request_completed", userId: "u", teamId: "t", properties: { input_tokens: 300_000, output_tokens: 100_000, total_tokens: 400_000 } }, captured.dependencies);
    expect(captured.bodies).toHaveLength(0);
  });
});

describe("streaming model usage extraction", () => {
  test("classifies streaming from the response media type, not body presence", () => {
    expect(isStreamingResponse(new Response("{}", {
      headers: { "content-type": "application/json" },
    }))).toBe(false);
    expect(isStreamingResponse(new Response("data: {}\n\n", {
      headers: { "content-type": "text/event-stream; charset=utf-8" },
    }))).toBe(true);
    expect(isStreamingResponse(new Response("{}", {
      headers: { "content-type": "application/x-ndjson" },
    }))).toBe(true);
  });

  test("extracts token counts without retaining prompt or output properties", () => {
    const usage = usageTest.usageFromTail(
      [
        'data: {"type":"response.completed","response":{',
        '"output":[{"content":[{"text":"private output"}]}],',
        '"usage":{"input_tokens":120,"input_tokens_details":{"cached_tokens":80},',
        '"output_tokens":30,"total_tokens":150}}}',
      ].join(""),
      "gpt-test",
    );
    expect(usage).toEqual({
      model: "gpt-test",
      inputTokens: 120,
      cachedInputTokens: 80,
      outputTokens: 30,
      totalTokens: 150,
    });
    expect(usage).not.toHaveProperty("output");
  });

  test("fails closed on missing or malformed usage", () => {
    expect(usageTest.usageFromTail('{"output":"private"}')).toBeNull();
    expect(
      usageTest.usageFromTail('{"usage":{"input_tokens":"many"}}'),
    ).toBeNull();
  });
});

describe("coderouter raw trace batch", () => {
  test("keeps only schema keys, keys by the Stack user, and defaults the identity", async () => {
    const captured = collector();
    captureCoderouterRawBatch(
      [
        {
          event: "$ai_trace",
          userId: "stack-user-raw",
          teamId: "team-raw",
          timestamp: "2026-09-03T00:00:00.000Z",
          properties: {
            $ai_trace_id: "req-1",
            $ai_latency: 0.5,
            coderouter_outcome: "success",
            trace_id: "0af7651916cd43dd8448eb211c80319c",
            prompt: "secret prompt",
            authorization: "Bearer crt_secret",
            email: "buyer@example.com",
          },
        },
        {
          event: "$exception",
          properties: {
            $exception_fingerprint: "coderouter.rds:codex",
            $exception_level: "error",
            $exception_list: [{ type: "Error", value: "message redacted" }],
          },
        },
      ],
      captured.dependencies,
    );
    await Promise.all(captured.deferred);
    expect(captured.urls).toEqual(["https://posthog.test/batch/"]);
    const body = JSON.parse(captured.bodies[0]!) as {
      api_key: string;
      batch: Array<{ event: string; distinct_id: string; timestamp: string; properties: Record<string, unknown> }>;
    };
    expect(body.api_key).toBe("phc_cmux_test");
    expect(body.batch.map((entry) => entry.event)).toEqual(["$exception"]);
    const exception = body.batch[0]!;
    expect(exception.distinct_id).toBe("coderouter-server");
    expect(exception.properties.$process_person_profile).toBe(false);
    expect(exception.properties.$exception_list).toEqual([
      { type: "Error", value: "message redacted" },
    ]);
  });

  test("is a no-op when disabled or unconfigured", async () => {
    const captured = collector();
    captureCoderouterRawBatch(
      [{ event: "$ai_trace", properties: { $ai_trace_id: "x" } }],
      { ...captured.dependencies, enabled: () => false },
    );
    captureCoderouterRawBatch(
      [{ event: "$ai_trace", properties: { $ai_trace_id: "x" } }],
      { ...captured.dependencies, config: () => null },
    );
    captureCoderouterRawBatch([], captured.dependencies);
    await Promise.all(captured.deferred);
    expect(captured.urls).toEqual([]);
  });

});
