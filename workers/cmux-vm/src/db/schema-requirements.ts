/**
 * What this build needs from schema `cmux_vm`, as plain data and one catalog
 * query. No imports: the Worker's schema gate (schema-check.ts) and the release
 * tooling (scripts/cmux-next/release: the deploy ordering gate and the
 * migration rehearsal) run the same check, so a deploy is refused before it
 * ships instead of answering 503 after it ships.
 *
 * Every migration adds its tables, columns and needed privileges here.
 */

export type Privilege = "SELECT" | "INSERT" | "UPDATE" | "DELETE";

export interface Requirement {
  readonly table: string;
  readonly column?: string;
  readonly privileges?: ReadonlyArray<Privilege>;
  /** The migration that adds it (four digits). */
  readonly migration: string;
}

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
];

/** The highest migration this build's requirements name. */
export const requiredMigration = (requirements: ReadonlyArray<Requirement> = REQUIRED_SCHEMA): string =>
  requirements.reduce((max, requirement) => (requirement.migration > max ? requirement.migration : max), "0000");

/** A Postgres text[] literal of identifiers (letters, digits, '_' and '.' only, so quoting needs no escapes). */
const pgArray = (values: ReadonlyArray<string>) => `{${values.map((value) => `"${value}"`).join(",")}}`;

/**
 * One row per requirement: `problem` is null when it is met, else
 * `<table>: missing`, `<table>.<column>: missing` or `<table>: no <PRIVILEGE> privilege`.
 * Parameters: $1 tables, $2 columns, $3 privileges (text[] literals), $4 the role
 * whose privileges count ('' = the current role).
 * pg_catalog, not information_schema: a column is found even when the role has no privilege on it.
 */
export const SCHEMA_CHECK_SQL = `SELECT CASE
              WHEN to_regclass(r.t) IS NULL THEN r.t || ': missing'
              WHEN r.c <> '' AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = to_regclass(r.t) AND a.attname = r.c AND a.attnum > 0 AND NOT a.attisdropped
              ) THEN r.t || '.' || r.c || ': missing'
              WHEN r.p <> '' AND NOT (CASE WHEN $4::text = '' THEN has_table_privilege(to_regclass(r.t), r.p)
                                           ELSE has_table_privilege($4::text, to_regclass(r.t), r.p) END)
                THEN r.t || ': no ' || r.p || ' privilege'
            END AS problem
       FROM unnest($1::text[], $2::text[], $3::text[]) WITH ORDINALITY AS r(t, c, p, n)
      ORDER BY r.n`;

/** The parameters of SCHEMA_CHECK_SQL for `requirements`, checked for `role` ('' = the current role). */
export const schemaCheckParams = (requirements: ReadonlyArray<Requirement> = REQUIRED_SCHEMA, role = ""): [string, string, string, string] => {
  const tables: string[] = [];
  const columns: string[] = [];
  const privileges: string[] = [];
  for (const requirement of requirements) {
    for (const privilege of requirement.privileges ?? [null]) {
      tables.push(requirement.table);
      columns.push(requirement.column ?? "");
      privileges.push(privilege ?? "");
    }
  }
  return [pgArray(tables), pgArray(columns), pgArray(privileges), role];
};
