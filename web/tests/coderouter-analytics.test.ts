import { describe, expect, mock, test } from "bun:test";

import {
  __test as analyticsTest,
  captureCoderouterEvent,
} from "../services/coderouter/analytics";
import {
  coderouterTeamAnalyticsId,
  coderouterUserAnalyticsId,
} from "../services/coderouter/analyticsIdentity";
import { __test as usageTest } from "../services/coderouter/responseUsage";

const scopeSecret = "test-only-scope-secret-at-least-32-bytes";
const isolatedConfig = () => ({
  ingestHost: "https://coderouter.i.posthog.test",
  projectKey: "phc_coderouter_only",
  scopeSecret,
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
    isolatedConfig,
  };
  return {
    bodies,
    urls,
    deferred,
    dependencies,
  };
}

describe("coderouter analytics", () => {
  test("sends content-free AI Observability usage only to the isolated project", async () => {
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
    expect(captured.urls).toEqual([
      "https://coderouter.i.posthog.test/batch/",
    ]);
    const payload = JSON.parse(captured.bodies[0]!) as {
      api_key: string;
      batch: Array<{
        event: string;
        distinct_id: string;
        properties: Record<string, unknown>;
      }>;
    };
    const event = payload.batch[0]!;
    expect(payload.api_key).toBe("phc_coderouter_only");
    expect(event.event).toBe("$ai_generation");
    expect(event.distinct_id).toBe(
      coderouterTeamAnalyticsId("team-raw", scopeSecret),
    );
    expect(event.properties).toMatchObject({
      $process_person_profile: false,
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
    for (const raw of [
      "team-raw",
      "stack-user-raw",
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

  test("routes ops events only to isolated config and HMACs team and user separately", async () => {
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
    const teamScope = coderouterTeamAnalyticsId("raw-team-id", scopeSecret);
    const userScope = coderouterUserAnalyticsId(
      "raw-stack-user-id",
      scopeSecret,
    );
    expect(payload.api_key).toBe("phc_coderouter_only");
    expect(event.distinct_id).toBe(teamScope);
    expect(event.properties).toMatchObject({
      provider: "codex",
      source: "native_api",
      already_exists: false,
      coderouter_team_scope: teamScope,
      coderouter_user_scope: userScope,
      $process_person_profile: false,
      $geoip_disable: true,
    });
    expect(Object.keys(event.properties).sort()).toEqual([
      "$geoip_disable",
      "$insert_id",
      "$process_person_profile",
      "already_exists",
      "coderouter_team_scope",
      "coderouter_user_scope",
      "product",
      "provider",
      "schema_version",
      "service_version",
      "source",
    ]);
    expect(captured.bodies[0]).not.toContain("raw-stack-user-id");
    expect(captured.bodies[0]).not.toContain("raw-team-id");
    expect(captured.bodies[0]).not.toContain("raw-account-id");
    expect(captured.bodies[0]).not.toContain("Personal account");
    expect(captured.bodies[0]).not.toContain("raw-token");
    expect(captured.bodies[0]).not.toContain("/Users/private/project");
    expect(captured.bodies[0]).not.toContain("free-form error");
  });

  test("fails closed for usage and ops when isolated configuration is missing", () => {
    const defer = mock(() => {});
    const dependencies = {
      fetch,
      defer,
      enabled: () => true,
      isolatedConfig: () => null,
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

  test("retains zero-token failures as separate route-health events", async () => {
    const captured = collector();
    captureCoderouterEvent(
      {
        event: "coderouter_route_health",
        teamId: "team-1",
        properties: {
          provider: "codex",
          agent: "pi",
          outcome: "no_usable_account",
          failure_stage: "account_selection",
          status: 503,
          duration_ms: 734,
          attempt_count: 0,
          refresh_retry_count: 0,
          response_streamed: false,
          request_id: "must-not-leak",
        },
      },
      captured.dependencies,
    );
    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        teamId: "team-1",
        properties: { provider: "codex", total_tokens: 0 },
      },
      captured.dependencies,
    );

    await Promise.all(captured.deferred);
    expect(captured.bodies).toHaveLength(1);
    const event = JSON.parse(captured.bodies[0]!).batch[0];
    expect(event.event).toBe("coderouter_route_health");
    expect(event.properties).toMatchObject({
      provider: "codex",
      agent: "pi",
      outcome: "no_usable_account",
      failure_stage: "account_selection",
      status_class: "5xx",
      latency_bucket: "500_1999ms",
      attempt_bucket: "0",
      refresh_bucket: "0",
      response_streamed: false,
    });
    expect(captured.bodies[0]).not.toContain("must-not-leak");
  });

  test("rejects invalid enum values and bounds numeric dimensions", () => {
    expect(
      analyticsTest.eventProperties("coderouter_auth_rejected", {
        surface: "https://private.example/path",
        reason: "raw explanation",
      }),
    ).toBeNull();
    expect(
      analyticsTest.eventProperties("coderouter_route_health", {
        provider: "codex",
        agent: "pi",
        outcome: "success",
        failure_stage: "none",
        status: Number.POSITIVE_INFINITY,
        duration_ms: -1,
        attempt_count: 99_999,
        refresh_retry_count: Number.NaN,
      }),
    ).toMatchObject({
      status_class: "unknown",
      latency_bucket: "unknown",
      attempt_bucket: "0",
      refresh_bucket: "0",
    });
  });

  test("uses keyed, domain-separated team and user pseudonyms", () => {
    const team = coderouterTeamAnalyticsId("same-raw-id", scopeSecret);
    const user = coderouterUserAnalyticsId("same-raw-id", scopeSecret);
    expect(team).not.toBe(user);
    expect(team).not.toContain("same-raw-id");
    expect(user).not.toContain("same-raw-id");
    expect(team).not.toBe(
      coderouterTeamAnalyticsId(
        "same-raw-id",
        "a-different-test-scope-secret-32-bytes",
      ),
    );
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
      "coderouter-team-test",
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
