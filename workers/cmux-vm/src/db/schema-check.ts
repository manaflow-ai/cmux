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
 * Every migration adds its tables and columns to schema-requirements.ts, and is
 * applied on staging BEFORE the push that needs it: the deploy ordering gate
 * (scripts/cmux-next/release/db-release.ts gate) runs the same check before a
 * deploy and refuses it (plans/cmux-next/release-rails.md).
 */
import { Effect, Schema } from "effect";
import { REQUIRED_SCHEMA, SCHEMA_CHECK_SQL, schemaCheckParams } from "./schema-requirements.ts";
import { SqlClient, StoreError } from "./sql.ts";

export { REQUIRED_SCHEMA } from "./schema-requirements.ts";

/** Every missing table, column or privilege, as `<table>[.<column>]: missing` or `<table>: no <PRIVILEGE> privilege`; empty when all is there. */
export const checkSchema: Effect.Effect<ReadonlyArray<string>, StoreError, SqlClient> = Effect.gen(function* () {
  const sql = yield* SqlClient;
  const rows = yield* sql.query("schema.check", SCHEMA_CHECK_SQL, schemaCheckParams(REQUIRED_SCHEMA));
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
