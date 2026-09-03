import { describe, expect, mock, test } from "bun:test";

import {
  __test as analyticsTest,
  captureCoderouterEvent,
  captureCoderouterRawBatch,
} from "../services/coderouter/analytics";
import { __test as usageTest } from "../services/coderouter/responseUsage";

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
  test("sends content-free AI Observability usage keyed by the Stack user", async () => {
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
    expect(captured.urls).toEqual(["https://posthog.test/batch/"]);
    const payload = JSON.parse(captured.bodies[0]!) as {
      api_key: string;
      batch: Array<{
        event: string;
        distinct_id: string;
        properties: Record<string, unknown>;
      }>;
    };
    const event = payload.batch[0]!;
    expect(payload.api_key).toBe("phc_cmux_test");
    expect(event.event).toBe("$ai_generation");
    expect(event.distinct_id).toBe("stack-user-raw");
    expect(event.properties).toMatchObject({
      user_id: "stack-user-raw",
      team_id: "team-raw",
      $geoip_disable: true,
      $ai_model: "gpt-5.6-terra",
      $ai_provider: "openai",
      $ai_input_tokens: 8,
      $ai_cache_read_input_tokens: 3,
      $ai_output_tokens: 2,
      coderouter_total_tokens: 10,
      product: "coderouter",
      schema_version: 3,
      service_version: "coderouter-web-v1",
    });
    const serialized = captured.bodies[0]!;
    expect(event.properties).not.toHaveProperty("$process_person_profile");
    for (const raw of [
      "secret prompt",
      "secret output",
      "crt_secret",
      "buyer@example.com",
      "acct_secret",
      "private.example",
      "authorization secret",
      "private-customer-label",
    ]) {
      expect(serialized).not.toContain(raw);
    }
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

  test("attributes VM-bound traffic per machine", () => {
    expect(
      analyticsTest.eventProperties("coderouter_auth_rejected", {
        surface: "responses",
        reason: "vm_mismatch",
      }),
    ).toEqual({ surface: "responses", reason: "vm_mismatch" });
    expect(
      analyticsTest.aiUsageProperties(
        { provider: "codex", model: "gpt-5.2", input_tokens: 5, output_tokens: 5, vm_id: "vm-1" },
      ),
    ).toMatchObject({ coderouter_vm_id: "vm-1" });
    // Unbound traffic and malformed ids carry no vm id at all.
    expect(
      analyticsTest.aiUsageProperties(
        { provider: "codex", model: "gpt-5.2", input_tokens: 5, output_tokens: 5, vm_id: "not a vm id; free text" },
      ),
    ).not.toHaveProperty("coderouter_vm_id");
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

  test("pre-calculates versioned long-context API-equivalent cost", () => {
    const properties = analyticsTest.aiUsageProperties(
      {
        provider: "codex",
        model: "gpt-5.6-terra",
        input_tokens: 300_000,
        cached_input_tokens: 0,
        output_tokens: 100_000,
        total_tokens: 400_000,
      },
    );
    expect(properties).not.toBeNull();
    expect(properties!.$ai_total_cost_usd).toBe(3.75);
    expect(properties!.coderouter_priced_tokens).toBe(400_000);
    expect(properties!.coderouter_unpriced_tokens).toBe(0);
  });
});

describe("streaming model usage extraction", () => {
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
          properties: { $exception_fingerprint: "coderouter.rds:codex", $exception_level: "error" },
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
    expect(body.batch.map((entry) => entry.event)).toEqual(["$ai_trace", "$exception"]);
    const trace = body.batch[0]!;
    expect(trace.distinct_id).toBe("stack-user-raw");
    expect(trace.timestamp).toBe("2026-09-03T00:00:00.000Z");
    expect(trace.properties).toMatchObject({
      $ai_trace_id: "req-1",
      $ai_latency: 0.5,
      coderouter_outcome: "success",
      trace_id: "0af7651916cd43dd8448eb211c80319c",
      user_id: "stack-user-raw",
      team_id: "team-raw",
      product: "coderouter",
    });
    for (const leaked of ["prompt", "authorization", "email", "$process_person_profile"]) {
      expect(leaked in trace.properties).toBe(false);
    }
    const exception = body.batch[1]!;
    expect(exception.distinct_id).toBe("coderouter-server");
    expect(exception.properties.$process_person_profile).toBe(false);
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

  test("$ai_generation carries the trace link, latency, status and stream flag", () => {
    const properties = analyticsTest.aiUsageProperties(
      {
        provider: "claude",
        model: "claude-sonnet-5",
        input_tokens: 10,
        cached_input_tokens: 2,
        output_tokens: 5,
        total_tokens: 15,
        request_id: "8b9a2f3e-1c4d-4e5f-8a6b-7c8d9e0f1a2b",
        duration_ms: 2500,
        status: 200,
        response_streamed: true,
      },
    );
    expect(properties).toMatchObject({
      $ai_trace_id: "8b9a2f3e-1c4d-4e5f-8a6b-7c8d9e0f1a2b",
      $ai_parent_id: "8b9a2f3e-1c4d-4e5f-8a6b-7c8d9e0f1a2b",
      coderouter_request_id: "8b9a2f3e-1c4d-4e5f-8a6b-7c8d9e0f1a2b",
      $ai_latency: 2.5,
      $ai_http_status: 200,
      $ai_is_error: false,
      $ai_stream: true,
    });
  });
});
