import clientSessionIndex from "../../migrations/0017_cmux_vm_client_session_index.sql?raw";
import agentKeys from "../../migrations/0016_cmux_vm_agent_keys.sql?raw";
import overlayServerCodes from "../../migrations/0015_cmux_vm_overlay_server_codes.sql?raw";
import overlayServers from "../../migrations/0014_cmux_vm_overlay_servers.sql?raw";
import overlayPolicy from "../../migrations/0013_cmux_vm_device_overlay_policy.sql?raw";
import creationReceiptIndex from "../../migrations/0011_cmux_vm_creation_receipt_index.sql?raw";
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
import creationReceipts from "../../migrations/0010_cmux_vm_creation_receipts.sql?raw";
import deviceAddress from "../../migrations/0009_cmux_vm_mesh_device_address.sql?raw";
import uncommittedCreations from "../../migrations/0012_cmux_vm_uncommitted_creations.sql?raw";
import { checkSchema, makeSchemaGate } from "../../src/db/schema-check.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";

const ALL = [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries, deviceAddress, creationReceipts, creationReceiptIndex, uncommittedCreations, overlayPolicy, overlayServers, overlayServerCodes, agentKeys, clientSessionIndex];

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

  it("requires the widened replay constraint before enabling overlay-policy reads", async () => {
    expect(await problemsOn(ALL.slice(0, 12))).toEqual(["cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing", "cmux_vm.mesh_overlay_servers: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v3_check: missing", "cmux_vm.mesh_overlay_server_codes: missing", "cmux_vm.api_keys.agent_labels: missing", "cmux_vm.api_keys.agent_max_vms: missing", "cmux_vm.api_keys.agent_max_usd_per_hour: missing", "cmux_vm.api_keys.agent_cleaned_at: missing", "cmux_vm.vm_client_sessions: missing", "cmux_vm.vm_client_sessions_vm_idx: missing"]);
    const db = new PGlite();
    for (const migration of ALL) await db.exec(migration);
    await db.exec("ALTER TABLE cmux_vm.mesh_signed_requests DROP CONSTRAINT mesh_signed_requests_purpose_v2_check; ALTER TABLE cmux_vm.mesh_signed_requests ADD CONSTRAINT mesh_signed_requests_purpose_v2_check CHECK (purpose IN ('enroll', 'rotate-key', 'peers', 'tunnel', 'address', 'overlay-policy')) NOT VALID;");
    const sql = Layer.succeed(SqlClient, { query: (operation, text, params) => Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }) });
    expect(await Effect.runPromise(Effect.provide(checkSchema, sql))).toEqual(["cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing"]);
  });

  it("names the table of a migration that was not applied (0008)", async () => {
    expect(await problemsOn(ALL.slice(0, 7))).toEqual(["cmux_vm.resources.creation_key: missing", "cmux_vm.resources.creation_receipt: missing", "cmux_vm.resources_creation_key_idx: missing", "cmux_vm.resources.committed: missing", "cmux_vm.stack_webhook_events: missing", "cmux_vm.mesh_devices.public_ipv6: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing", "cmux_vm.mesh_overlay_servers: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v3_check: missing", "cmux_vm.mesh_overlay_server_codes: missing", "cmux_vm.api_keys.agent_labels: missing", "cmux_vm.api_keys.agent_max_vms: missing", "cmux_vm.api_keys.agent_max_usd_per_hour: missing", "cmux_vm.api_keys.agent_cleaned_at: missing", "cmux_vm.vm_client_sessions: missing", "cmux_vm.vm_client_sessions_vm_idx: missing"]);
  });

  it("names the column of 0009 when only it was not applied", async () => {
    expect(await problemsOn(ALL.slice(0, 8))).toEqual(["cmux_vm.resources.creation_key: missing", "cmux_vm.resources.creation_receipt: missing", "cmux_vm.resources_creation_key_idx: missing", "cmux_vm.resources.committed: missing", "cmux_vm.mesh_devices.public_ipv6: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing", "cmux_vm.mesh_overlay_servers: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v3_check: missing", "cmux_vm.mesh_overlay_server_codes: missing", "cmux_vm.api_keys.agent_labels: missing", "cmux_vm.api_keys.agent_max_vms: missing", "cmux_vm.api_keys.agent_max_usd_per_hour: missing", "cmux_vm.api_keys.agent_cleaned_at: missing", "cmux_vm.vm_client_sessions: missing", "cmux_vm.vm_client_sessions_vm_idx: missing"]);
  });

  it("names the receipt columns before creation receipts are applied", async () => {
    expect(await problemsOn(ALL.slice(0, 9))).toEqual(["cmux_vm.resources.creation_key: missing", "cmux_vm.resources.creation_receipt: missing", "cmux_vm.resources_creation_key_idx: missing", "cmux_vm.resources.committed: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing", "cmux_vm.mesh_overlay_servers: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v3_check: missing", "cmux_vm.mesh_overlay_server_codes: missing", "cmux_vm.api_keys.agent_labels: missing", "cmux_vm.api_keys.agent_max_vms: missing", "cmux_vm.api_keys.agent_max_usd_per_hour: missing", "cmux_vm.api_keys.agent_cleaned_at: missing", "cmux_vm.vm_client_sessions: missing", "cmux_vm.vm_client_sessions_vm_idx: missing"]);
  });

  it("requires the concurrent receipt index before enabling this build", async () => {
    expect(await problemsOn(ALL.slice(0, 10))).toEqual(["cmux_vm.resources_creation_key_idx: missing", "cmux_vm.resources.committed: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing", "cmux_vm.mesh_overlay_servers: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v3_check: missing", "cmux_vm.mesh_overlay_server_codes: missing", "cmux_vm.api_keys.agent_labels: missing", "cmux_vm.api_keys.agent_max_vms: missing", "cmux_vm.api_keys.agent_max_usd_per_hour: missing", "cmux_vm.api_keys.agent_cleaned_at: missing", "cmux_vm.vm_client_sessions: missing", "cmux_vm.vm_client_sessions_vm_idx: missing"]);
  });

  it("requires the committed column of uncommitted creations (0012)", async () => {
    expect(await problemsOn(ALL.slice(0, 11))).toEqual(["cmux_vm.resources.committed: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v2_check: missing", "cmux_vm.mesh_overlay_servers: missing", "cmux_vm.mesh_signed_requests.mesh_signed_requests_purpose_v3_check: missing", "cmux_vm.mesh_overlay_server_codes: missing", "cmux_vm.api_keys.agent_labels: missing", "cmux_vm.api_keys.agent_max_vms: missing", "cmux_vm.api_keys.agent_max_usd_per_hour: missing", "cmux_vm.api_keys.agent_cleaned_at: missing", "cmux_vm.vm_client_sessions: missing", "cmux_vm.vm_client_sessions_vm_idx: missing"]);
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
