import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import migration1 from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import migration2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import migration11 from "../../migrations/0011_cmux_vm_usage.sql?raw";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { MeteringLedger } from "../../src/metering/ledger.ts";
import { meteringLayer } from "../../src/metering/live.ts";

let pg: PGlite;
const migration = `${migration1}\n${migration2}\n${migration11}`;

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(migration);
});

describe("Stripe metering export", () => {
  it("exports each tenant-hour once with a stable identifier", async () => {
    const requests: Request[] = [];
    await pg.query(
      `INSERT INTO cmux_vm.billing_accounts (tenant_id, stripe_customer_id, status)
       VALUES ('team_a', 'cus_test', 'active')`,
    );
    await pg.query(
      `INSERT INTO cmux_vm.usage_intervals
        (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, ended_at, vcpus, memory_mb, storage_mb, compute_billed, source, ended_source)
       VALUES ('team_a', 'freestyle', '*', 'up-1', 'vm_00000000000000000000000000', '2026-10-18T00:00:00Z', '2026-10-18T01:00:00Z', 4, 8192, 32768, true, 'api', 'api')`,
    );
    const sql = Layer.succeed(SqlClient, {
      query: (operation, text, params) =>
        Effect.tryPromise({
          try: async () => (await pg.query(text, [...params])).rows,
          catch: (cause) => new StoreError({ operation, cause }),
        }),
    });
    const metering = meteringLayer({
      provider: "freestyle",
      region: "*",
      markupBps: 1_000,
      stripeSecretKey: "sk_test",
      stripeMeterEvent: "vm_usage",
      fetch: async (request) => {
        requests.push(request);
        return new Response("{}", { status: 200 });
      },
    }).pipe(Layer.provide(sql));
    const run = <A>(effect: Effect.Effect<A, unknown, MeteringLedger>) => Effect.runPromise(Effect.provide(effect, metering));

    await run(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))));
    await run(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))));

    expect(requests).toHaveLength(1);
    const first = requests[0];
    if (first === undefined) throw new Error("Stripe request was not sent");
    const body = new URLSearchParams(await first.text());
    expect(body.get("event_name")).toBe("vm_usage");
    expect(body.get("payload[stripe_customer_id]")).toBe("cus_test");
    expect(body.get("identifier")).toBe("cmux-vm-team_a-1792281600000");
    const exported = await pg.query<{ count: string }>("SELECT count(*)::text AS count FROM cmux_vm.usage_exports");
    expect(exported.rows[0]?.count).toBe("1");
  });
});
