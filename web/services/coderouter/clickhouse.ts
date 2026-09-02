// HTTP client for the coderouter ClickHouse ledger. Plain `fetch` with basic
// auth against the ClickHouse HTTPS interface; no SDK. Inserts are asynchronous
// on the server so a proxied model request never waits on ClickHouse. Reads use
// server-side query parameters (`{name:Type}` placeholders), so user data is
// never interpolated into SQL. The runtime user holds SELECT and INSERT on its
// own database only; DDL runs through scripts/clickhouse-migrate.ts.
import { reportCoderouterFailure } from "./observability";

export type ClickHouseConfig = {
  /** Origin plus optional path prefix, no trailing slash. */
  readonly url: string;
  readonly user: string;
  readonly password: string;
  readonly database: string;
};

export type ClickHouseDependencies = {
  readonly config: () => ClickHouseConfig | null;
  readonly fetch: typeof fetch;
  /** Overridable for tests only; production uses the constants below. */
  readonly timeoutMs?: {
    readonly insert: number;
    readonly query: number;
  };
};

export type ClickHouseFailure =
  | {
      readonly ok: false;
      readonly reason: "disabled" | "request_failed" | "malformed_response";
    }
  | { readonly ok: false; readonly reason: "status"; readonly status: number };

export type ClickHouseInsertResult = { readonly ok: true } | ClickHouseFailure;

export type ClickHouseQueryResult<Row> =
  | { readonly ok: true; readonly rows: readonly Row[] }
  | ClickHouseFailure;

export type ClickHouseParamValue = string | number | boolean;

const INSERT_TIMEOUT_MS = 2_000;
const QUERY_TIMEOUT_MS = 5_000;
const IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

let disabledReported = false;

export const defaultClickHouseDependencies: ClickHouseDependencies = {
  config: clickHouseConfig,
  fetch: (input, init) => fetch(input, init),
};

/**
 * Inserts rows with `INSERT INTO <db>.<table> FORMAT JSONEachRow`. The server
 * buffers the insert (`async_insert=1`) and acknowledges before it lands
 * (`wait_for_async_insert=0`), so the call returns as soon as the request is
 * accepted. A disabled ledger is a silent no-op reported once per process.
 */
export async function insertRows(
  table: string,
  rows: readonly Readonly<Record<string, unknown>>[],
  dependencies: ClickHouseDependencies = defaultClickHouseDependencies,
): Promise<ClickHouseInsertResult> {
  const config = dependencies.config();
  if (!config) {
    reportDisabledOnce();
    return { ok: false, reason: "disabled" };
  }
  if (!IDENTIFIER.test(table)) {
    throw new Error("ClickHouse table name must be a plain identifier");
  }
  if (rows.length === 0) return { ok: true };
  const url = new URL(config.url);
  url.search = new URLSearchParams({
    query: `INSERT INTO ${config.database}.${table} FORMAT JSONEachRow`,
    async_insert: "1",
    wait_for_async_insert: "0",
  }).toString();
  try {
    const response = await dependencies.fetch(url, {
      method: "POST",
      headers: {
        authorization: basicAuth(config),
        "content-type": "application/x-ndjson",
      },
      body: `${rows.map((row) => JSON.stringify(row)).join("\n")}\n`,
      signal: AbortSignal.timeout(
        dependencies.timeoutMs?.insert ?? INSERT_TIMEOUT_MS,
      ),
    });
    // Drain the body inside the try: an unread body that the timeout signal
    // later aborts surfaces as an unhandled rejection in Bun.
    await response.arrayBuffer().catch(() => undefined);
    if (!response.ok) return { ok: false, reason: "status", status: response.status };
    return { ok: true };
  } catch {
    return { ok: false, reason: "request_failed" };
  }
}

/**
 * Runs a SELECT and returns one object per JSONEachRow line. `{db}` in the
 * SQL is replaced with the configured database; every other value must be a
 * `{name:Type}` placeholder bound through `params`. Callers validate row
 * shapes themselves; this function only guarantees parseable JSON objects.
 */
export async function query<Row>(
  sql: string,
  params: Readonly<Record<string, ClickHouseParamValue>>,
  dependencies: ClickHouseDependencies = defaultClickHouseDependencies,
): Promise<ClickHouseQueryResult<Row>> {
  const config = dependencies.config();
  if (!config) {
    reportDisabledOnce();
    return { ok: false, reason: "disabled" };
  }
  const url = new URL(config.url);
  const search = new URLSearchParams({
    default_format: "JSONEachRow",
    // Sums over UInt64 come back as JSON numbers instead of quoted strings.
    output_format_json_quote_64bit_integers: "0",
  });
  for (const [name, value] of Object.entries(params)) {
    if (!IDENTIFIER.test(name)) {
      throw new Error("ClickHouse parameter name must be a plain identifier");
    }
    search.set(`param_${name}`, String(value));
  }
  url.search = search.toString();
  const body = `${sql.replaceAll("{db}", config.database)}\nFORMAT JSONEachRow\n`;
  let text: string;
  try {
    const response = await dependencies.fetch(url, {
      method: "POST",
      headers: {
        authorization: basicAuth(config),
        "content-type": "text/plain; charset=utf-8",
      },
      body,
      signal: AbortSignal.timeout(
        dependencies.timeoutMs?.query ?? QUERY_TIMEOUT_MS,
      ),
    });
    if (!response.ok) return { ok: false, reason: "status", status: response.status };
    text = await response.text();
  } catch {
    return { ok: false, reason: "request_failed" };
  }
  const rows: Row[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      return { ok: false, reason: "malformed_response" };
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { ok: false, reason: "malformed_response" };
    }
    rows.push(parsed as Row);
  }
  return { ok: true, rows };
}

/** Runtime configuration; `null` disables the ledger. Never logged. */
export function clickHouseConfig(): ClickHouseConfig | null {
  const rawUrl = process.env.CLICKHOUSE_URL?.trim();
  const user = process.env.CLICKHOUSE_USER?.trim();
  const password = process.env.CLICKHOUSE_PASSWORD?.trim();
  const database = process.env.CLICKHOUSE_DATABASE?.trim();
  if (!rawUrl || !user || !password || !database) return null;
  if (!IDENTIFIER.test(database)) return null;
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }
  if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
  return {
    url: `${parsed.origin}${parsed.pathname.replace(/\/+$/, "")}`,
    user,
    password,
    database,
  };
}

function basicAuth(config: ClickHouseConfig): string {
  return `Basic ${
    Buffer.from(`${config.user}:${config.password}`, "utf8").toString("base64")
  }`;
}

function reportDisabledOnce(): void {
  if (disabledReported) return;
  disabledReported = true;
  reportCoderouterFailure(
    "usage_ledger",
    new Error("ClickHouse ledger disabled"),
    { reason: "configuration_missing" },
  );
}

export const __test = {
  resetDisabledReport: () => {
    disabledReported = false;
  },
};
