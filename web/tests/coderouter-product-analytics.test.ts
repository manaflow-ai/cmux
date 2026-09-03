import { describe, expect, test } from "bun:test";

import {
  captureCoderouterProductEvent,
  CODEROUTER_PRODUCT_EVENT_NAMES,
  coderouterAccountAddedEvent,
  coderouterAccountRemovedEvent,
  coderouterClaudeUpstreamEvent,
  coderouterGenerationEvent,
  coderouterRequestFailedEvent,
  coderouterSessionIssuedEvent,
} from "../services/coderouter/productAnalytics";

const NOW = new Date("2026-09-03T12:00:00.000Z");
const identity = { stackUserId: "user-1", teamId: "team-1", vmId: "vm-row-1" };

describe("coderouter $ai_generation", () => {
  test("is keyed by the Stack user with the team group and LLM analytics keys", () => {
    const event = coderouterGenerationEvent({
      identity,
      provider: "claude",
      agent: "claude",
      model: "Claude-Opus-4.7-20260401",
      inputTokens: 1_000,
      cachedInputTokens: 400,
      outputTokens: 200,
      totalTokens: 1_200,
      status: 200,
      upstreamKind: "bedrock",
      responseStreamed: true,
    }, NOW);
    expect(event).not.toBeNull();
    expect(event!.event).toBe("$ai_generation");
    expect(event!.distinctId).toBe("user-1");
    expect(event!.teamId).toBe("team-1");
    expect(event!.properties).toMatchObject({
      product: "coderouter",
      schema_version: 1,
      vm_bound: true,
      vm_id: "vm-row-1",
      $ai_provider: "anthropic",
      $ai_model: "claude-opus-4.7-20260401",
      $ai_input_tokens: 1_000,
      $ai_cache_read_input_tokens: 400,
      $ai_output_tokens: 200,
      $ai_http_status: 200,
      $ai_is_error: false,
      route_provider: "claude",
      agent: "claude",
      model_family: "claude-opus-4.7",
      total_tokens: 1_200,
      upstream_kind: "bedrock",
      response_streamed: true,
    });
    expect(typeof event!.properties!.$ai_total_cost_usd).toBe("number");
    expect(event!.properties!.$ai_total_cost_usd).toBeGreaterThan(0);
    expect(event!.properties!.api_equivalent_usd).toBe(event!.properties!.$ai_total_cost_usd);
    expect(event!.setOnce).toEqual({ coderouter_first_generation_at: NOW.toISOString() });
  });

  test("an unknown model is priced as unknown and its raw id is kept only when well formed", () => {
    const event = coderouterGenerationEvent({
      identity: { stackUserId: "user-1", teamId: "team-1", vmId: null },
      provider: "codex",
      agent: "codex",
      model: "my secret customer label with spaces",
      inputTokens: 10,
      cachedInputTokens: 0,
      outputTokens: 5,
      totalTokens: 15,
      status: 200,
    }, NOW);
    expect(event!.properties).toMatchObject({
      $ai_provider: "openai",
      $ai_model: "unknown",
      model_family: "unknown",
      vm_bound: false,
      priced_tokens: 0,
      unpriced_tokens: 15,
    });
    expect("$ai_total_cost_usd" in event!.properties!).toBe(false);
    expect(event!.properties!.vm_id).toBeUndefined();
  });

  test("zero usage is not a generation", () => {
    expect(coderouterGenerationEvent({
      identity,
      provider: "codex",
      agent: "codex",
      model: "gpt-5.6-sol",
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      status: 200,
    }, NOW)).toBeNull();
  });

  test("cached tokens never exceed input tokens and bad counts are zeroed", () => {
    const event = coderouterGenerationEvent({
      identity,
      provider: "codex",
      agent: "codex",
      model: "gpt-5.6-sol",
      inputTokens: 100,
      cachedInputTokens: 500,
      outputTokens: -3,
      totalTokens: Number.NaN,
      status: 200,
    }, NOW);
    expect(event!.properties).toMatchObject({
      $ai_input_tokens: 100,
      $ai_cache_read_input_tokens: 100,
      $ai_output_tokens: 0,
      total_tokens: 100,
    });
  });
});

