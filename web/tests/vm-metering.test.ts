import { describe, expect, test } from "bun:test";

import type { ClickHouseDependencies } from "../services/coderouter/clickhouse";
import {
  VM_METERING_FLAG,
  runVmMetering,
  vmMeteringEnabled,
  type VmMeteringDependencies,
} from "../services/vms/metering/vmMeterJob";
import {
  stopEventVersion,
  vmRuntimeEvents,
  type VmMeterIntervalRow,
  type VmRuntimeEvent,
} from "../services/vms/metering/vmMeterEvents";
import { reconcileVmMeter } from "../services/vms/metering/vmMeterReconcile";
import {
  meteredSeconds,
  mergeMonthlyUsage,
  monthlyUsage,
} from "../services/vms/metering/vmMeterUsage";

const T0 = Date.parse("2026-10-01T00:00:00.000Z");
const MIN = 60_000;

function row(overrides: Partial<VmMeterIntervalRow> = {}): VmMeterIntervalRow {
  return {
    intervalId: "i-1",
    vmId: "vm-1",
    providerVmId: "fs-1",
    userId: "user-1",
    teamId: "team-1",
    planId: "pro",
    provider: "freestyle",
    vcpus: 4,
    memoryMb: 8192,
    startedAt: new Date(T0),
    endedAt: new Date(T0 + 30 * MIN),
    ...overrides,
  };
}

/** A ClickHouse table in memory with ReplacingMergeTree(version) semantics. */
function fakeClickHouse(options: { failInserts?: number } = {}) {
  const table = new Map<string, VmRuntimeEvent>();
  const inserts: { table: string; url: URL; rows: VmRuntimeEvent[] }[] = [];
  let failInserts = options.failInserts ?? 0;
  const dependencies: ClickHouseDependencies = {
    config: () => ({ url: "https://ch.test", user: "u", password: "p", database: "coderouter_dev" }),
    fetch: (async (input: string | URL | Request, init?: RequestInit) => {
      const url = new URL(String(input));
      const sql = url.searchParams.get("query") ?? String(init?.body ?? "");
      if (sql.startsWith("INSERT")) {
        if (failInserts > 0) {
          failInserts--;
          return new Response("Code: 252. TOO_MANY_PARTS", { status: 500 });
        }
        const rows = String(init?.body).trim().split("\n").map((line) => JSON.parse(line) as VmRuntimeEvent);
        inserts.push({ table: sql.split(" ")[2]!, url, rows });
        for (const event of rows) {
          const key = `${event.stack_user_id}|${event.vm_id}|${event.event_id}`;
          const existing = table.get(key);
          if (!existing || event.version >= existing.version) table.set(key, event);
        }
        return new Response("", { status: 200 });
      }
      // The only reads the job makes: the open intervals in ClickHouse.
      const open = openIntervals(table);
      return new Response(open.map((entry) => JSON.stringify(entry)).join("\n"), { status: 200 });
    }) as typeof fetch,
  };
  return { dependencies, table, inserts };
}

function openIntervals(table: Map<string, VmRuntimeEvent>) {
  const byInterval = new Map<string, { start?: VmRuntimeEvent; stop?: VmRuntimeEvent }>();
  for (const event of table.values()) {
    const entry = byInterval.get(event.interval_id) ?? {};
    entry[event.event_type] = event;
    byInterval.set(event.interval_id, entry);
  }
  return [...byInterval.entries()]
    .filter(([, entry]) => entry.start && !entry.stop)
    .map(([intervalId, entry]) => ({ interval_id: intervalId, vm_id: entry.start!.vm_id }));
}

function deps(overrides: Partial<VmMeteringDependencies> & { clickhouse: ClickHouseDependencies }): VmMeteringDependencies {
  return {
    env: { [VM_METERING_FLAG]: "1" },
    now: () => new Date(T0 + 60 * MIN),
    loadIntervals: async () => [],
    loadOpenIntervals: async () => [],
    loadIntervalsById: async () => [],
    providerStatus: async () => "running",
    ...overrides,
  };
}

describe("VM runtime events", () => {
  test("a closed interval is one start and one stop with deterministic ids", () => {
    const events = vmRuntimeEvents(row(), "postgres");
    expect(events.map((event) => [event.event_id, event.event_type, event.event_time])).toEqual([
      ["i-1:start", "start", "2026-10-01T00:00:00.000Z"],
      ["i-1:stop", "stop", "2026-10-01T00:30:00.000Z"],
    ]);
    expect(events.every((event) => event.interval_started_at === "2026-10-01T00:00:00.000Z")).toBe(true);
    expect(events[0]).toMatchObject({ vm_id: "vm-1", stack_user_id: "user-1", team_id: "team-1", vcpus: 4, memory_mb: 8192, source: "postgres", version: 0 });
  });

  test("an open interval is only a start", () => {
    expect(vmRuntimeEvents(row({ endedAt: null }), "postgres").map((event) => event.event_type)).toEqual(["start"]);
  });

  test("an earlier stop always carries the higher version", () => {
    expect(stopEventVersion(new Date(T0))).toBeGreaterThan(stopEventVersion(new Date(T0 + 1)));
    expect(Number.isSafeInteger(stopEventVersion(new Date(T0)))).toBe(true);
  });
});

