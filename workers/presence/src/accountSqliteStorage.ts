/** Account-owned SQL state. Existing control-plane KV state is separate. */
export const ACCOUNT_STORAGE_QUOTA_BYTES = 8 * 1024 * 1024;
export const ACCOUNT_MAX_BINDINGS = 32;
export const ACCOUNT_MAX_PAYLOAD_BYTES = 64 * 1024;
export const ACCOUNT_MAX_RECORDS = 4096;
export const ACCOUNT_RETENTION_BATCH_SIZE = 128;
/** Physical guard leaves room for SQLite indexes and migration metadata while
 * staying far below Cloudflare's per-object limit. Cloudflare does not expose
 * a supported VACUUM operation here, so writes fail closed before the file can
 * approach the platform limit; DELETE still makes pages available for reuse. */
export const ACCOUNT_PHYSICAL_STORAGE_QUOTA_BYTES = 16 * 1024 * 1024;
const DAY_MS = 24 * 60 * 60 * 1000;
export const RETENTION_WINDOWS_MS = {
  challenge: 10 * 60 * 1000,
  pairGrant: DAY_MS,
  relayIssuance: DAY_MS,
  revocationTombstone: 30 * DAY_MS,
  inactiveBinding: 30 * DAY_MS,
} as const;

export interface SqliteExecutor {
  exec(query: string, ...bindings: unknown[]): Iterable<unknown>;
  readonly databaseSize?: number;
}
export interface AccountSqliteDatabase {
  readonly sql: SqliteExecutor;
  readonly transactionSync: <T>(callback: () => T) => T;
}
export interface AccountSqliteMigration {
  readonly version: number;
  readonly name: string;
  readonly statements: readonly string[];
}
export class AccountStorageQuotaError extends Error {
  readonly code = "account_storage_quota_exceeded";
  constructor(readonly bytes: number) {
    super(`account SQLite quota exceeded (${bytes} bytes)`);
    this.name = "AccountStorageQuotaError";
  }
}
export class AccountBindingQuotaError extends Error {
  readonly code = "account_binding_quota_exceeded";
  constructor(readonly bindings: number) {
    super(`account binding quota exceeded (${bindings} bindings)`);
    this.name = "AccountBindingQuotaError";
  }
}

// Version 1 has never been deployed to production. Once deployed, freeze both
// these SQL strings and the constants used to construct them. Append version 2.
const payloadColumns = `
  payload TEXT NOT NULL,
  payload_bytes INTEGER GENERATED ALWAYS AS (length(CAST(payload AS BLOB))) STORED
    CHECK (payload_bytes BETWEEN 0 AND 65536)`;
const keyColumn = (name: string) => `${name} TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(${name} AS BLOB)) BETWEEN 1 AND 255)`;
const temporaryTables = [
  ["account_challenges", "challenge_id"],
  ["account_pair_grants", "grant_id"],
  ["account_relay_issuances", "issuance_id"],
] as const;
const dataTables = ["account_bindings", ...temporaryTables.map(([table]) => table), "account_preferences"];

// Triggers make the quota part of every INSERT/UPDATE/DELETE transaction. A
// failed constraint rolls back both the data write and the usage adjustment.
function usageTriggers(table: string): string[] {
  const bindingInsert = table === "account_bindings" ? ", live_bindings = live_bindings + (NEW.revoked_at IS NULL)" : "";
  const bindingDelete = table === "account_bindings" ? ", live_bindings = live_bindings - (OLD.revoked_at IS NULL)" : "";
  const bindingUpdate = table === "account_bindings" ? ", live_bindings = live_bindings + (NEW.revoked_at IS NULL) - (OLD.revoked_at IS NULL)" : "";
  return [
    `CREATE TRIGGER ${table}_usage_insert AFTER INSERT ON ${table} BEGIN
      UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes,
        records = records + 1 ${bindingInsert} WHERE id = 1; END`,
    `CREATE TRIGGER ${table}_usage_delete AFTER DELETE ON ${table} BEGIN
      UPDATE account_storage_usage SET payload_bytes = payload_bytes - OLD.payload_bytes,
        records = records - 1 ${bindingDelete} WHERE id = 1; END`,
    `CREATE TRIGGER ${table}_usage_update AFTER UPDATE ON ${table} BEGIN
      UPDATE account_storage_usage SET payload_bytes = payload_bytes + NEW.payload_bytes - OLD.payload_bytes
        ${bindingUpdate} WHERE id = 1; END`,
  ];
}

/** Append-only after production deployment. The ledger stores exact SQL, so a
 * later edit to an applied definition is rejected even if its name is intact. */