describe("coderouter failures and lifecycle", () => {
  test("a failed request carries the closed outcome vocabulary and no free text", () => {
    const event = coderouterRequestFailedEvent({
      identity,
      provider: "opencode-go",
      agent: "opencode",
      outcome: "upstream_error",
      failureStage: "upstream_response",
      status: 502,
      durationMs: 1234.7,
      attemptCount: 3,
    }, NOW);
    expect(event.event).toBe("coderouter_request_failed");
    expect(event.properties).toEqual({
      product: "coderouter",
      schema_version: 1,
      vm_bound: true,
      vm_id: "vm-row-1",
      route_provider: "opencode-go",
      agent: "opencode",
      outcome: "upstream_error",
      failure_stage: "upstream_response",
      status: 502,
      duration_ms: 1235,
      attempt_count: 3,
    });
  });

  test("an outcome outside the token grammar becomes unknown", () => {
    const event = coderouterRequestFailedEvent({
      identity,
      provider: "codex",
      agent: "codex",
      outcome: "upstream said: 'boom'",
      failureStage: "auth",
      status: 9000,
      durationMs: -5,
    }, NOW);
    expect(event.properties).toMatchObject({ outcome: "unknown", status: 0, duration_ms: 0, agent: "codex" });
  });

  test("account, session and upstream events keep the user and team", () => {
    const added = coderouterAccountAddedEvent({
      stackUserId: "user-1",
      teamId: "team-1",
      source: "legacy_dashboard",
      provider: "codex",
      alreadyExists: false,
    });
    expect(added).toMatchObject({
      event: "coderouter_account_added",
      distinctId: "user-1",
      teamId: "team-1",
      properties: { provider: "codex", source: "legacy_dashboard", already_exists: false },
    });
    expect(typeof added.setOnce!.coderouter_first_account_added_at).toBe("string");

    const removed = coderouterAccountRemovedEvent({ stackUserId: "user-1", teamId: "team-1", source: "native_api", lastAccount: true });
    expect(removed.properties).toMatchObject({ source: "native_api", last_account: true });

    const session = coderouterSessionIssuedEvent({ stackUserId: "user-1", teamId: "team-1" });
    expect(session.event).toBe("coderouter_route_session_issued");

    const set = coderouterClaudeUpstreamEvent({ kind: "set", stackUserId: "user-1", teamId: "team-1", upstreamKind: "anthropic_oauth", replaced: true });
    expect(set.properties).toMatchObject({ upstream_kind: "anthropic_oauth", replaced: true });
    const bogus = coderouterClaudeUpstreamEvent({ kind: "set", stackUserId: "user-1", teamId: "team-1", upstreamKind: "sk-live-xyz", replaced: false });
    expect(bogus.properties).toMatchObject({ upstream_kind: "unknown" });
    const removedUpstream = coderouterClaudeUpstreamEvent({ kind: "removed", stackUserId: "user-1", teamId: "team-1" });
    expect(removedUpstream.event).toBe("coderouter_claude_upstream_removed");
  });

  test("the catalog names are unique", () => {
    expect(new Set(CODEROUTER_PRODUCT_EVENT_NAMES).size).toBe(CODEROUTER_PRODUCT_EVENT_NAMES.length);
  });

  test("capture posts through the shared sender with the team group", async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const deferred: Promise<unknown>[] = [];
    captureCoderouterProductEvent(
      coderouterSessionIssuedEvent({ stackUserId: "user-1", teamId: "team-1" }),
      {
        fetch: (async (_input: string | URL | Request, init?: RequestInit) => {
          bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
          return new Response(null, { status: 200 });
        }) as unknown as typeof fetch,
        env: { CMUX_SERVER_ANALYTICS_FORCE: "1" },
        defer: (task) => {
          deferred.push(task);
        },
      },
    );
    await Promise.all(deferred);
    expect(bodies).toHaveLength(1);
    expect(bodies[0]).toMatchObject({ event: "coderouter_route_session_issued", distinct_id: "user-1" });
    expect((bodies[0].properties as Record<string, unknown>).$groups).toEqual({ stack_team: "team-1" });
    captureCoderouterProductEvent(null);
  });
});
