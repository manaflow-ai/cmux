import { describe, expect, mock, test } from "bun:test";

import {
  __test as analyticsTest,
  captureCoderouterEvent,
} from "../services/coderouter/analytics";
import { __test as usageTest } from "../services/coderouter/responseUsage";

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

  test("is deferred and retries one transient PostHog failure with one insert id", async () => {
    const bodies: string[] = [];
    const posthogFetch = mock(async (...args: unknown[]) => {
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
      },
    );

    expect(deferred).not.toBeNull();
    await deferred;
    expect(posthogFetch).toHaveBeenCalledTimes(2);
    expect(bodies[0]).toBe(bodies[1]);
    const payload = JSON.parse(bodies[0]!) as {
      batch: Array<{
        distinct_id: string;
        properties: Record<string, unknown>;
      }>;
    };
    expect(payload.batch[0]?.distinct_id).toBe("stack-user-1");
    expect(payload.batch[0]?.properties.$groups).toEqual({
      coderouter_team: "team-1",
    });
    expect(payload.batch[0]?.properties.$insert_id).toBeString();
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