export const ACCOUNT_SQLITE_MIGRATIONS: readonly AccountSqliteMigration[] = [{
  version: 1,
  name: "account_state_tables",
  statements: [
    `CREATE TABLE account_storage_usage (
      id INTEGER PRIMARY KEY CHECK(id = 1),
      payload_bytes INTEGER NOT NULL CHECK(payload_bytes BETWEEN 0 AND 8388608),
      records INTEGER NOT NULL CHECK(records BETWEEN 0 AND 4096),
      live_bindings INTEGER NOT NULL CHECK(live_bindings BETWEEN 0 AND 32)
    )`,
    "INSERT INTO account_storage_usage VALUES (1, 0, 0, 0)",
    `CREATE TABLE account_bindings (
      ${keyColumn("binding_id")},
      endpoint_id TEXT NOT NULL CHECK(length(endpoint_id) = 64),
      device_id TEXT NOT NULL CHECK(length(device_id) BETWEEN 1 AND 255),
      client_namespace TEXT NOT NULL CHECK(length(client_namespace) BETWEEN 1 AND 255),
      platform TEXT NOT NULL CHECK(platform IN ('mac', 'ios')),
      ${payloadColumns},
      last_seen_at INTEGER NOT NULL CHECK(last_seen_at >= 0),
      registered_at INTEGER NOT NULL CHECK(registered_at >= 0),
      revoked_at INTEGER,
      tombstone_expires_at INTEGER,
      CHECK ((revoked_at IS NULL AND tombstone_expires_at IS NULL) OR
        (revoked_at IS NOT NULL AND revoked_at >= 0 AND tombstone_expires_at IS NOT NULL
          AND tombstone_expires_at >= revoked_at + 2592000000))
    )`,
    "CREATE UNIQUE INDEX account_bindings_endpoint_live ON account_bindings(endpoint_id) WHERE revoked_at IS NULL",
    "CREATE INDEX account_bindings_live_expiry ON account_bindings(last_seen_at) WHERE revoked_at IS NULL",
    "CREATE INDEX account_bindings_revoked_expiry ON account_bindings(tombstone_expires_at) WHERE revoked_at IS NOT NULL",
    ...temporaryTables.flatMap(([table, key]) => [
      `CREATE TABLE ${table} (${keyColumn(key)}, ${payloadColumns}, expires_at INTEGER NOT NULL CHECK(expires_at >= 0))`,
      `CREATE INDEX ${table}_expiry ON ${table}(expires_at)`,
    ]),
    `CREATE TABLE account_preferences (
      preference_key TEXT PRIMARY KEY NOT NULL CHECK(preference_key = 'relay'),
      ${payloadColumns}, updated_at INTEGER NOT NULL CHECK(updated_at >= 0)
    )`,
    `CREATE TABLE account_meta (
      key TEXT PRIMARY KEY NOT NULL CHECK(key IN ('route_revision', 'lan_generation', 'revocation_epoch')),
      value TEXT NOT NULL CHECK(length(CAST(value AS BLOB)) <= 128)
    )`,
    ...dataTables.flatMap(usageTriggers),
  ],
}];

export function runAccountSqliteMigrations(
  database: AccountSqliteDatabase,
  nowMs: number,
  migrations: readonly AccountSqliteMigration[] = ACCOUNT_SQLITE_MIGRATIONS,
): void {
  expiredBefore(nowMs);
  if (typeof database.transactionSync !== "function") throw new Error("account migrations require a synchronous transaction");
  if (migrations.length === 0 || migrations.length > 128) throw new Error("invalid account migration count");
  for (const [index, migration] of migrations.entries()) {
    if (migration.version !== index + 1 || !/^[a-z][a-z0-9_]{0,127}$/.test(migration.name)
      || migration.statements.length === 0 || migration.statements.length > 128
      || new TextEncoder().encode(JSON.stringify(migration.statements)).length > 65_536) {
      throw new Error("invalid account migration sequence or definition");
    }
  }
  database.transactionSync(() => {
    const { sql } = database;
    sql.exec(`CREATE TABLE IF NOT EXISTS account_schema_migrations (
      version INTEGER PRIMARY KEY CHECK(version BETWEEN 1 AND 128), name TEXT NOT NULL,
      definition TEXT NOT NULL CHECK(length(CAST(definition AS BLOB)) <= 65536),
      applied_at INTEGER NOT NULL)`);
    const applied = [...sql.exec("SELECT version, name, definition FROM account_schema_migrations ORDER BY version")];
    for (const [index, raw] of applied.entries()) {
      const row = raw as { version?: unknown; name?: unknown; definition?: unknown } | null;
      const expected = migrations[index];
      if (!row || row.version !== index + 1 || !expected || row.version !== expected.version
        || row.name !== expected.name || row.definition !== JSON.stringify(expected.statements)) {
        throw new Error("account schema is newer, incomplete, or has a changed migration definition");
      }
    }
    for (const migration of migrations.slice(applied.length)) {
      for (const statement of migration.statements) sql.exec(statement);
      sql.exec("INSERT INTO account_schema_migrations (version, name, definition, applied_at) VALUES (?, ?, ?, ?)",
        migration.version, migration.name, JSON.stringify(migration.statements), nowMs);
    }
  });
}

