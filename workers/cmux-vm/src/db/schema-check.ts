/**
 * The schema gate (cx-0op.6): a deploy must never run ahead of its migration.
 *
 * `checkSchema` lists what this build needs from schema `cmux_vm` and the
 * database lacks: tables, columns added by later migrations, and the
 * privileges of tables whose absence would fail a request instead of degrading
 * it. One cheap catalog query. `makeSchemaGate` runs it on an isolate's first
 * request: while anything is missing (or the check fails) every route except
 * /healthz answers 503 and the Worker logs one "schema not applied" line naming
 * what is missing, so the staging smoke test fails at once; after the first
 * clean check the isolate stops checking.
 *
 * Every migration adds its tables and columns here, and is applied on staging
 * BEFORE the push that needs it (DESIGN.md, Operations).
 */
import { Effect, Schema } from "effect";
import { SqlClient, StoreError } from "./sql.ts";

type Privilege = "SELECT" | "INSERT" | "UPDATE" | "DELETE";

interface Requirement {
  readonly table: string;
  readonly column?: string;
  readonly privileges?: ReadonlyArray<Privilege>;
  /** The migration that adds it, for the log. */
  readonly migration: string;
}

/** What this build needs. */
export const REQUIRED_SCHEMA: ReadonlyArray<Requirement> = [
  { table: "cmux_vm.resources", migration: "0001" },
  { table: "cmux_vm.api_keys", migration: "0001" },
  { table: "cmux_vm.resources", column: "display_name", migration: "0002" },
  { table: "cmux_vm.resources", column: "labels", migration: "0002" },
  { table: "cmux_vm.audit_log", migration: "0002" },
  { table: "cmux_vm.resources", column: "parent_cmux_id", migration: "0003" },
  { table: "cmux_vm.mesh_cidrs", migration: "0004" },
  { table: "cmux_vm.mesh_devices", migration: "0004" },
  { table: "cmux_vm.mesh_members", migration: "0004" },
  { table: "cmux_vm.mesh_acl_versions", migration: "0004" },
  { table: "cmux_vm.mesh_firewall_rules", migration: "0004" },
  { table: "cmux_vm.mesh_devices", column: "install_public_key", migration: "0005" },
  { table: "cmux_vm.mesh_devices", column: "key_rotated_at", migration: "0005" },
  { table: "cmux_vm.mesh_signed_requests", migration: "0005" },
  { table: "cmux_vm.mesh_enrollment_codes", migration: "0005" },
  { table: "cmux_vm.audit_log", column: "owner_actor", migration: "0007" },
  { table: "cmux_vm.stack_memberships", migration: "0007" },
  { table: "cmux_vm.stack_webhook_deliveries", migration: "0007" },
  // Without these privileges every Stack webhook answers 503 (first receipt time, G1 retries).
  { table: "cmux_vm.stack_webhook_events", privileges: ["SELECT", "INSERT", "UPDATE"], migration: "0008" },
  // A device's published public IPv6 address (address rules, bead cx-wb5.45).
  { table: "cmux_vm.mesh_devices", column: "public_ipv6", migration: "0009" },
];

/** A Postgres text[] literal of identifiers (letters, digits, '_' and '.' only, so quoting needs no escapes). */
const pgArray = (values: ReadonlyArray<string>) => `{${values.map((value) => `"${value}"`).join(",")}}`;

/** Every missing table, column or privilege, as `<table>[.<column>]: missing` or `<table>: no <PRIVILEGE> privilege`; empty when all is there. */
export const checkSchema: Effect.Effect<ReadonlyArray<string>, StoreError, SqlClient> = Effect.gen(function* () {
  const sql = yield* SqlClient;
  const tables: string[] = [];
  const columns: string[] = [];
  const privileges: string[] = [];
  for (const requirement of REQUIRED_SCHEMA) {
    for (const privilege of requirement.privileges ?? [null]) {
      tables.push(requirement.table);
      columns.push(requirement.column ?? "");
      privileges.push(privilege ?? "");
    }
  }
  // pg_catalog, not information_schema: a column is found even when the role has no privilege on it.
  const rows = yield* sql.query(
    "schema.check",
    `SELECT CASE
              WHEN to_regclass(r.t) IS NULL THEN r.t || ': missing'
              WHEN r.c <> '' AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = to_regclass(r.t) AND a.attname = r.c AND a.attnum > 0 AND NOT a.attisdropped
              ) THEN r.t || '.' || r.c || ': missing'
              WHEN r.p <> '' AND NOT has_table_privilege(to_regclass(r.t), r.p) THEN r.t || ': no ' || r.p || ' privilege'
            END AS problem
       FROM unnest($1::text[], $2::text[], $3::text[]) WITH ORDINALITY AS r(t, c, p, n)
      ORDER BY r.n`,
    [pgArray(tables), pgArray(columns), pgArray(privileges)],
  );
  const decoded = yield* Schema.decodeUnknown(Schema.Array(Schema.Struct({ problem: Schema.NullOr(Schema.String) })))(rows).pipe(
    Effect.mapError((cause) => new StoreError({ operation: "schema.check", cause })),
  );
  const problems = decoded.flatMap((row) => (row.problem === null ? [] : [row.problem]));
  return [...new Set(problems)];
});

const LOG = (line: string) => console.error(line);

/**
 * Wraps `handler`: until `check` once answers an empty list, every request
 * except GET /healthz answers 503 "schema not applied" (or "schema check
 * failed" when the check itself fails) and logs one line with what is missing.
 */
export const makeSchemaGate = (
  check: () => Promise<ReadonlyArray<string>>,
  handler: (request: Request) => Promise<Response>,
  log: (line: string) => void = LOG,
): ((request: Request) => Promise<Response>) => {
  let ready = false;
  const refuse = (message: string) => Response.json({ _tag: "ServiceUnavailable", message }, { status: 503 });
  return async (request) => {
    if (ready || new URL(request.url).pathname === "/healthz") return handler(request);
    let problems: ReadonlyArray<string>;
    try {
      problems = await check();
    } catch (error) {
      const code = error instanceof StoreError ? error.operation : "check";
      log(JSON.stringify({ event: "cmux_vm_schema_check_failed", message: "cmux-vm schema check failed; answering 503", where: code }));
      return refuse("Database schema check failed; retry");
    }
    if (problems.length > 0) {
      log(JSON.stringify({ event: "cmux_vm_schema_not_applied", message: "cmux-vm schema not applied; answering 503 until the migration is applied", missing: problems }));
      return refuse("Database schema not applied; retry");
    }
    ready = true;
    return handler(request);
  };
};
