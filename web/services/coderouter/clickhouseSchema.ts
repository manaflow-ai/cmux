// Detects ClickHouse schema drift: a migration under web/db/clickhouse/ that
// was merged but never applied to the configured database. Nothing runs those
// migrations at deploy time, and JSONEachRow inserts silently drop unknown
// fields, so an unapplied migration loses data without any insert error and
// surfaces only when a read selects the missing column (CODEROUTER-WEB-19).
//
// The manifest below lists every column the migrations create, attributed to
// the last migration file that adds it (a column added by an ALTER and later
// folded into the 001 CREATE is still missing from databases created earlier).
// A test parses the SQL files and fails when this manifest falls out of sync.
import {
  defaultClickHouseDependencies,
  query,
  type ClickHouseDependencies,
} from "./clickhouse";

export type ClickHouseExpectedColumn = {
  readonly table: string;
  readonly column: string;
  readonly migration: string;
};

const CREATE_001 = "001_coderouter_events.sql";

function columns(table: string, migration: string, names: readonly string[]): ClickHouseExpectedColumn[] {
  return names.map((column) => ({ table, column, migration }));
}

export const CLICKHOUSE_EXPECTED_COLUMNS: readonly ClickHouseExpectedColumn[] = [
  ...columns("usage_events", CREATE_001, [
    "event_time", "team_id", "stack_user_id", "vm_id", "provider", "upstream_kind",
    "agent", "model", "input_tokens", "cached_input_tokens", "output_tokens",
    "total_tokens", "api_equivalent_usd", "priced", "rate_card_version",
    "request_id", "status",
  ]),
  ...columns("route_events", CREATE_001, [
    "event_time", "team_id", "vm_id", "provider", "agent", "outcome",
    "failure_stage", "status", "attempt_count", "refresh_retry_count",
    "duration_ms", "response_streamed", "request_id",
  ]),
  ...columns("usage_events", "002_coderouter_upstream_account.sql", ["upstream_account_id"]),
  ...columns("route_events", "002_coderouter_upstream_account.sql", ["upstream_account_id"]),
  ...columns("route_events", "003_route_events_stack_user.sql", ["stack_user_id"]),
  ...columns("usage_events", "004_usage_events_origin.sql", ["workspace_id", "surface_id"]),
  ...columns("usage_events", "005_usage_events_api_key.sql", ["api_key_id"]),
  ...columns("route_events", "005_usage_events_api_key.sql", ["api_key_id"]),
  ...columns("route_events", "006_route_events_capacity_hold.sql", ["held_ms", "hold_count"]),
];

export type ClickHouseSchemaCheck =
  | { readonly kind: "disabled" }
  | { readonly kind: "unavailable"; readonly reason: string }
  | { readonly kind: "ok" }
  | {
    readonly kind: "drift";
    /** `table.column`, sorted. */
    readonly missingColumns: readonly string[];
    /** Migration file names that were not (fully) applied, sorted. */
    readonly migrations: readonly string[];
  };

const SCHEMA_SQL = `SELECT table, name
FROM system.columns
WHERE database = {database:String}
  AND table IN ({tables:Array(String)})`;

/** A successful answer is reused for this long, so the 5-minute cron costs one query per instance per window. */
export const CLICKHOUSE_SCHEMA_CACHE_MS = 30 * 60 * 1_000;

type CacheEntry = { readonly at: number; readonly result: ClickHouseSchemaCheck };
let cache: CacheEntry | null = null;

export type ClickHouseSchemaCheckDependencies = {
  readonly clickhouse?: ClickHouseDependencies;
  readonly now?: () => number;
  readonly expected?: readonly ClickHouseExpectedColumn[];
};

export async function checkClickHouseSchema(
  dependencies: ClickHouseSchemaCheckDependencies = {},
): Promise<ClickHouseSchemaCheck> {
  const now = (dependencies.now ?? Date.now)();
  if (cache && now - cache.at < CLICKHOUSE_SCHEMA_CACHE_MS) return cache.result;
  const clickhouse = dependencies.clickhouse ?? defaultClickHouseDependencies;
  const config = clickhouse.config();
  if (!config) return { kind: "disabled" };
  const expected = dependencies.expected ?? CLICKHOUSE_EXPECTED_COLUMNS;
  const tables = [...new Set(expected.map((entry) => entry.table))].sort();
  const result = await query<{ table?: unknown; name?: unknown }>(
    SCHEMA_SQL,
    // ClickHouse parses Array(String) parameters from their SQL literal form.
    { database: config.database, tables: `[${tables.map((table) => `'${table}'`).join(",")}]` },
    clickhouse,
  );
  if (!result.ok) {
    // Unavailability is the ledger-unreachable alert's job; do not cache it.
    return { kind: "unavailable", reason: result.reason === "status" ? `http_${result.status}` : result.reason };
  }
  const present = new Set<string>();
  for (const row of result.rows) {
    if (typeof row.table === "string" && typeof row.name === "string") present.add(`${row.table}.${row.name}`);
  }
  const missing = expected.filter((entry) => !present.has(`${entry.table}.${entry.column}`));
  const check: ClickHouseSchemaCheck = missing.length === 0
    ? { kind: "ok" }
    : {
      kind: "drift",
      missingColumns: missing.map((entry) => `${entry.table}.${entry.column}`).sort(),
      migrations: [...new Set(missing.map((entry) => entry.migration))].sort(),
    };
  cache = { at: now, result: check };
  return check;
}

export function resetClickHouseSchemaCacheForTests(): void {
  cache = null;
}