export function expiredBefore(nowMs: number): number {
  if (!Number.isSafeInteger(nowMs) || nowMs < 0 || nowMs > Number.MAX_SAFE_INTEGER - 30 * DAY_MS) {
    throw new RangeError("nowMs is outside the supported timestamp range");
  }
  return nowMs;
}
export function retentionAlarmAt(nowMs: number): number { return expiredBefore(nowMs) + DAY_MS; }
export function isPayloadWithinQuota(bytes: number): boolean {
  return Number.isSafeInteger(bytes) && bytes >= 0 && bytes <= ACCOUNT_MAX_PAYLOAD_BYTES;
}
function scalarNumber(sql: SqliteExecutor, query: string): number {
  const rows = [...sql.exec(query)];
  const value = (rows[0] as { value?: unknown } | null)?.value;
  if (rows.length !== 1 || typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new Error("account SQLite aggregate returned an unusable value");
  }
  return value;
}

/** At most 128 deleted rows across all tables per pass. Expired rows beyond the
 * batch remain due, causing another alarm. Unexpired tokens are never deleted. */
export function pruneExpiredAccountState(sql: SqliteExecutor, nowMs: number): number {
  const now = expiredBefore(nowMs);
  const sources: readonly (readonly [string, string, string, number])[] = [
    ...temporaryTables.map(([table, key]) => [table, key, "expires_at <= ?", now] as const),
    ["account_bindings", "binding_id", "revoked_at IS NOT NULL AND tombstone_expires_at <= ?", now],
    ["account_bindings", "binding_id", "revoked_at IS NULL AND last_seen_at <= ?", now - RETENTION_WINDOWS_MS.inactiveBinding],
  ];
  let remaining = ACCOUNT_RETENTION_BATCH_SIZE;
  for (const [table, key, predicate, cutoff] of sources) {
    if (remaining === 0) break;
    const removed = [...sql.exec(
      `DELETE FROM ${table} WHERE ${key} IN (SELECT ${key} FROM ${table} WHERE ${predicate} LIMIT ?) RETURNING ${key}`,
      cutoff, remaining,
    )].length;
    remaining -= removed;
  }
  return ACCOUNT_RETENTION_BATCH_SIZE - remaining;
}

/** No daily wake for an empty account. Schedule the earliest retained expiry,
 * cap distant deadlines at one day, and avoid a tight loop while draining a
 * backlog. Input columns are bounded and every MIN uses its expiry index. */
export function nextAccountRetentionAt(sql: SqliteExecutor, nowMs: number): number | null {
  const now = expiredBefore(nowMs);
  const rows = [...sql.exec(`SELECT MIN(deadline) AS deadline FROM (
    SELECT MIN(expires_at) AS deadline FROM account_challenges
    UNION ALL SELECT MIN(expires_at) FROM account_pair_grants
    UNION ALL SELECT MIN(expires_at) FROM account_relay_issuances
    UNION ALL SELECT MIN(tombstone_expires_at) FROM account_bindings WHERE revoked_at IS NOT NULL
    UNION ALL SELECT MIN(last_seen_at) + 2592000000 FROM account_bindings WHERE revoked_at IS NULL
  )`)];
  const deadline = (rows[0] as { deadline?: unknown } | null)?.deadline;
  if (rows.length !== 1 || (deadline !== null && (typeof deadline !== "number" || !Number.isSafeInteger(deadline)))) {
    throw new Error("invalid account retention deadline");
  }
  return deadline === null ? null : Math.max(now + 1000, Math.min(retentionAlarmAt(now), deadline as number));
}

export function accountPayloadBytes(sql: SqliteExecutor): number {
  return scalarNumber(sql, "SELECT payload_bytes AS value FROM account_storage_usage WHERE id = 1");
}
export function assertAccountStorageQuota(sql: SqliteExecutor): void {
  const bytes = accountPayloadBytes(sql);
  if (bytes > ACCOUNT_STORAGE_QUOTA_BYTES) throw new AccountStorageQuotaError(bytes);
  if (sql.databaseSize !== undefined
    && (!Number.isSafeInteger(sql.databaseSize) || sql.databaseSize > ACCOUNT_PHYSICAL_STORAGE_QUOTA_BYTES)) {
    throw new AccountStorageQuotaError(sql.databaseSize);
  }
}
export function assertBindingQuota(sql: SqliteExecutor): void {
  const bindings = scalarNumber(sql, "SELECT live_bindings AS value FROM account_storage_usage WHERE id = 1");
  if (bindings >= ACCOUNT_MAX_BINDINGS) throw new AccountBindingQuotaError(bindings);
}
