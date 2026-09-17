import { describe, expect, mock, test } from "bun:test";

import type { ClickHouseConfig } from "../services/coderouter/clickhouse";
import {
  __test as metricsTest,
  type CoderouterTeamMetrics,
} from "../services/coderouter/teamMetrics";

const config: ClickHouseConfig = {
  url: "https://ledger.clickhouse.test:8443",
  user: "coderouter_app",
  password: "app-password",
  database: "coderouter_dev",
};
const now = () => new Date("2026-08-08T12:00:00.000Z");
const usageRow = {
  input_tokens: 1_200_000,
  cached_input_tokens: 200_000,
  output_tokens: 100_000,
  total_tokens: 1_300_000,
  api_equivalent_usd: 3.185,
  priced_tokens: 1_300_000,
  unpriced_tokens: 0,
};

function jsonEachRow(rows: readonly unknown[]): Response {
  return new Response(rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
}

describe("CodeRouter team metrics", () => {
  test("queries the ledger with bound parameters and a 30-day UTC window", async () => {
    const ledgerFetch = mock(async (...args: unknown[]) => {
      const [input, init] = args;
      const url = new URL(String(input));
      expect(url.origin).toBe("https://ledger.clickhouse.test:8443");
      expect(url.searchParams.get("param_team_id")).toBe("team-authorized");
      expect(url.searchParams.get("param_start_day")).toBe("2026-07-10");
      expect(url.searchParams.get("param_end_day")).toBe("2026-08-08");
      const body = String((init as RequestInit | undefined)?.body);
      expect(body).toContain("FROM coderouter_dev.usage_events");
      expect(body).toContain("WHERE team_id = {team_id:String}");
      expect(body).toContain("toDate(event_time) >= {start_day:Date}");
      expect(body).toContain("LIMIT 31");
      expect(body).not.toContain("team-authorized");
      return jsonEachRow([{ day: "2026-08-08", ...usageRow }]);
    });

    const result = await metricsTest.queryCoderouterTeamMetrics(
      "team-authorized",
      { clickhouse: { config: () => config, fetch: ledgerFetch as typeof fetch }, now },
    );

    expect(ledgerFetch).toHaveBeenCalledTimes(1);
    expect(result.kind).toBe("ready");
    const ready = result as Extract<CoderouterTeamMetrics, { kind: "ready" }>;
    expect(ready.periodDays).toBe(30);
    expect(ready.rateCardVersion).toBe("2026-08-08");
    expect(ready.totals).toEqual({
      inputTokens: 1_200_000,
      cachedInputTokens: 200_000,
      outputTokens: 100_000,
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.185,
      pricedTokens: 1_300_000,
      unpricedTokens: 0,
    });
    expect(ready.daily).toHaveLength(30);
    expect(ready.daily[0]).toEqual({ day: "2026-07-10", totalTokens: 0, apiEquivalentUsd: 0 });
    expect(ready.daily.at(-1)).toEqual({
      day: "2026-08-08",
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.185,
    });
    expect(JSON.stringify(ready)).not.toMatch(/model|provider|member|account/i);
  });

  test("accepts partial pricing coverage and quoted UInt64 sums", () => {
    const result = metricsTest.metricsFromRows(
      [{
        day: "2026-08-08",
        input_tokens: "84",
        cached_input_tokens: "20",
        output_tokens: "26",
        total_tokens: "110",
        api_equivalent_usd: 0.0003,
        priced_tokens: "100",
        unpriced_tokens: "10",
      }],
      now(),
    );

    expect(result).not.toBeNull();
    expect(result!.totals.totalTokens).toBe(110);
    expect(result!.totals.pricedTokens).toBe(100);
    expect(result!.totals.unpricedTokens).toBe(10);
  });

  test("fails closed when the ledger is disabled or rows are malformed", async () => {
    const failures: string[] = [];
    expect(
      await metricsTest.queryCoderouterTeamMetrics("team-1", {
        clickhouse: { config: () => null, fetch },
        now,
        reportFailure: (reason) => failures.push(reason),
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await metricsTest.queryCoderouterTeamMetrics("team-1", {
        clickhouse: {
          config: () => config,
          fetch: mock(async () => jsonEachRow([{ prompt: "private" }])) as typeof fetch,
        },
        now,
        reportFailure: (reason) => failures.push(reason),
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await metricsTest.queryCoderouterTeamMetrics("team-1", {
        clickhouse: {
          config: () => config,
          fetch: mock(async () =>
            jsonEachRow([{ day: "2026-08-08", ...usageRow, cached_input_tokens: 2_000_000 }])) as typeof fetch,
        },
        now,
        reportFailure: (reason) => failures.push(reason),
      }),
    ).toEqual({ kind: "unavailable" });

    expect(failures).toEqual(["configuration_missing", "invalid_metrics", "invalid_metrics"]);
  });

  test("rejects a 31st UTC day instead of silently truncating", async () => {
    const failures: string[] = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-1", {
      clickhouse: {
        config: () => config,
        fetch: mock(async () =>
          jsonEachRow(Array.from({ length: 31 }, (_, index) => ({
            day: `2026-07-${String(index + 1).padStart(2, "0")}`,
            input_tokens: 1,
            cached_input_tokens: 0,
            output_tokens: 1,
            total_tokens: 2,
            api_equivalent_usd: 0,
            priced_tokens: 0,
            unpriced_tokens: 2,
          })))) as typeof fetch,
      },
      now,
      reportFailure: (reason) => failures.push(reason),
    });
    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual(["malformed_response"]);
  });

  test("reports query failures without including the team identity", async () => {
    const failures: Array<{ reason: string; status?: number }> = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      clickhouse: {
        config: () => config,
        fetch: mock(async () => new Response("denied", { status: 503 })) as typeof fetch,
      },
      now,
      reportFailure: (reason, status) => failures.push({ reason, status }),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual([{ reason: "endpoint_status", status: 503 }]);
    expect(JSON.stringify(failures)).not.toContain("team-private");
  });

  test("classifies invalid JSONEachRow as a malformed response", async () => {
    const failures: string[] = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      clickhouse: {
        config: () => config,
        fetch: mock(async () => new Response("{\n", { status: 200 })) as typeof fetch,
      },
      now,
      reportFailure: (reason) => failures.push(reason),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual(["malformed_response"]);
  });

  test("classifies body stream failures as request failures", async () => {
    const failures: string[] = [];
    const result = await metricsTest.queryCoderouterTeamMetrics("team-private", {
      clickhouse: {
        config: () => config,
        fetch: mock(async () =>
          new Response(new ReadableStream({
            start(controller) {
              controller.error(new Error("stream failed"));
            },
          }), { status: 200 })) as typeof fetch,
      },
      now,
      reportFailure: (reason) => failures.push(reason),
    });

    expect(result).toEqual({ kind: "unavailable" });
    expect(failures).toEqual(["request_failed"]);
  });
});