describe("metered seconds", () => {
  const period = { start: new Date(T0), end: new Date(T0 + 24 * 60 * MIN) };

  test("only time inside an interval counts; paused gaps never count", () => {
    const intervals = [
      { startedAt: new Date(T0), endedAt: new Date(T0 + 10 * MIN) },
      // paused 50 minutes
      { startedAt: new Date(T0 + 60 * MIN), endedAt: new Date(T0 + 70 * MIN) },
    ];
    expect(meteredSeconds(intervals, period, new Date(T0 + 120 * MIN))).toBe(1200);
  });

  test("intervals are clipped to the period and open ones run to as-of", () => {
    const intervals = [
      { startedAt: new Date(T0 - 30 * MIN), endedAt: new Date(T0 + 30 * MIN) },
      { startedAt: new Date(T0 + 23 * 60 * MIN), endedAt: null },
    ];
    expect(meteredSeconds(intervals, period, new Date(T0 + 23 * 60 * MIN + 15 * MIN))).toBe(30 * 60 + 15 * 60);
    expect(meteredSeconds(intervals, period, new Date(T0 + 48 * 60 * MIN))).toBe(30 * 60 + 60 * 60);
  });
});

describe("reconciliation", () => {
  const now = new Date(T0 + 60 * MIN);

  test("Postgres open but the provider says paused: stop at the observation", () => {
    const result = reconcileVmMeter({
      postgresOpen: [row({ endedAt: null })],
      clickhouseOpen: [{ intervalId: "i-1", vmId: "vm-1" }],
      postgresClosedForClickhouseOpen: [],
      providerStatuses: new Map([["vm-1", "paused"]]),
      observedAt: now,
    });
    expect(result.events.map((event) => [event.event_id, event.event_time, event.source])).toEqual([
      ["i-1:stop", now.toISOString(), "reconcile"],
    ]);
    expect(result.drift).toEqual({ providerStopped: 1, missedStops: 0, missingStarts: 0, unknownStatus: 0 });
  });

  test("ClickHouse open but Postgres closed: the missed stop is replayed from Postgres", () => {
    const closed = row({ intervalId: "i-2", endedAt: new Date(T0 + 5 * MIN) });
    const result = reconcileVmMeter({
      postgresOpen: [],
      clickhouseOpen: [{ intervalId: "i-2", vmId: "vm-1" }],
      postgresClosedForClickhouseOpen: [closed],
      providerStatuses: new Map(),
      observedAt: now,
    });
    expect(result.events.map((event) => [event.event_id, event.event_time, event.source])).toEqual([
      ["i-2:stop", "2026-10-01T00:05:00.000Z", "postgres"],
    ]);
    expect(result.drift.missedStops).toBe(1);
  });

  test("Postgres open but ClickHouse has no start: the start is replayed", () => {
    const result = reconcileVmMeter({
      postgresOpen: [row({ endedAt: null })],
      clickhouseOpen: [],
      postgresClosedForClickhouseOpen: [],
      providerStatuses: new Map([["vm-1", "running"]]),
      observedAt: now,
    });
    expect(result.events.map((event) => event.event_id)).toEqual(["i-1:start"]);
    expect(result.drift.missingStarts).toBe(1);
  });

  test("a transitional or failed provider read never stops the meter", () => {
    const result = reconcileVmMeter({
      postgresOpen: [row({ endedAt: null }), row({ intervalId: "i-3", vmId: "vm-3" })],
      clickhouseOpen: [{ intervalId: "i-1", vmId: "vm-1" }, { intervalId: "i-3", vmId: "vm-3" }],
      postgresClosedForClickhouseOpen: [],
      providerStatuses: new Map([["vm-1", "creating"], ["vm-3", "unknown"]]),
      observedAt: now,
    });
    expect(result.events).toEqual([]);
    expect(result.drift.unknownStatus).toBe(1);
  });
});

