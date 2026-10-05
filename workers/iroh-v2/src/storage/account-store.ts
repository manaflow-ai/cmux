import { sql } from "drizzle-orm";
import { drizzle } from "drizzle-orm/durable-sqlite";
import { DeviceRecordSchema, type DeviceRecord, type Identity } from "../contracts/common";
import { ACCOUNT_MAC_LIMIT } from "../contracts/account";
import { OperationError } from "../errors";
import { DEVICE_PROOF_WINDOW_SECONDS } from "./team-store";

/**
 * SQLite owned by one AccountControl object, which is one Stack user in one
 * environment and project. It shares no table with TeamControl storage; team
 * schema versions, migrations and audit history are untouched by this store.
 */
const ACCOUNT_SCHEMA_VERSION = 1;
const PROOF_RING_LIMIT = 256;
const BUCKET_CAPACITY = 120;
const BUCKET_REFILL_PER_MS = 300 / 60_000;

const statements = [
  `CREATE TABLE IF NOT EXISTS "account_meta" ("id" INTEGER PRIMARY KEY NOT NULL CHECK ("id" = 1), "revision" INTEGER NOT NULL DEFAULT 0 CHECK ("revision" >= 0), "schema_version" INTEGER NOT NULL CHECK ("schema_version" >= 1), "tokens" REAL NOT NULL CHECK ("tokens" >= 0), "refilled_at" INTEGER NOT NULL)`,
  `INSERT OR IGNORE INTO "account_meta" ("id", "revision", "schema_version", "tokens", "refilled_at") VALUES (1, 0, ${ACCOUNT_SCHEMA_VERSION}, ${BUCKET_CAPACITY}, 0)`,
  `CREATE TABLE IF NOT EXISTS "account_macs" ("installation_key" TEXT PRIMARY KEY NOT NULL, "team_id" TEXT NOT NULL, "identity_key" TEXT NOT NULL, "device_record_id" TEXT NOT NULL, "endpoint_id" TEXT NOT NULL, "device_json" TEXT NOT NULL, "authority_expires_at" INTEGER NOT NULL CHECK ("authority_expires_at" >= 0), "row_version" INTEGER NOT NULL CHECK ("row_version" >= 1), "updated_at" INTEGER NOT NULL, CHECK (length(CAST("installation_key" AS BLOB)) BETWEEN 1 AND 1024), CHECK (length(CAST("device_json" AS BLOB)) <= 65536))`,
  `CREATE INDEX IF NOT EXISTS "account_macs_team_idx" ON "account_macs" ("team_id", "device_record_id")`,
  `CREATE TRIGGER IF NOT EXISTS "account_macs_limit_guard" BEFORE INSERT ON "account_macs" WHEN (SELECT count(*) FROM "account_macs") >= ${ACCOUNT_MAC_LIMIT} AND NOT EXISTS (SELECT 1 FROM "account_macs" WHERE "installation_key" = NEW."installation_key") BEGIN SELECT RAISE(ABORT, 'device_limit'); END`,
  `CREATE TABLE IF NOT EXISTS "account_proof_replays" ("installation_key" TEXT NOT NULL, "request_id" TEXT NOT NULL, "issued_at" INTEGER NOT NULL, "expires_at" INTEGER NOT NULL, PRIMARY KEY ("installation_key", "request_id"))`,
  `CREATE INDEX IF NOT EXISTS "account_proof_replays_expiry_idx" ON "account_proof_replays" ("installation_key", "expires_at")`,
];

/** One Mac installation per user: a team switch replaces the row instead of adding one. */
export function installationKey(identity: Pick<Identity, "deviceId" | "appNamespace" | "buildTag">): string {
  return JSON.stringify([identity.deviceId, identity.appNamespace, identity.buildTag]);
}

export interface AccountMacRow {
  readonly installationKey: string;
  readonly teamId: string;
  readonly identityKey: string;
  readonly device: DeviceRecord;
  readonly authorityExpiresAt: number;
  readonly rowVersion: number;
  readonly updatedAt: number;
}

type Row = {
  installation_key: string; team_id: string; identity_key: string; device_record_id: string; endpoint_id: string;
  device_json: string; authority_expires_at: number; row_version: number; updated_at: number;
};

function fromRow(row: Row): AccountMacRow {
  return {
    installationKey: row.installation_key, teamId: row.team_id, identityKey: row.identity_key,
    device: DeviceRecordSchema.parse(JSON.parse(row.device_json)), authorityExpiresAt: row.authority_expires_at,
    rowVersion: row.row_version, updatedAt: row.updated_at,
  };
}

