import { describe, expect, mock, test } from "bun:test";

import {
  __test as metricsTest,
  type CoderouterTeamMetrics,
} from "../services/coderouter/teamMetrics";

const config = {
  apiHost: "https://us.posthog.test",
  environmentId: "244066",
  queryApiKey: "phx_query_read_only",
};

describe("CodeRouter team metrics", () => {
  test("uses a parameterized, team-scoped aggregate query", async () => {
    const posthogFetch = mock(async (...args: Parameters<typeof fetch>) => {
      const [url, init] = args;
      expect(String(url)).toBe(
        "https://us.posthog.test/api/projects/244066/query/",
      );
      expect(new Headers(init?.headers).get("authorization")).toBe(
        "Bearer phx_query_read_only",
      );
      const body = JSON.parse(String(init?.body)) as {
        query: { query: string; values: Record<string, unknown> };
      };
      expect(body.query.query).toContain("{team_id}");
      expect(body.query.query).not.toContain("team-authorized");
      expect(body.query.values).toEqual({ team_id: "team-authorized" });
      expect(body.query.query).not.toMatch(
        /distinct_id|person|prompt|response|content|credential|account_id/i,
      );
      return Response.json({
        columns: [
          "day",
          "model",
          "request_count",
          "input_tokens",
          "cached_input_tokens",
          "output_tokens",
          "total_tokens",
        ],
        results: [[
          "2026-08-08",
          "gpt-5.2",
          2,
          1_200_000,
          200_000,
          100_000,
          1_300_000,
        ]],
      });
    });

    const result = await metricsTest.queryCoderouterTeamMetrics(
      "team-authorized",
      {
        config: () => config,
        fetch: posthogFetch as typeof fetch,
        now: () => new Date("2026-08-08T12:00:00.000Z"),
      },
    );

    expect(result.kind).toBe("ready");
    const ready = result as Extract<CoderouterTeamMetrics, { kind: "ready" }>;
    expect(ready.totals).toEqual({
      requestCount: 2,
      inputTokens: 1_200_000,
      cachedInputTokens: 200_000,
      outputTokens: 100_000,
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.325,
      pricedTokens: 1_300_000,
      unpricedTokens: 0,
    });
    expect(ready.daily.at(-1)).toMatchObject({
      day: "2026-08-08",
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.325,
    });
  });

  test("reports partial price coverage without exposing model details", async () => {
    const result = await metricsTest.metricsFromRows(
      [
        ["2026-08-08", "unknown-private-model", 1, 4, 0, 6, 10],
        ["2026-08-08", "gpt-5-codex", 1, 80, 20, 20, 100],
      ],
      new Date("2026-08-08T12:00:00.000Z"),
    );

    expect(result.totals.totalTokens).toBe(110);
    expect(result.totals.pricedTokens).toBe(100);
    expect(result.totals.unpricedTokens).toBe(10);
    expect(result).not.toHaveProperty("models");
    expect(JSON.stringify(result)).not.toContain("unknown-private-model");
  });

  test("fails closed when PostHog is unconfigured or malformed", async () => {
    expect(
      await metricsTest.queryCoderouterTeamMetrics("team-1", {
        config: () => null,
        fetch,
        now: () => new Date("2026-08-08T12:00:00.000Z"),
      }),
    ).toEqual({ kind: "unavailable" });

    const malformed = await metricsTest.queryCoderouterTeamMetrics("team-1", {
      config: () => config,
      fetch: mock(async () => Response.json({
        columns: ["prompt"],
        results: [["private"]],
      })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
    });
    expect(malformed).toEqual({ kind: "unavailable" });
  });
});