describe("vm-metering job", () => {
  test("off unless the flag is set", async () => {
    expect(vmMeteringEnabled({})).toBe(false);
    expect(vmMeteringEnabled({ [VM_METERING_FLAG]: "1" })).toBe(true);
    const { dependencies, inserts } = fakeClickHouse();
    const result = await runVmMetering(deps({ clickhouse: dependencies, env: {} }));
    expect(result).toEqual({ enabled: false });
    expect(inserts).toEqual([]);
  });

  test("inserts wait for the server to accept the rows", async () => {
    const { dependencies, inserts } = fakeClickHouse();
    await runVmMetering(deps({ clickhouse: dependencies, loadIntervals: async () => [row()] }));
    expect(inserts[0]?.table).toBe("coderouter_dev.vm_runtime_events");
    expect(inserts[0]?.url.searchParams.get("wait_for_async_insert")).toBe("1");
  });

  test("replaying the same sync three times leaves one row per event", async () => {
    const { dependencies, table, inserts } = fakeClickHouse();
    const rows = [row(), row({ intervalId: "i-2", startedAt: new Date(T0 + 40 * MIN), endedAt: null })];
    for (let run = 0; run < 3; run++) {
      await runVmMetering(deps({ clickhouse: dependencies, loadIntervals: async () => rows }));
    }
    expect(inserts.length).toBe(3);
    expect([...table.keys()].sort()).toEqual(["user-1|vm-1|i-1:start", "user-1|vm-1|i-1:stop", "user-1|vm-1|i-2:start"]);
  });

  test("a later Postgres stop does not replace an earlier reconcile stop", async () => {
    const { dependencies, table } = fakeClickHouse();
    const open = row({ endedAt: null });
    await runVmMetering(deps({
      clickhouse: dependencies,
      loadIntervals: async () => [open],
      loadOpenIntervals: async () => [open],
      providerStatus: async () => "paused",
      now: () => new Date(T0 + 20 * MIN),
    }));
    // Five minutes later the status cron closes the Postgres interval.
    await runVmMetering(deps({
      clickhouse: dependencies,
      loadIntervals: async () => [row({ endedAt: new Date(T0 + 25 * MIN) })],
    }));
    expect(table.get("user-1|vm-1|i-1:stop")).toMatchObject({ event_time: "2026-10-01T00:20:00.000Z", source: "reconcile" });
  });

  test("a failed insert is reported and the next run writes the rows", async () => {
    const { dependencies, table } = fakeClickHouse({ failInserts: 1 });
    const first = await runVmMetering(deps({ clickhouse: dependencies, loadIntervals: async () => [row()] }));
    expect(first).toMatchObject({ enabled: true, inserted: 0, insertFailed: true });
    expect(table.size).toBe(0);
    const second = await runVmMetering(deps({ clickhouse: dependencies, loadIntervals: async () => [row()] }));
    expect(second).toMatchObject({ enabled: true, inserted: 2, insertFailed: false });
    expect(table.size).toBe(2);
  });
});

describe("monthly usage", () => {
  test("binds the period as query parameters and merges VM and token rows", async () => {
    const urls: URL[] = [];
    const clickhouse: ClickHouseDependencies = {
      config: () => ({ url: "https://ch.test", user: "u", password: "p", database: "coderouter" }),
      fetch: (async (input: string | URL | Request, init?: RequestInit) => {
        const url = new URL(String(input));
        urls.push(url);
        const body = String(init?.body);
        if (body.includes("vm_runtime_intervals")) {
          return new Response(JSON.stringify({ team_id: "team-1", stack_user_id: "user-1", vm_seconds: 3600, vcpu_seconds: 14400, intervals: 2 }), { status: 200 });
        }
        return new Response([
          JSON.stringify({ team_id: "team-1", stack_user_id: "user-1", input_tokens: 10, cached_input_tokens: 4, output_tokens: 5, api_equivalent_usd: 0.5 }),
          JSON.stringify({ team_id: "team-2", stack_user_id: "user-2", input_tokens: 1, cached_input_tokens: 0, output_tokens: 1, api_equivalent_usd: 0.01 }),
        ].join("\n"), { status: 200 });
      }) as typeof fetch,
    };
    const result = await monthlyUsage({ year: 2026, month: 10 }, { clickhouse, now: () => new Date("2026-10-15T00:00:00.000Z") });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.rows).toEqual([
      { teamId: "team-1", userId: "user-1", vmSeconds: 3600, vcpuSeconds: 14400, intervals: 2, inputTokens: 10, cachedInputTokens: 4, outputTokens: 5, apiEquivalentUsd: 0.5 },
      { teamId: "team-2", userId: "user-2", vmSeconds: 0, vcpuSeconds: 0, intervals: 0, inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, apiEquivalentUsd: 0.01 },
    ]);
    expect(urls[0]?.searchParams.get("param_period_start")).toBe("2026-10-01 00:00:00.000");
    expect(urls[0]?.searchParams.get("param_period_end")).toBe("2026-11-01 00:00:00.000");
    expect(urls[0]?.searchParams.get("param_as_of")).toBe("2026-10-15 00:00:00.000");
  });

  test("mergeMonthlyUsage sorts by team then user", () => {
    expect(mergeMonthlyUsage([], []).length).toBe(0);
  });
});
