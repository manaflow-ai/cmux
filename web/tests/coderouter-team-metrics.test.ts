import { describe, expect, mock, test } from "bun:test";

import {
  __test as metricsTest,
  type CoderouterTeamMetrics,
} from "../services/coderouter/teamMetrics";
import { coderouterTeamAnalyticsId } from
  "../services/coderouter/analyticsIdentity";

const scopeSecret = "test-only-scope-secret-at-least-32-bytes";
const config = {
  apiHost: "https://us.posthog.test",
  environmentId: "244066",
  endpointSecret: "phs_endpoint_read_only",
  endpointName: "coderouter-team-usage-30d",
  scopeSecret,
};

describe("CodeRouter team metrics", () => {
  test("calls the fixed PostHog Endpoint with a project-scoped key", async () => {
    const posthogFetch = mock(async (...args: unknown[]) => {
      const [url, init] = args;
      expect(String(url)).toBe(
        "https://us.posthog.test/api/environments/244066/endpoints/coderouter-team-usage-30d/run",
      );
      expect(
        new Headers((init as RequestInit | undefined)?.headers).get(
          "authorization",
        ),
      ).toBe("Bearer phs_endpoint_read_only");
      const body = JSON.parse(
        String((init as RequestInit | undefined)?.body),
      ) as { variables: Record<string, unknown> };
      expect(body).toEqual({
        variables: {
          team_scope: coderouterTeamAnalyticsId(
            "team-authorized",
            scopeSecret,
          ),
        },
      });
      expect(JSON.stringify(body)).not.toContain("team-authorized");
      return Response.json({
        columns: [
          "day",
          "input_tokens",
          "cached_input_tokens",
          "output_tokens",
          "total_tokens",
          "api_equivalent_usd",
          "priced_tokens",
          "unpriced_tokens",
        ],
        results: [{
          day: "2026-08-08",
          input_tokens: 1_200_000,
          cached_input_tokens: 200_000,
          output_tokens: 100_000,
          total_tokens: 1_300_000,
          api_equivalent_usd: 3.185,
          priced_tokens: 1_300_000,
          unpriced_tokens: 0,
        }],
        hasMore: false,
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
      inputTokens: 1_200_000,
      cachedInputTokens: 200_000,
      outputTokens: 100_000,
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.185,
      pricedTokens: 1_300_000,
      unpricedTokens: 0,
    });
    expect(ready.daily.at(-1)).toMatchObject({
      day: "2026-08-08",
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.185,
    });
  });

  test("accepts partial pricing coverage without exposing dimensions", () => {
    const result = metricsTest.metricsFromRows(
      [{
        day: "2026-08-08",
        input_tokens: 84,
        cached_input_tokens: 20,
        output_tokens: 26,
        total_tokens: 110,
        api_equivalent_usd: 0.0003,
        priced_tokens: 100,
        unpriced_tokens: 10,
      }],
      new Date("2026-08-08T12:00:00.000Z"),
    );

    expect(result).not.toBeNull();
    expect(result!.totals.totalTokens).toBe(110);
    expect(result!.totals.pricedTokens).toBe(100);
    expect(result!.totals.unpricedTokens).toBe(10);
    expect(JSON.stringify(result)).not.toMatch(/model|provider|member|account/i);
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
      fetch: mock(async () =>
        Response.json({
          columns: ["prompt"],
          results: [{ prompt: "private" }],
          hasMore: false,
        })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
    });
    expect(malformed).toEqual({ kind: "unavailable" });
  });

  test("rejects truncated endpoint responses", async () => {
    const result = await metricsTest.queryCoderouterTeamMetrics("team-1", {
      config: () => config,
      fetch: mock(async () =>
        Response.json({
          columns: [
            "day",
            "input_tokens",
            "cached_input_tokens",
            "output_tokens",
            "total_tokens",
            "api_equivalent_usd",
            "priced_tokens",
            "unpriced_tokens",
          ],
          results: [],
          hasMore: true,
        })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
    });
    expect(result).toEqual({ kind: "unavailable" });
  });
});
