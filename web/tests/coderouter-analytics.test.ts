import { describe, expect, mock, test } from "bun:test";

import {
  __test as analyticsTest,
  captureCoderouterEvent,
} from "../services/coderouter/analytics";
import { coderouterTeamAnalyticsId } from
  "../services/coderouter/analyticsIdentity";
import { __test as usageTest } from "../services/coderouter/responseUsage";

const scopeSecret = "test-only-scope-secret-at-least-32-bytes";

describe("coderouter analytics", () => {
  test("keeps aggregate usage while dropping sensitive properties", () => {
    expect(
      analyticsTest.safeProperties({
        provider: "codex",
        input_tokens: 123,
        cached_input_tokens: 20,
        output_tokens: 45,
        total_tokens: 168,
        actual_cost_usd: 0,
        prompt: "secret prompt",
        response_body: "secret output",
        route_token: "crt_secret",
        email: "buyer@example.com",
        provider_account_id: "acct_secret",
      }),
    ).toEqual({
      provider: "codex",
      input_tokens: 123,
      cached_input_tokens: 20,
      output_tokens: 45,
      total_tokens: 168,
      actual_cost_usd: 0,
    });
  });

  test("sends content-free AI Observability usage to the isolated project", async () => {
    const bodies: string[] = [];
    const urls: string[] = [];
    const posthogFetch = mock(async (...args: unknown[]) => {
      urls.push(String(args[0]));
      const init = args[1] as RequestInit | undefined;
      bodies.push(String(init?.body));
      return new Response(null, { status: bodies.length === 1 ? 503 : 200 });
    });
    let deferred: Promise<unknown> | null = null;

    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        userId: "stack-user-1",
        teamId: "team-1",
        properties: { provider: "codex", total_tokens: 10 },
      },
      {
        fetch: posthogFetch as typeof fetch,
        defer: (task) => {
          deferred = task;
        },
        enabled: () => true,
        usageConfig: () => ({
          ingestHost: "https://coderouter.i.posthog.test",
          projectKey: "phc_coderouter_only",
          scopeSecret,
        }),
      },
    );

    expect(deferred).not.toBeNull();
    await deferred;
    expect(posthogFetch).toHaveBeenCalledTimes(2);
    expect(urls).toEqual([
      "https://coderouter.i.posthog.test/batch/",
      "https://coderouter.i.posthog.test/batch/",
    ]);
    expect(bodies[0]).toBe(bodies[1]);
    const payload = JSON.parse(bodies[0]!) as {
      api_key: string;
      batch: Array<{
        event: string;
        distinct_id: string;
        properties: Record<string, unknown>;
      }>;
    };
    expect(payload.api_key).toBe("phc_coderouter_only");
    expect(payload.batch[0]?.event).toBe("$ai_generation");
    expect(payload.batch[0]?.distinct_id).toBe(
      coderouterTeamAnalyticsId("team-1", scopeSecret),
    );
    expect(payload.batch[0]?.properties.coderouter_team_scope).toBe(
      payload.batch[0]?.distinct_id,
    );
    expect(payload.batch[0]?.properties).toMatchObject({
      $process_person_profile: false,
      $ai_model: "unknown",
      $ai_provider: "openai",
      $ai_input_tokens: 0,
      $ai_cache_read_input_tokens: 0,
      $ai_cache_reporting_exclusive: false,
      $ai_output_tokens: 0,
      coderouter_total_tokens: 10,
      coderouter_unpriced_tokens: 10,
    });
    expect(payload.batch[0]?.properties).not.toHaveProperty("$groups");
    expect(payload.batch[0]?.properties).not.toHaveProperty("$ai_input");
    expect(payload.batch[0]?.properties).not.toHaveProperty(
      "$ai_output_choices",
    );
    expect(payload.batch[0]?.properties).not.toHaveProperty("agent");
    expect(payload.batch[0]?.properties).not.toHaveProperty("outcome");
    expect(payload.batch[0]?.properties.$insert_id).toBeString();
    expect(bodies[0]).not.toContain("team-1");
    expect(bodies[0]).not.toContain("stack-user-1");
  });

  test("drops usage without a team or isolated analytics configuration", () => {
    const defer = mock(() => {});
    const dependencies = {
      fetch,
      defer,
      enabled: () => true,
      usageConfig: () => null,
    };

    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        userId: "stack-user-1",
        properties: { total_tokens: 10 },
      },
      dependencies,
    );
    captureCoderouterEvent(
      {
        event: "coderouter_model_request_completed",
        userId: "stack-user-1",
        teamId: "team-1",
        properties: { total_tokens: 10 },
      },
      dependencies,
    );

    expect(defer).not.toHaveBeenCalled();
  });

  test("uses keyed, domain-separated team pseudonyms", () => {
    const first = coderouterTeamAnalyticsId("team-1", scopeSecret);
    expect(first).toBe(coderouterTeamAnalyticsId("team-1", scopeSecret));
    expect(first).not.toBe(
      coderouterTeamAnalyticsId(
        "team-1",
        "a-different-test-scope-secret-32-bytes",
      ),
    );
    expect(first).not.toContain("team-1");
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
