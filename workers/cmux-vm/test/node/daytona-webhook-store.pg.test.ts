import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { describe, expect, it } from "vitest";
import migration from "../../migrations/0013_cmux_vm_daytona_webhooks.sql?raw";
import { DaytonaWebhookDeliveryStore, sqlDaytonaWebhookDeliveryStoreLayer } from "../../src/db/identity.ts";
import { SqlClient, StoreError } from "../../src/db/sql.ts";

describe("Daytona webhook delivery store", () => {
  it("creates the dedup table and makes record idempotent", async () => {
    const db = new PGlite();
    await db.exec(migration);
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
