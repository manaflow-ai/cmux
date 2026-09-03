import { describe, expect, mock, test } from "bun:test";

import { __test as analyticsTest } from "../services/coderouter/analytics";
import type { ClickHouseConfig } from "../services/coderouter/clickhouse";
import {
  __test as vmMetricsTest,
  type CoderouterTeamMachineMetrics,
  type CoderouterVmMetrics,
} from "../services/coderouter/vmMetrics";

const config: ClickHouseConfig = {
  url: "https://ledger.clickhouse.test:8443",
  user: "coderouter_app",
  password: "app-password",
  database: "coderouter_dev",
};
const now = () => new Date("2026-09-02T12:00:00.000Z");
const vmId = "0f4b1c2e-1111-4222-8333-444455556666";
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

describe("CodeRouter per-machine metrics", () => {
  test("stamps coderouter_vm_id on $ai_generation only for bound traffic", () => {
    const bound = analyticsTest.aiUsageProperties(
      { provider: "codex", model: "gpt-5.2", input_tokens: 5, output_tokens: 5, vm_id: vmId },
      "team-scope",
    );
    expect(bound).toMatchObject({ coderouter_vm_id: vmId });
    expect(bound).not.toHaveProperty("vm_id");
    expect(
      analyticsTest.aiUsageProperties(
        { provider: "codex", model: "gpt-5.2", input_tokens: 5, output_tokens: 5 },
        "team-scope",
      ),
    ).not.toHaveProperty("coderouter_vm_id");
    expect(
      analyticsTest.eventProperties("coderouter_vm_usage_viewed", {
        surface: "vm_self_api",
        outcome: "ready",
      }),
    ).toEqual({ surface: "vm_self_api", outcome: "ready" });
    expect(
      analyticsTest.eventProperties("coderouter_vm_usage_viewed", {
        surface: "/private/path",
        outcome: "ready",
      }),
    ).toBeNull();
  });

  test("filters the ledger by team and machine id through bound parameters", async () => {
    const ledgerFetch = mock(async (...args: unknown[]) => {
      const [input, init] = args;
      const url = new URL(String(input));
      expect(url.searchParams.get("param_team_id")).toBe("team-authorized");
      expect(url.searchParams.get("param_vm_id")).toBe(vmId);
      expect(url.searchParams.get("param_start_day")).toBe("2026-08-04");
      expect(url.searchParams.get("param_end_day")).toBe("2026-09-02");
      const body = String((init as RequestInit | undefined)?.body);
      expect(body).toContain("FROM coderouter_dev.usage_events");
      expect(body).toContain("team_id = {team_id:String}");
      expect(body).toContain("vm_id = {vm_id:String}");
      expect(body).not.toContain("team-authorized");
      expect(body).not.toContain(vmId);
      return jsonEachRow([{ day: "2026-09-02", ...usageRow }]);
    });

    const result = await vmMetricsTest.queryCoderouterVmMetrics(
      "team-authorized",
      vmId,
      { clickhouse: { config: () => config, fetch: ledgerFetch as typeof fetch }, now },
    );
    expect(ledgerFetch).toHaveBeenCalledTimes(1);
    expect(result.kind).toBe("ready");
    const ready = result as Extract<CoderouterVmMetrics, { kind: "ready" }>;
    expect(ready.vmId).toBe(vmId);
    expect(ready.periodDays).toBe(30);
    expect(ready.daily).toHaveLength(30);
    expect(ready.totals.totalTokens).toBe(1_300_000);
    expect(ready.totals.apiEquivalentUsd).toBe(3.185);
    expect(ready.daily.at(-1)).toEqual({
      day: "2026-09-02",
      totalTokens: 1_300_000,
      apiEquivalentUsd: 3.185,
    });
    expect(ready.daily[0]).toEqual({
      day: "2026-08-04",
      totalTokens: 0,
      apiEquivalentUsd: 0,
    });
  });

  test("groups a team's usage by machine and sorts by tokens", async () => {
    const ledgerFetch = mock(async (...args: unknown[]) => {
      const [input, init] = args;
      const url = new URL(String(input));
      expect(url.searchParams.get("param_team_id")).toBe("team-authorized");
      expect(url.searchParams.has("param_vm_id")).toBe(false);
      const body = String((init as RequestInit | undefined)?.body);
      expect(body).toContain("vm_id IS NOT NULL");
      expect(body).toContain("GROUP BY vm_id");
      expect(body).toContain("LIMIT 200");
      return jsonEachRow([
        { vm_id: "vm-small", input_tokens: 10, cached_input_tokens: 0, output_tokens: 10, total_tokens: 20, api_equivalent_usd: 0.01, priced_tokens: 20, unpriced_tokens: 0 },
        { vm_id: "vm-large", ...usageRow },
        { vm_id: "vm-small", input_tokens: 5, cached_input_tokens: 0, output_tokens: 5, total_tokens: 10, api_equivalent_usd: 0.005, priced_tokens: 10, unpriced_tokens: 0 },
      ]);
    });

    const result = await vmMetricsTest.queryCoderouterTeamMachineMetrics(
      "team-authorized",
      { clickhouse: { config: () => config, fetch: ledgerFetch as typeof fetch }, now },
    );
    expect(result.kind).toBe("ready");
    const ready = result as Extract<
      CoderouterTeamMachineMetrics,
      { kind: "ready" }
    >;
    expect(ready.machines.map((machine) => machine.vmId)).toEqual([
      "vm-large",
      "vm-small",
    ]);
    expect(ready.machines[1].totals.totalTokens).toBe(30);
    expect(ready.machines[1].totals.apiEquivalentUsd).toBeCloseTo(0.015);
    expect(JSON.stringify(ready)).not.toMatch(/model|provider|member|account/i);
  });

  test("fails closed when disabled, malformed, truncated, or given a bad id", async () => {
    const failures: Array<[string, string, number | undefined]> = [];
    const reportFailure = (
      query: "vm" | "machines",
      reason: string,
      status?: number,
    ) => failures.push([query, reason, status]);
    const withFetch = (fetchImpl: typeof fetch) => ({
      clickhouse: { config: () => config, fetch: fetchImpl },
      now,
      reportFailure,
    });

    expect(
      await vmMetricsTest.queryCoderouterVmMetrics("team-1", vmId, {
        clickhouse: { config: () => null, fetch },
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterVmMetrics(
        "team-1",
        "not a vm id",
        withFetch(mock(async () => {
          throw new Error("must not be called");
        }) as typeof fetch),
      ),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterVmMetrics(
        "team-1",
        vmId,
        withFetch(mock(async () => jsonEachRow([{ prompt: "private" }])) as typeof fetch),
      ),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterTeamMachineMetrics(
        "team-1",
        withFetch(mock(async () =>
          jsonEachRow(Array.from({ length: 201 }, (_, index) => ({
            vm_id: `vm-${index}`,
            ...usageRow,
          })))) as typeof fetch),
      ),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterTeamMachineMetrics(
        "team-private",
        withFetch(mock(async () => new Response(null, { status: 503 })) as typeof fetch),
      ),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterTeamMachineMetrics(
        "team-1",
        withFetch(mock(async () =>
          jsonEachRow([{ vm_id: "free text; not an id", ...usageRow }])) as typeof fetch),
      ),
    ).toEqual({ kind: "unavailable" });

    expect(failures).toEqual([
      ["vm", "configuration_missing", undefined],
      ["vm", "invalid_vm_id", undefined],
      ["vm", "invalid_metrics", undefined],
      ["machines", "malformed_response", undefined],
      ["machines", "endpoint_status", 503],
      ["machines", "invalid_metrics", undefined],
    ]);
    expect(JSON.stringify(failures)).not.toContain("team-private");
  });

  test("rejects rows whose token invariants do not hold", () => {
    expect(
      vmMetricsTest.vmMetricsFromRows(
        vmId,
        [{ day: "2026-09-02", ...usageRow, cached_input_tokens: 2_000_000 }],
        now(),
      ),
    ).toBeNull();
    expect(
      vmMetricsTest.machineMetricsFromRows(
        [{ vm_id: vmId, ...usageRow, priced_tokens: 1 }],
        now(),
      ),
    ).toBeNull();
  });
});
