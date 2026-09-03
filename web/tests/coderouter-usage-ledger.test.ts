import { describe, expect, spyOn, test } from "bun:test";

import * as clickhouse from "../services/coderouter/clickhouse";
import type { ClickHouseInsertResult } from "../services/coderouter/clickhouse";
import * as observability from "../services/coderouter/observability";
import {
  clickHouseDateTime,
  recordRouteEvent,
  recordUsageEvent,
  routeEventRow,
  usageEventRow,
  type UsageLedgerDependencies,
} from "../services/coderouter/usageLedger";
import {
  createClaudeMessagesProxy,
  type ClaudeProxyDependencies,
} from "../services/coderouter/claudeProxy";
import type { ClaudeUpstream } from "../services/coderouter/claudeUpstream";

const now = () => new Date("2026-09-02T10:20:30.456Z");
const vmId = "0f4b1c2e-1111-4222-8333-444455556666";
const requestId = "8d3c0a2e-5f0e-4d8a-9b1c-2f6e7a8b9c0d";

type Insert = { readonly table: string; readonly rows: readonly Record<string, unknown>[] };

function harness(result: ClickHouseInsertResult = { ok: true }) {
  const inserts: Insert[] = [];
  const tasks: Promise<unknown>[] = [];
  const dependencies: UsageLedgerDependencies = {
    insert: async (table, rows) => {
      inserts.push({ table, rows });
      return result;
    },
    defer: (task) => {
      tasks.push(task);
    },
    now,
  };
  return { inserts, tasks, dependencies };
}

describe("CodeRouter usage ledger rows", () => {
  test("formats event_time as a UTC DateTime64(3) literal", () => {
    expect(clickHouseDateTime(now())).toBe("2026-09-02 10:20:30.456");
  });

  test("codex completion from a VM-bound token", async () => {
    const { inserts, tasks, dependencies } = harness();
    recordUsageEvent({
      requestId,
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId,
      provider: "codex",
      agent: "codex",
      model: "gpt-5.2-codex",
      inputTokens: 1_200_000,
      cachedInputTokens: 200_000,
      outputTokens: 100_000,
      totalTokens: 1_300_000,
      status: 200,
    }, dependencies);
    await Promise.all(tasks);
    expect(inserts).toEqual([{
      table: "usage_events",
      rows: [{
        event_time: "2026-09-02 10:20:30.456",
        team_id: "team-1",
        stack_user_id: "stack-user-1",
        vm_id: vmId,
        provider: "codex",
        upstream_kind: "",
        agent: "codex",
        model: "gpt-5.2-codex",
        input_tokens: 1_200_000,
        cached_input_tokens: 200_000,
        output_tokens: 100_000,
        total_tokens: 1_300_000,
        // 1,000,000 uncached at $1.75 + 200,000 cached at $0.175 + 100,000 out at $14.
        api_equivalent_usd: 3.185,
        priced: 1,
        rate_card_version: "2026-08-08",
        request_id: requestId,
        status: 200,
      }],
    }]);
  });

  test("opencode completion from an unbound CLI token has a null vm_id and is unpriced", () => {
    const row = usageEventRow({
      requestId,
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId: null,
      provider: "opencode-go",
      agent: "opencode",
      model: "kimi-k2",
      inputTokens: 80,
      cachedInputTokens: 20,
      outputTokens: 20,
      totalTokens: 100,
      status: 200,
    }, now());
    expect(row).toMatchObject({
      vm_id: null,
      provider: "opencode-go",
      upstream_kind: "",
      agent: "opencode",
      model: "kimi-k2",
      total_tokens: 100,
      api_equivalent_usd: 0,
      priced: 0,
    });
  });

  test("claude completion keeps its upstream kind", () => {
    const row = usageEventRow({
      requestId,
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId,
      provider: "claude",
      upstreamKind: "bedrock",
      agent: "claude",
      model: "Claude-Sonnet-4-5-20250929",
      inputTokens: 115,
      cachedInputTokens: 100,
      outputTokens: 42,
      totalTokens: 157,
      status: 200,
    }, now());
    expect(row).toMatchObject({
      vm_id: vmId,
      provider: "claude",
      upstream_kind: "bedrock",
      agent: "claude",
      model: "claude-sonnet-4-5-20250929",
      input_tokens: 115,
      cached_input_tokens: 100,
      output_tokens: 42,
      total_tokens: 157,
      priced: 1,
    });
    expect(row!.api_equivalent_usd).toBeCloseTo((15 * 3 + 100 * 0.3 + 42 * 15) / 1_000_000, 12);
  });

  test("sanitizes counts, ids, and empty completions", () => {
    expect(usageEventRow({
      requestId,
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId: null,
      provider: "codex",
      agent: "codex",
      model: "gpt-5.2",
      inputTokens: 0,
      cachedInputTokens: 0,
      outputTokens: 0,
      totalTokens: 0,
      status: 200,
    }, now())).toBeNull();
    const row = usageEventRow({
      requestId,
      teamId: "team-1",
      stackUserId: "stack-user-1",
      vmId: "not a vm id",
      provider: "codex",
      agent: "codex",
      model: undefined,
      inputTokens: 10,
      cachedInputTokens: 50,
      outputTokens: -3,
      totalTokens: 4,
      status: 99_999,
    }, now());
    expect(row).toMatchObject({
      vm_id: null,
      model: "unknown",
      input_tokens: 10,
      cached_input_tokens: 10,
      output_tokens: 0,
      total_tokens: 10,
      priced: 0,
      status: 0,
    });
  });

  test("route row for an unauthenticated request has an empty team", async () => {
    const { inserts, tasks, dependencies } = harness();
    recordRouteEvent({
      requestId,
      provider: "codex",
      agent: "other",
      outcome: "unauthorized",
      failureStage: "auth",
      status: 401,
      attemptCount: 0,
      refreshRetryCount: 0,
      durationMs: 12.6,
      responseStreamed: false,
    }, dependencies);
    await Promise.all(tasks);
    expect(inserts).toEqual([{
      table: "route_events",
      rows: [{
        event_time: "2026-09-02 10:20:30.456",
        team_id: "",
        vm_id: null,
        provider: "codex",
        agent: "other",
        outcome: "unauthorized",
        failure_stage: "auth",
        status: 401,
        attempt_count: 0,
        refresh_retry_count: 0,
        duration_ms: 13,
        response_streamed: 0,
        request_id: requestId,
      }],
    }]);
    expect(routeEventRow({
      requestId,
      teamId: "team-1",
      vmId,
      provider: "claude",
      agent: "claude",
      outcome: "success",
      failureStage: "none",
      status: 200,
      attemptCount: 1,
      refreshRetryCount: 0,
      durationMs: 840,
      responseStreamed: true,
    }, now())).toMatchObject({ team_id: "team-1", vm_id: vmId, response_streamed: 1 });
  });

  test("reports insert failures without team data and stays silent when disabled", async () => {
    const report = spyOn(observability, "reportCoderouterFailure");
    try {
      const failed = harness({ ok: false, reason: "status", status: 500 });
      recordRouteEvent({
        requestId,
        teamId: "team-private",
        provider: "codex",
        agent: "codex",
        outcome: "success",
        failureStage: "none",
        status: 200,
        attemptCount: 1,
        refreshRetryCount: 0,
        durationMs: 1,
        responseStreamed: true,
      }, failed.dependencies);
      await Promise.all(failed.tasks);
      expect(report).toHaveBeenCalledTimes(1);
      expect(report.mock.calls[0]![0]).toBe("usage_ledger");
      expect(report.mock.calls[0]![2]).toEqual({ table: "route_events", reason: "status", status: 500 });
      expect(JSON.stringify(report.mock.calls)).not.toContain("team-private");

      const disabled = harness({ ok: false, reason: "disabled" });
      recordRouteEvent({
        requestId,
        teamId: "team-private",
        provider: "codex",
        agent: "codex",
        outcome: "success",
        failureStage: "none",
        status: 200,
        attemptCount: 1,
        refreshRetryCount: 0,
        durationMs: 1,
        responseStreamed: true,
      }, disabled.dependencies);
      await Promise.all(disabled.tasks);
      expect(report).toHaveBeenCalledTimes(1);
    } finally {
      report.mockRestore();
    }
  });
});

