import { describe, expect, mock, test } from "bun:test";
import { readFile } from "node:fs/promises";

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
        "https://us.posthog.test/api/projects/244066/endpoints/coderouter-team-usage-30d/run",
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

  test("accepts PostHog tabular rows aligned with validated columns", () => {
    const result = metricsTest.metricsFromRows(
      [[
        "2026-08-08",
        80,
        20,
        20,
        100,
        0.0003,
        100,
        0,
      ]],
      new Date("2026-08-08T12:00:00.000Z"),
    );
    expect(result?.totals).toMatchObject({
      inputTokens: 80,
      cachedInputTokens: 20,
      outputTokens: 20,
      totalTokens: 100,
      pricedTokens: 100,
      unpricedTokens: 0,
    });
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

  test("reports endpoint failures without including the team identity", async () => {
    const failures: Array<{ reason: string; status?: number }> = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      config: () => config,
      fetch: mock(async () =>
        new Response(null, { status: 503 })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
      reportFailure: (reason, status) => failures.push({ reason, status }),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual([{ reason: "endpoint_status", status: 503 }]);
    expect(JSON.stringify(failures)).not.toContain("team-private");
  });

  test("classifies invalid endpoint JSON as a malformed response", async () => {
    const failures: string[] = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      config: () => config,
      fetch: mock(async () =>
        new Response("{", {
          status: 200,
          headers: { "content-type": "application/json" },
        })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
      reportFailure: (reason) => failures.push(reason),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual(["malformed_response"]);
  });

  test("classifies endpoint body stream failures as request failures", async () => {
    const failures: string[] = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      config: () => config,
      fetch: mock(async () =>
        new Response(new ReadableStream({
          start(controller) {
            controller.error(new Error("stream failed"));
          },
        }), { status: 200 })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
      reportFailure: (reason) => failures.push(reason),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual(["request_failed"]);
  });

  test("classifies a null endpoint JSON root as a malformed response", async () => {
    const failures: string[] = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      config: () => config,
      fetch: mock(async () => Response.json(null)) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
      reportFailure: (reason) => failures.push(reason),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual(["malformed_response"]);
  });

  test("rejects a 31st UTC day instead of silently truncating", async () => {
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
          results: Array.from({ length: 31 }, (_, index) => ({
            day: `2026-07-${String(index + 1).padStart(2, "0")}`,
            input_tokens: 1,
            cached_input_tokens: 0,
            output_tokens: 1,
            total_tokens: 2,
            api_equivalent_usd: 0,
            priced_tokens: 0,
            unpriced_tokens: 2,
          })),
          hasMore: false,
        })) as typeof fetch,
      now: () => new Date("2026-08-08T12:00:00.000Z"),
    });
    expect(result).toEqual({ kind: "unavailable" });
  });

  test("endpoint query uses exactly 30 UTC calendar days plus an overflow sentinel", async () => {
    const query = await readFile(
      new URL(
        "../../docs/posthog/coderouter-team-usage-30d.hogql",
        import.meta.url,
      ),
      "utf8",
    );
    expect(query).toContain("toString(toDate(timestamp)) AS day");
    expect(query).toContain(
      "toDate(timestamp) >= toDate(now()) - INTERVAL 29 DAY",
    );
    expect(query).toContain("toDate(timestamp) <= toDate(now())");
    expect(query).toContain("LIMIT 31");
    expect(query).not.toContain("now() - INTERVAL 30 DAY");
  });
});
