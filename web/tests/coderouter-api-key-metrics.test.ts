import { describe, expect, mock, test } from "bun:test";

import type { ClickHouseConfig } from "../services/coderouter/clickhouse";
import { loadCoderouterApiKeyUsage } from "../services/coderouter/apiKeyMetrics";

const config: ClickHouseConfig = {
  url: "https://ledger.clickhouse.test:8443",
  user: "coderouter_app",
  password: "app-password",
  database: "coderouter_dev",
};
const now = () => new Date("2026-09-20T12:00:00.000Z");

function jsonEachRow(rows: readonly unknown[]): Response {
  return new Response(rows.map((row) => JSON.stringify(row)).join("\n") + "\n");
}

describe("CodeRouter API-key usage", () => {
  test("aggregates only the selected team's keys over the 30-day window", async () => {
    const ledgerFetch = mock(async (...args: unknown[]) => {
      const [input, init] = args;
      const url = new URL(String(input));
      expect(url.searchParams.get("param_team_id")).toBe("team-authorized");
      expect(url.searchParams.get("param_start_day")).toBe("2026-08-22");
      expect(url.searchParams.get("param_end_day")).toBe("2026-09-20");
      const body = String((init as RequestInit | undefined)?.body);
      expect(body).toContain("FROM coderouter_dev.usage_events");
      expect(body).toContain("api_key_id IS NOT NULL");
      expect(body).toContain("api_key_id IN ({key_id_0:String})");
      expect(body).toContain("GROUP BY api_key_id");
      expect(body).not.toContain("team-authorized");
      return jsonEachRow([
        {
          api_key_id: "key-a",
          completions: 12,
          input_tokens: 1_000,
          cached_input_tokens: 100,
          output_tokens: 500,
          total_tokens: 1_500,
          api_equivalent_usd: 0.42,
          priced_tokens: 1_500,
          unpriced_tokens: 0,
        },
        {
          api_key_id: "old-key-not-listed",
          completions: 4,
          input_tokens: 10,
          cached_input_tokens: 0,
          output_tokens: 5,
          total_tokens: 15,
          api_equivalent_usd: 0.01,
          priced_tokens: 15,
          unpriced_tokens: 0,
        },
      ]);
    });

    const result = await loadCoderouterApiKeyUsage("team-authorized", ["key-a"], {
      clickhouse: { config: () => config, fetch: ledgerFetch as typeof fetch },
      now,
    });

    expect(result).toEqual({
      kind: "ready",
      byKey: {
        "key-a": {
          completions: 12,
          inputTokens: 1_000,
          cachedInputTokens: 100,
          outputTokens: 500,
          totalTokens: 1_500,
          apiEquivalentUsd: 0.42,
          pricedTokens: 1_500,
          unpricedTokens: 0,
        },
      },
    });
  });

  test("fails closed when the usage ledger is unavailable or malformed", async () => {
    const failures: string[] = [];
    expect(await loadCoderouterApiKeyUsage("team-1", ["key-a"], {
      clickhouse: { config: () => null, fetch },
      now,
      reportFailure: (reason) => failures.push(reason),
    })).toEqual({ kind: "unavailable" });

    expect(await loadCoderouterApiKeyUsage("team-1", ["key-a"], {
      clickhouse: {
        config: () => config,
        fetch: mock(async () => jsonEachRow([{ api_key_id: "key-a" }])) as typeof fetch,
      },
      now,
      reportFailure: (reason) => failures.push(reason),
    })).toEqual({ kind: "unavailable" });

    expect(failures).toEqual(["configuration_missing", "malformed_response"]);
  });
});