describe("CodeRouter usage ledger wiring", () => {
  test("the Claude proxy writes a usage row and a route row sharing one request id", async () => {
    // Calls through; without CLICKHOUSE_* in the test env the client reports
    // itself disabled and never opens a connection.
    const insert = spyOn(clickhouse, "insertRows");
    try {
      const upstream: ClaudeUpstream = {
        teamId: "team-1",
        kind: "anthropic_api_key",
        secret: { kind: "anthropic_api_key", apiKey: "sk-ant-api03-test-key" },
        config: {},
        updatedAt: new Date(0),
      };
      const dependencies: ClaudeProxyDependencies = {
        authenticate: async () => ({
          ok: true,
          identity: { teamId: "team-1", stackUserId: "stack-user-1", vmId, token: "crt_x" },
        }),
        upstream: async () => upstream,
        fetch: (async () =>
          Response.json({
            id: "msg_1",
            model: "claude-sonnet-4-5-20250929",
            usage: {
              input_tokens: 15,
              cache_read_input_tokens: 100,
              cache_creation_input_tokens: 0,
              output_tokens: 42,
            },
          })) as typeof fetch,
        now,
        capture: () => {},
      };
      const proxy = createClaudeMessagesProxy(dependencies);
      const response = await proxy(
        new Request("https://cmux.test/api/coderouter/claude/v1/messages", {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "anthropic-version": "2023-06-01",
            "user-agent": "claude-cli/2.0.0",
          },
          body: JSON.stringify({ model: "claude-sonnet-4-5-20250929", max_tokens: 8, messages: [] }),
        }),
      );
      await response.text();
      const calls = insert.mock.calls.map((call) => ({
        table: call[0] as string,
        row: (call[1] as readonly Record<string, unknown>[])[0]!,
      }));
      const route = calls.find((call) => call.table === "route_events");
      const usage = calls.find((call) => call.table === "usage_events");
      expect(route?.row).toMatchObject({
        team_id: "team-1",
        vm_id: vmId,
        provider: "claude",
        agent: "claude",
        outcome: "success",
        status: 200,
      });
      expect(usage?.row).toMatchObject({
        team_id: "team-1",
        stack_user_id: "stack-user-1",
        vm_id: vmId,
        provider: "claude",
        upstream_kind: "anthropic_api_key",
        agent: "claude",
        model: "claude-sonnet-4-5-20250929",
        input_tokens: 115,
        cached_input_tokens: 100,
        output_tokens: 42,
        total_tokens: 157,
        priced: 1,
        status: 200,
      });
      expect(typeof route?.row.request_id).toBe("string");
      expect(route?.row.request_id).toBe(usage?.row.request_id);
      expect(JSON.stringify(calls)).not.toContain("sk-ant-api03");
    } finally {
      insert.mockRestore();
    }
  });
});