/** A write decided after awaiting team objects, applied only if the row has not moved since it was read. */
export type AccountRevalidation =
  | { readonly kind: "delete"; readonly installationKey: string; readonly rowVersion: number }
  | { readonly kind: "update"; readonly installationKey: string; readonly rowVersion: number; readonly device: DeviceRecord; readonly authorityExpiresAt: number; readonly visible: boolean };

export class AccountStore {
  readonly #db;
  constructor(readonly storage: DurableObjectStorage, options?: { initialize?: boolean }) {
    this.#db = drizzle(storage);
    if (options?.initialize !== false) this.initialize();
  }

  /** False until the first account request: a team notice for a user with no account rows never creates storage. */
  exists(): boolean {
    return this.#db.get(sql`SELECT 1 AS "found" FROM "sqlite_master" WHERE "type" = 'table' AND "name" = 'account_meta'`) !== undefined;
  }

  initialize(): void {
    this.storage.transactionSync(() => { for (const statement of statements) this.#db.run(sql.raw(statement)); });
  }

  readRevision(): number {
    return this.#db.get<{ revision: number }>(sql`SELECT "revision" FROM "account_meta" WHERE "id" = 1`)?.revision ?? 0;
  }

  /** One token per open, request and socket message; independent of the team UserUsage budgets. */
  consumeToken(nowMs: number): void {
    this.storage.transactionSync(() => {
      const row = this.#db.get<{ tokens: number; refilled_at: number }>(sql`SELECT "tokens", "refilled_at" FROM "account_meta" WHERE "id" = 1`)!;
      const available = Math.min(BUCKET_CAPACITY, row.tokens + Math.max(0, nowMs - row.refilled_at) * BUCKET_REFILL_PER_MS);
      if (available < 1) throw new OperationError("rate_limited", 429, true, Math.max(1, Math.ceil((1 - available) / BUCKET_REFILL_PER_MS)));
      this.#db.run(sql`UPDATE "account_meta" SET "tokens" = ${available - 1}, "refilled_at" = ${nowMs} WHERE "id" = 1`);
    });
  }

  /** Same bounded ring and window as TeamStore.consumeDeviceProof, keyed by installation. */
  consumeProof(key: string, nonce: string, issuedAt: number, now: number): void {
    if (!nonce || Math.abs(now - issuedAt) > DEVICE_PROOF_WINDOW_SECONDS) throw new OperationError("invalid_device_proof", 403);
    this.storage.transactionSync(() => {
      this.#db.run(sql`DELETE FROM "account_proof_replays" WHERE "installation_key" = ${key} AND "expires_at" <= ${now}`);
      if (this.#db.get(sql`SELECT 1 AS "found" FROM "account_proof_replays" WHERE "installation_key" = ${key} AND "request_id" = ${nonce}`)) {
        throw new OperationError("proof_replayed", 409);
      }
      const count = this.#db.get<{ count: number }>(sql`SELECT count(*) AS "count" FROM "account_proof_replays" WHERE "installation_key" = ${key}`)?.count ?? 0;
      if (count >= PROOF_RING_LIMIT) throw new OperationError("rate_limited", 429, true, DEVICE_PROOF_WINDOW_SECONDS * 1000);
      this.#db.run(sql`INSERT INTO "account_proof_replays" ("installation_key", "request_id", "issued_at", "expires_at") VALUES (${key}, ${nonce}, ${issuedAt}, ${issuedAt + DEVICE_PROOF_WINDOW_SECONDS + 1})`);
    });
  }

  list(): AccountMacRow[] {
    return this.#db.all<Row>(sql`SELECT * FROM "account_macs" ORDER BY "installation_key"`).map(fromRow);
  }

  get(key: string): AccountMacRow | null {
    const row = this.#db.get<Row>(sql`SELECT * FROM "account_macs" WHERE "installation_key" = ${key}`);
    return row ? fromRow(row) : null;
  }

  /** Rows for a changed team record, by record id or by installation (a rekeyed record can carry a new id). */
  rowsForTeamDevice(teamId: string, deviceRecordId: string, key: string): AccountMacRow[] {
    return this.#db.all<Row>(sql`SELECT * FROM "account_macs" WHERE "team_id" = ${teamId} AND ("device_record_id" = ${deviceRecordId} OR "installation_key" = ${key})`).map(fromRow);
  }

  /**
   * Inserts or replaces this installation's row. At the cap, rows whose team
   * authority lease has lapsed are evicted oldest first; a live Mac republishes
   * when it reconnects. The revision moves only when the directory changes.
   */
  upsert(input: { installationKey: string; teamId: string; identityKey: string; device: DeviceRecord; authorityExpiresAt: number; now: number }): number {
    const deviceJSON = JSON.stringify(DeviceRecordSchema.parse(input.device));
    return this.storage.transactionSync(() => {
      const existing = this.#db.get<Row>(sql`SELECT * FROM "account_macs" WHERE "installation_key" = ${input.installationKey}`);
      const visibleChange = !existing || existing.team_id !== input.teamId || existing.identity_key !== input.identityKey || existing.device_json !== deviceJSON;
      if (!existing) {
        const count = this.#db.get<{ count: number }>(sql`SELECT count(*) AS "count" FROM "account_macs"`)!.count;
        if (count >= ACCOUNT_MAC_LIMIT) {
          this.#db.run(sql`DELETE FROM "account_macs" WHERE "installation_key" IN (
            SELECT "installation_key" FROM "account_macs" WHERE "authority_expires_at" <= ${input.now}
            ORDER BY "updated_at" ASC, "installation_key" ASC LIMIT ${count - ACCOUNT_MAC_LIMIT + 1})`);
          const remaining = this.#db.get<{ count: number }>(sql`SELECT count(*) AS "count" FROM "account_macs"`)!.count;
          if (remaining >= ACCOUNT_MAC_LIMIT) throw new OperationError("device_limit", 409);
        }
      }
      this.#db.run(sql`INSERT INTO "account_macs" ("installation_key", "team_id", "identity_key", "device_record_id", "endpoint_id", "device_json", "authority_expires_at", "row_version", "updated_at")
        VALUES (${input.installationKey}, ${input.teamId}, ${input.identityKey}, ${input.device.deviceRecordId}, ${input.device.descriptor.endpointId}, ${deviceJSON}, ${input.authorityExpiresAt}, 1, ${input.now})
        ON CONFLICT ("installation_key") DO UPDATE SET "team_id" = excluded."team_id", "identity_key" = excluded."identity_key", "device_record_id" = excluded."device_record_id",
          "endpoint_id" = excluded."endpoint_id", "device_json" = excluded."device_json", "authority_expires_at" = excluded."authority_expires_at",
          "row_version" = "account_macs"."row_version" + 1, "updated_at" = excluded."updated_at"`);
      return visibleChange ? this.bump() : this.readRevision();
    });
  }

  /** Deletes only the caller's own key material; another installation or a rekeyed row is untouched. */
  withdraw(key: string, endpointId: string): { revision: number; changed: boolean } {
    return this.storage.transactionSync(() => {
      const existing = this.#db.get<{ endpoint_id: string }>(sql`SELECT "endpoint_id" FROM "account_macs" WHERE "installation_key" = ${key}`);
      if (!existing || existing.endpoint_id !== endpointId) return { revision: this.readRevision(), changed: false };
      this.#db.run(sql`DELETE FROM "account_macs" WHERE "installation_key" = ${key}`);
      return { revision: this.bump(), changed: true };
    });
  }

  /** Applies team revalidation; a row republished while the team objects were consulted is left alone. */
  revalidate(changes: readonly AccountRevalidation[], now: number): { revision: number; changed: boolean } {
    return this.storage.transactionSync(() => {
      let changed = false;
      for (const change of changes) {
        const current = this.#db.get(sql`SELECT 1 AS "found" FROM "account_macs" WHERE "installation_key" = ${change.installationKey} AND "row_version" = ${change.rowVersion}`);
        if (!current) continue;
        if (change.kind === "delete") {
          this.#db.run(sql`DELETE FROM "account_macs" WHERE "installation_key" = ${change.installationKey}`);
          changed = true;
        } else {
          this.#db.run(sql`UPDATE "account_macs" SET "device_json" = ${JSON.stringify(DeviceRecordSchema.parse(change.device))}, "device_record_id" = ${change.device.deviceRecordId},
            "authority_expires_at" = ${change.authorityExpiresAt}, "row_version" = "row_version" + 1, "updated_at" = ${now}
            WHERE "installation_key" = ${change.installationKey}`);
          changed ||= change.visible;
        }
      }
      return { revision: changed ? this.bump() : this.readRevision(), changed };
    });
  }

  private bump(): number {
    const revision = this.readRevision() + 1;
    this.#db.run(sql`UPDATE "account_meta" SET "revision" = ${revision} WHERE "id" = 1`);
    return revision;
  }
}
