import { afterEach, describe, expect, mock, test } from "bun:test";

import { __test as analyticsTest } from "../services/coderouter/analytics";
import { coderouterTeamAnalyticsId } from
  "../services/coderouter/analyticsIdentity";
import {
  __test as vmMetricsTest,
  type CoderouterTeamMachineMetrics,
  type CoderouterVmMetrics,
} from "../services/coderouter/vmMetrics";

const scopeSecret = "test-only-scope-secret-at-least-32-bytes";
const config = {
  apiHost: "https://us.posthog.test",
  environmentId: "244066",
  endpointSecret: "phs_endpoint_read_only",
  vmEndpointName: "coderouter-vm-usage-30d",
  machinesEndpointName: "coderouter-team-machines-30d",
  scopeSecret,
};
const now = () => new Date("2026-09-02T12:00:00.000Z");
const vmId = "0f4b1c2e-1111-4222-8333-444455556666";
const usageColumns = [
  "input_tokens",
  "cached_input_tokens",
  "output_tokens",
  "total_tokens",
  "api_equivalent_usd",
  "priced_tokens",
  "unpriced_tokens",
];
const usageRow = {
  input_tokens: 1_200_000,
  cached_input_tokens: 200_000,
  output_tokens: 100_000,
  total_tokens: 1_300_000,
  api_equivalent_usd: 3.185,
  priced_tokens: 1_300_000,
  unpriced_tokens: 0,
};

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

  test("calls the VM Endpoint with the team pseudonym and the machine id", async () => {
    const posthogFetch = mock(async (...args: unknown[]) => {
      const [url, init] = args;
      expect(String(url)).toBe(
        "https://us.posthog.test/api/projects/244066/endpoints/coderouter-vm-usage-30d/run",
      );
      expect(
        new Headers((init as RequestInit | undefined)?.headers).get("authorization"),
      ).toBe("Bearer phs_endpoint_read_only");
      const body = JSON.parse(String((init as RequestInit | undefined)?.body));
      expect(body).toEqual({
        variables: {
          team_scope: coderouterTeamAnalyticsId("team-authorized", scopeSecret),
          vm_id: vmId,
        },
      });
      expect(JSON.stringify(body)).not.toContain("team-authorized");
      return Response.json({
        columns: ["day", ...usageColumns],
        results: [{ day: "2026-09-02", ...usageRow }],
        hasMore: false,
      });
    });

    const result = await vmMetricsTest.queryCoderouterVmMetrics(
      "team-authorized",
      vmId,
      { config: () => config, fetch: posthogFetch as typeof fetch, now },
    );
    expect(posthogFetch).toHaveBeenCalledTimes(1);
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

  test("calls the machines Endpoint with only the team pseudonym and sorts by tokens", async () => {
    const posthogFetch = mock(async (...args: unknown[]) => {
      const [url, init] = args;
      expect(String(url)).toBe(
        "https://us.posthog.test/api/projects/244066/endpoints/coderouter-team-machines-30d/run",
      );
      const body = JSON.parse(String((init as RequestInit | undefined)?.body));
      expect(body).toEqual({
        variables: {
          team_scope: coderouterTeamAnalyticsId("team-authorized", scopeSecret),
        },
      });
      return Response.json({
        columns: ["vm_id", ...usageColumns],
        results: [
          ["vm-small", 10, 0, 10, 20, 0.01, 20, 0],
          { vm_id: "vm-large", ...usageRow },
          ["vm-small", 5, 0, 5, 10, 0.005, 10, 0],
        ],
        hasMore: false,
      });
    });

    const result = await vmMetricsTest.queryCoderouterTeamMachineMetrics(
      "team-authorized",
      { config: () => config, fetch: posthogFetch as typeof fetch, now },
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

  test("fails closed when unconfigured, malformed, truncated, or given a bad id", async () => {
    const failures: Array<[string, string, number | undefined]> = [];
    const reportFailure = (
      query: "vm" | "machines",
      reason: string,
      status?: number,
    ) => failures.push([query, reason, status]);

    expect(
      await vmMetricsTest.queryCoderouterVmMetrics("team-1", vmId, {
        config: () => null,
        fetch,
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterVmMetrics("team-1", "not a vm id", {
        config: () => config,
        fetch: mock(async () => {
          throw new Error("must not be called");
        }) as typeof fetch,
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterVmMetrics("team-1", vmId, {
        config: () => config,
        fetch: mock(async () =>
          Response.json({
            columns: ["prompt"],
            results: [{ prompt: "private" }],
            hasMore: false,
          })) as typeof fetch,
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterTeamMachineMetrics("team-1", {
        config: () => config,
        fetch: mock(async () =>
          Response.json({
            columns: ["vm_id", ...usageColumns],
            results: [],
            hasMore: true,
          })) as typeof fetch,
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterTeamMachineMetrics("team-private", {
        config: () => config,
        fetch: mock(async () => new Response(null, { status: 503 })) as typeof fetch,
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(
      await vmMetricsTest.queryCoderouterTeamMachineMetrics("team-1", {
        config: () => config,
        fetch: mock(async () =>
          Response.json({
            columns: ["vm_id", ...usageColumns],
            results: [{ vm_id: "free text; not an id", ...usageRow }],
            hasMore: false,
          })) as typeof fetch,
        now,
        reportFailure,
      }),
    ).toEqual({ kind: "unavailable" });

    expect(failures).toEqual([
      ["vm", "configuration_missing", undefined],
      ["vm", "invalid_vm_id", undefined],
      ["vm", "malformed_response", undefined],
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

describe("CodeRouter per-machine metrics configuration", () => {
  const saved = { ...process.env };
  afterEach(() => {
    for (const key of Object.keys(process.env)) {
      if (!(key in saved)) delete process.env[key];
    }
    Object.assign(process.env, saved);
  });

  test("defaults Endpoint names and accepts safe overrides", () => {
    process.env.POSTHOG_CODEROUTER_ENDPOINT_SECRET = "phs_secret";
    process.env.POSTHOG_CODEROUTER_ENVIRONMENT_ID = "244066";
    process.env.CODEROUTER_ANALYTICS_SCOPE_SECRET = scopeSecret;
    process.env.POSTHOG_CODEROUTER_API_HOST = "https://eu.posthog.test/";
    delete process.env.POSTHOG_CODEROUTER_VM_ENDPOINT_NAME;
    delete process.env.POSTHOG_CODEROUTER_MACHINES_ENDPOINT_NAME;

    expect(vmMetricsTest.postHogVmMetricsConfig()).toEqual({
      apiHost: "https://eu.posthog.test",
      environmentId: "244066",
      endpointSecret: "phs_secret",
      scopeSecret,
      vmEndpointName: "coderouter-vm-usage-30d",
      machinesEndpointName: "coderouter-team-machines-30d",
    });

    process.env.POSTHOG_CODEROUTER_VM_ENDPOINT_NAME = "coderouter-vm-usage-30d-v2";
    process.env.POSTHOG_CODEROUTER_MACHINES_ENDPOINT_NAME = "../other-project";
    expect(vmMetricsTest.postHogVmMetricsConfig()).toMatchObject({
      vmEndpointName: "coderouter-vm-usage-30d-v2",
      machinesEndpointName: "coderouter-team-machines-30d",
    });

    process.env.CODEROUTER_ANALYTICS_SCOPE_SECRET = "short";
    expect(vmMetricsTest.postHogVmMetricsConfig()).toBeNull();
  });
});
