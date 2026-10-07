/**
 * The schema gate (cx-0op.6): a deploy must never run ahead of its migration.
 * The check lists every table, column and privilege this build needs that the
 * database lacks; the gate answers 503 ("schema not applied", one log line
 * naming what is missing) for every route but /healthz until the list is
 * empty, then stops checking.
 */
import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { describe, expect, it } from "vitest";
import ownership from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import s2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import snapshots from "../../migrations/0003_cmux_vm_snapshot_parent.sql?raw";
import mesh from "../../migrations/0004_cmux_vm_mesh.sql?raw";
import meshM2 from "../../migrations/0005_cmux_vm_mesh_m2.sql?raw";
import meshM3 from "../../migrations/0006_cmux_vm_mesh_m3.sql?raw";
import meshM4 from "../../migrations/0007_cmux_vm_mesh_m4.sql?raw";
import meshM4Retries from "../../migrations/0008_cmux_vm_mesh_m4_retries.sql?raw";
import { checkSchema, makeSchemaGate } from "../../src/db/schema-check.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";

const ALL = [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries];

const problemsOn = async (migrations: ReadonlyArray<string>) => {
  const db = new PGlite();
  for (const migration of migrations) await db.exec(migration);
  const sql = Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
  });
  return Effect.runPromise(Effect.provide(checkSchema, sql));
};

describe("checkSchema", () => {
  it("finds nothing missing on a database with every migration", async () => {
    expect(await problemsOn(ALL)).toEqual([]);
  });

  it("names the table of a migration that was not applied (0008)", async () => {
    expect(await problemsOn(ALL.slice(0, 7))).toEqual(["cmux_vm.stack_webhook_events: missing"]);
  });

  it("names added columns and tables of older missing migrations (0007 and 0008)", async () => {
    const problems = await problemsOn(ALL.slice(0, 6));
    expect(problems).toContain("cmux_vm.audit_log.owner_actor: missing");
    expect(problems).toContain("cmux_vm.stack_memberships: missing");
    expect(problems).toContain("cmux_vm.stack_webhook_deliveries: missing");
    expect(problems).toContain("cmux_vm.stack_webhook_events: missing");
  });

  it("names a privilege the Worker role lacks", async () => {
    const db = new PGlite();
    for (const migration of ALL) await db.exec(migration);
    await db.exec("CREATE ROLE worker_role; GRANT USAGE ON SCHEMA cmux_vm TO worker_role; GRANT SELECT ON ALL TABLES IN SCHEMA cmux_vm TO worker_role; SET ROLE worker_role;");
    const sql = Layer.succeed(SqlClient, {
      query: (operation, text, params) =>
        Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
    });
    const problems = await Effect.runPromise(Effect.provide(checkSchema, sql));
    expect(problems).toContain("cmux_vm.stack_webhook_events: no INSERT privilege");
    expect(problems).toContain("cmux_vm.stack_webhook_events: no UPDATE privilege");
  });
});

describe("makeSchemaGate", () => {
  const ok = () => Promise.resolve(new Response("ok"));

  it("answers 503 'schema not applied' and logs what is missing, but lets /healthz through", async () => {
    const lines: string[] = [];
    const gate = makeSchemaGate(async () => ["cmux_vm.stack_webhook_events: missing"], ok, (line) => lines.push(line));
    const refused = await gate(new Request("https://vm.test/v1/vms"));
    expect(refused.status).toBe(503);
    expect(JSON.stringify(await refused.json())).toMatch(/schema not applied/iu);
    expect(lines.some((line) => /schema not applied/iu.test(line) && line.includes("cmux_vm.stack_webhook_events: missing"))).toBe(true);
    expect((await gate(new Request("https://vm.test/healthz"))).status).toBe(200);
  });

  it("checks again until the schema is there, then stops checking", async () => {
    let calls = 0;
    let missing = ["cmux_vm.stack_webhook_events: missing"];
    const gate = makeSchemaGate(
      async () => {
        calls += 1;
        return missing;
      },
      ok,
      () => {},
    );
    expect((await gate(new Request("https://vm.test/v1/webhooks/stack", { method: "POST" }))).status).toBe(503);
    missing = [];
    expect((await gate(new Request("https://vm.test/v1/vms"))).status).toBe(200);
    expect((await gate(new Request("https://vm.test/v1/vms"))).status).toBe(200);
    expect(calls).toBe(2);
  });

  it("answers 503 when the check itself fails (database unreachable) and logs it", async () => {
    const lines: string[] = [];
    const gate = makeSchemaGate(() => Promise.reject(new Error("connect timeout")), ok, (line) => lines.push(line));
    expect((await gate(new Request("https://vm.test/v1/vms"))).status).toBe(503);
    expect(lines.some((line) => /schema check failed/iu.test(line))).toBe(true);
  });
});
