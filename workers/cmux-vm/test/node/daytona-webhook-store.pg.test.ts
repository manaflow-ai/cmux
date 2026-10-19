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
import deviceAddress from "../../migrations/0009_cmux_vm_mesh_device_address.sql?raw";
import migration from "../../migrations/0013_cmux_vm_daytona_webhooks.sql?raw";
import { DaytonaWebhookDeliveryStore, sqlDaytonaWebhookDeliveryStoreLayer } from "../../src/db/identity.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";

describe("Daytona webhook delivery store", () => {
  it("creates the dedup table and makes record idempotent", async () => {
    const db = new PGlite();
    for (const sql of [ownership, s2, snapshots, mesh, meshM2, meshM3, meshM4, meshM4Retries, deviceAddress, migration]) await db.exec(sql);
    const sql = Layer.succeed(SqlClient, {
      query: (operation, text, params) =>
        Effect.tryPromise({ try: async () => (await db.query(text, [...params])).rows, catch: (cause) => new StoreError({ operation, cause }) }),
    });
    const layer = sqlDaytonaWebhookDeliveryStoreLayer.pipe(Layer.provide(sql));
    const run = <A, E>(effect: Effect.Effect<A, E, DaytonaWebhookDeliveryStore>) => Effect.runPromise(Effect.provide(effect, layer));
    const delivery = "daytona-message-1";
    expect(await run(Effect.flatMap(DaytonaWebhookDeliveryStore, (store) => store.processed(delivery)))).toBe(false);
    await run(Effect.flatMap(DaytonaWebhookDeliveryStore, (store) => store.record(delivery, "sandbox.state.updated", new Date())));
    await run(Effect.flatMap(DaytonaWebhookDeliveryStore, (store) => store.record(delivery, "sandbox.state.updated", new Date())));
    expect(await run(Effect.flatMap(DaytonaWebhookDeliveryStore, (store) => store.processed(delivery)))).toBe(true);
    const rows = await db.query<{ count: string }>("SELECT count(*)::text AS count FROM cmux_vm.daytona_webhook_deliveries");
    expect(rows.rows[0]?.count).toBe("1");
  });
});
