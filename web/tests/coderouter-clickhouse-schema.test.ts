import { afterEach, describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { ClickHouseDependencies } from "../services/coderouter/clickhouse";
import {
  CLICKHOUSE_EXPECTED_COLUMNS,
  CLICKHOUSE_SCHEMA_CACHE_MS,
  checkClickHouseSchema,
  resetClickHouseSchemaCacheForTests,
} from "../services/coderouter/clickhouseSchema";
import type { AlertInput, AlertResult } from "../services/observability/alerts";
import {
  CODEROUTER_SCHEMA_DRIFT_ALERT_KEY,
  runCoderouterAlertChecks,
} from "../services/observability/coderouterAlerts";
import type { VmAlertStateStore } from "../services/observability/vmAlerts";

const MIGRATIONS_DIR = join(import.meta.dir, "..", "db", "clickhouse");

/**
 * Every column the migration files create, attributed to the LAST file that
 * adds it: a database created before a column was folded into 001's CREATE
 * still needs the later ALTER.
 */
function columnsFromMigrations(): Map<string, string> {
  const owners = new Map<string, string>();
  for (const file of readdirSync(MIGRATIONS_DIR).filter((name) => name.endsWith(".sql")).sort()) {
    const sql = readFileSync(join(MIGRATIONS_DIR, file), "utf8").replace(/--.*$/gm, "");
    for (const match of sql.matchAll(/CREATE TABLE IF NOT EXISTS \{db\}\.(\w+)\s*\(([\s\S]*?)\n\)/g)) {
      for (const line of match[2]!.split("\n")) {
        const column = line.trim().match(/^(\w+)\s/)?.[1];
        if (column) owners.set(`${match[1]}.${column}`, file);
      }
    }
    for (const match of sql.matchAll(/ALTER TABLE \{db\}\.(\w+)\s+ADD COLUMN IF NOT EXISTS (\w+)/g)) {
      owners.set(`${match[1]}.${match[2]}`, file);
    }
  }
  return owners;
}

function fakeClickHouse(columns: readonly string[] | { status: number }) {
  const calls: URL[] = [];
  const dependencies: ClickHouseDependencies = {
    config: () => ({ url: "https://ch.test", user: "u", password: "p", database: "coderouter" }),
    fetch: (async (input: string | URL | Request) => {
      calls.push(new URL(String(input)));
      if (!Array.isArray(columns)) return new Response("Code: 81. UNKNOWN_DATABASE", { status: (columns as { status: number }).status });
      const body = (columns as readonly string[]).map((entry) => {
        const [table, name] = entry.split(".");
        return JSON.stringify({ table, name });
      }).join("\n");
      return new Response(body, { status: 200 });
    }) as typeof fetch,
  };
  return { dependencies, calls };
}

const allColumns = CLICKHOUSE_EXPECTED_COLUMNS.map((entry) => `${entry.table}.${entry.column}`);
// Production on 2026-10-08: 005 and 006 were never applied.
const productionColumns = allColumns.filter((column) =>
  !["usage_events.api_key_id", "route_events.api_key_id", "route_events.held_ms", "route_events.hold_count"].includes(column));

afterEach(() => resetClickHouseSchemaCacheForTests());

describe("ClickHouse schema drift check", () => {
  test("the expected-column manifest matches web/db/clickhouse migrations", () => {
    const fromSql = columnsFromMigrations();
    const manifest = new Map(CLICKHOUSE_EXPECTED_COLUMNS.map((entry) => [`${entry.table}.${entry.column}`, entry.migration]));
    expect(Object.fromEntries([...manifest].sort())).toEqual(Object.fromEntries([...fromSql].sort()));
  });

  test("names the unapplied migrations and missing columns", async () => {
    const { dependencies, calls } = fakeClickHouse(productionColumns);
    const result = await checkClickHouseSchema({ clickhouse: dependencies });
    expect(result).toEqual({
      kind: "drift",
      missingColumns: ["route_events.api_key_id", "route_events.held_ms", "route_events.hold_count", "usage_events.api_key_id"],
      migrations: ["005_usage_events_api_key.sql", "006_route_events_capacity_hold.sql"],
    });
    expect(calls).toHaveLength(1);
    expect(calls[0]!.searchParams.get("param_database")).toBe("coderouter");
  });

  test("a fully migrated database is ok, and the answer is cached", async () => {
    const { dependencies, calls } = fakeClickHouse(allColumns);
    let now = 1_000;
    expect(await checkClickHouseSchema({ clickhouse: dependencies, now: () => now })).toEqual({ kind: "ok" });
    now += CLICKHOUSE_SCHEMA_CACHE_MS - 1;
    expect(await checkClickHouseSchema({ clickhouse: dependencies, now: () => now })).toEqual({ kind: "ok" });
    expect(calls).toHaveLength(1);
    now += 1;
    await checkClickHouseSchema({ clickhouse: dependencies, now: () => now });
    expect(calls).toHaveLength(2);
  });

  test("unconfigured ClickHouse is quiet and an HTTP failure is not cached", async () => {
    expect(await checkClickHouseSchema({
      clickhouse: { config: () => null, fetch: (async () => { throw new Error("no fetch"); }) as unknown as typeof fetch },
    })).toEqual({ kind: "disabled" });
    const { dependencies, calls } = fakeClickHouse({ status: 404 });
    expect(await checkClickHouseSchema({ clickhouse: dependencies })).toEqual({ kind: "unavailable", reason: "http_404" });
    await checkClickHouseSchema({ clickhouse: dependencies });
    expect(calls).toHaveLength(2);
  });
});

function memoryStore() {
  const state = new Map<string, { active: boolean; lastSentAt: Date | null; lease: string | null }>();
  let leases = 0;
  const store: VmAlertStateStore = {
    claim: async (input, now) => {
      const row = state.get(input.key);
      const due = !row || !row.active || !row.lastSentAt || now.getTime() - row.lastSentAt.getTime() > 24 * 3_600_000;
      if (!due || row?.lease) return null;
      const lease = `lease-${++leases}`;
      state.set(input.key, { active: true, lastSentAt: row?.lastSentAt ?? null, lease });
      return lease;
    },
    acknowledge: async (key, leaseId, now) => {
      const row = state.get(key);
      if (row?.lease === leaseId) state.set(key, { active: true, lastSentAt: now, lease: null });
    },
    clear: async (key) => {
      const row = state.get(key);
      if (row) state.set(key, { ...row, active: false, lease: null });
    },
  };
  return { store, state };
}

describe("coderouter alerts cron: schema drift", () => {
  const drift = {
    kind: "drift" as const,
    missingColumns: ["route_events.held_ms", "usage_events.api_key_id"],
    migrations: ["005_usage_events_api_key.sql", "006_route_events_capacity_hold.sql"],
  };

  function harness(schema: () => Promise<Awaited<ReturnType<typeof checkClickHouseSchema>>>, store: VmAlertStateStore | null) {
    const sent: AlertInput[] = [];
    const reported: { message: string; context: Record<string, unknown> }[] = [];
    let now = new Date("2026-10-08T16:00:00Z");
    const run = () => runCoderouterAlertChecks({
      env: { CMUX_ALERTS_SLACK_WEBHOOK_URL: "https://hooks.slack.test/x" },
      health: async () => ({ status: "ok", checks: [], checkedAt: now.toISOString() }),
      routeEvents: async () => ({ ok: true, rows: [] }),
      sendAlert: async (input): Promise<AlertResult> => {
        sent.push(input);
        return { sent: true, configured: true, status: 200 };
      },
      schemaCheck: schema,
      alertStateStore: () => {
        if (!store) throw new Error("DATABASE_URL missing");
        return store;
      },
      reportError: (error, context) => {
        reported.push({ message: (error as Error).message, context });
      },
      now: () => now,
    });
    return { sent, reported, run, advance: (ms: number) => { now = new Date(now.getTime() + ms); } };
  }

  test("drift sends one critical Slack alert and one Sentry event naming the migrations, then dedupes", async () => {
    const { store } = memoryStore();
    const { sent, reported, run, advance } = harness(async () => drift, store);
    const first = await run();
    expect(first.clickhouseSchema).toBe("drift");
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ key: CODEROUTER_SCHEMA_DRIFT_ALERT_KEY, severity: "critical" });
    expect(sent[0]!.body).toContain("005_usage_events_api_key.sql, 006_route_events_capacity_hold.sql");
    expect(reported).toHaveLength(1);
    expect(reported[0]!.message).toContain("005_usage_events_api_key.sql");
    expect(reported[0]!.context.migrations).toBe("005_usage_events_api_key.sql,006_route_events_capacity_hold.sql");

    advance(5 * 60_000);
    await run();
    expect(sent).toHaveLength(1);
    expect(reported).toHaveLength(1);

    advance(25 * 3_600_000);
    await run();
    expect(sent).toHaveLength(2);
  });

  test("a clean check clears the dedupe state so the next drift alerts at once", async () => {
    const { store, state } = memoryStore();
    let schema: Awaited<ReturnType<typeof checkClickHouseSchema>> = drift;
    const { sent, run, advance } = harness(async () => schema, store);
    await run();
    schema = { kind: "ok" };
    advance(5 * 60_000);
    expect((await run()).clickhouseSchema).toBe("ok");
    expect(state.get(CODEROUTER_SCHEMA_DRIFT_ALERT_KEY)?.active).toBe(false);
    schema = drift;
    advance(5 * 60_000);
    await run();
    expect(sent).toHaveLength(2);
  });

  test("disabled or unreachable ClickHouse never alerts; a missing dedupe store fails open", async () => {
    for (const schema of [{ kind: "disabled" as const }, { kind: "unavailable" as const, reason: "http_503" }]) {
      const { sent, reported, run } = harness(async () => schema, memoryStore().store);
      expect((await run()).clickhouseSchema).toBe(schema.kind);
      expect(sent).toEqual([]);
      expect(reported).toEqual([]);
    }
    const { sent, run } = harness(async () => drift, null);
    await run();
    expect(sent.map((alert) => alert.key)).toEqual([CODEROUTER_SCHEMA_DRIFT_ALERT_KEY]);
  });
});
