import { PGlite } from "@electric-sql/pglite";
import { Effect, Layer } from "effect";
import { beforeEach, describe, expect, it } from "vitest";
import migration1 from "../../migrations/0001_cmux_vm_ownership.sql?raw";
import migration2 from "../../migrations/0002_cmux_vm_display_name_audit.sql?raw";
import migration11 from "../../migrations/0011_cmux_vm_usage.sql?raw";
import { SqlClient, StoreError } from "../../src/db/sql.ts";
import { MeteringLedger } from "../../src/metering/ledger.ts";
import { meteringLayer } from "../../src/metering/live.ts";
import { pricesFor, type PriceTable } from "../../src/metering/prices.ts";

let pg: PGlite;
const migration = `${migration1}\n${migration2}\n${migration11}`;

const sqlLayer = (failOperation?: string) => {
  let failed = false;
  return Layer.succeed(SqlClient, {
    query: (operation, text, params) =>
      Effect.tryPromise({
        try: async () => {
          if (operation === failOperation && !failed) {
            failed = true;
            throw new Error("injected SQL failure");
          }
          return (await pg.query(text, [...params])).rows;
        },
        catch: (cause) => new StoreError({ operation, cause }),
      }),
  });
};

const seedAccount = async (activatedAt = "2026-10-17T00:00:00Z") => {
  await pg.query(
    `INSERT INTO cmux_vm.billing_accounts (tenant_id, stripe_customer_id, status, activated_at)
     VALUES ('team_a', 'cus_test', 'active', $1::timestamptz)`,
    [activatedAt],
  );
};

const seedInterval = async (values: { readonly started: string; readonly ended?: string; readonly tenant?: string; readonly cmux?: string; readonly upstream?: string }) => {
  await pg.query(
    `INSERT INTO cmux_vm.usage_intervals
      (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, ended_at, vcpus, memory_mb, storage_mb, compute_billed, source, ended_source)
     VALUES ($1, 'freestyle', '*', $2, $3, $4::timestamptz, $5::timestamptz, 4, 8192, 32768, true, 'api', CASE WHEN $5::timestamptz IS NULL THEN NULL ELSE 'api' END)`,
    [values.tenant ?? "team_a", values.upstream ?? `up-${crypto.randomUUID()}`, values.cmux ?? "vm_00000000000000000000000000", values.started, values.ended ?? null],
  );
};

beforeEach(async () => {
  pg = new PGlite();
  await pg.exec(migration);
});

describe("Stripe metering export", () => {
  it("uses the dated price in force for each hour", () => {
    const testPrices: PriceTable = { freestyle: { "*": [
      { effective_from: "2026-10-17T00:00:00.000Z", vcpuHourMicrodollars: 40_320, memoryGibHourMicrodollars: 12_900, storageGibHourMicrodollars: 86, transferGbMicrodollars: 20_000 },
      { effective_from: "2026-10-19T00:00:00.000Z", vcpuHourMicrodollars: 50_000, memoryGibHourMicrodollars: 15_000, storageGibHourMicrodollars: 100, transferGbMicrodollars: 20_000 },
    ] } };
    const before = pricesFor("freestyle", "*", new Date("2026-10-18T12:00:00Z"), testPrices);
    const after = pricesFor("freestyle", "*", new Date("2026-10-19T12:00:00Z"), testPrices);
    expect(before?.vcpuHourMicrodollars).toBe(40_320);
    expect(after?.vcpuHourMicrodollars).toBe(50_000);
  });

  it("exports each tenant-hour once with a stable identifier", async () => {
    const requests: Request[] = [];
    await pg.query(
      `INSERT INTO cmux_vm.billing_accounts (tenant_id, stripe_customer_id, status, activated_at)
       VALUES ('team_a', 'cus_test', 'active', '2026-10-17T00:00:00Z')`,
    );
    await pg.query(
      `INSERT INTO cmux_vm.usage_intervals
        (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, ended_at, vcpus, memory_mb, storage_mb, compute_billed, source, ended_source)
       VALUES ('team_a', 'freestyle', '*', 'up-1', 'vm_00000000000000000000000000', '2026-10-18T00:00:00Z', '2026-10-18T01:00:00Z', 4, 8192, 32768, true, 'api', 'api')`,
    );
    const sql = sqlLayer();
    const metering = meteringLayer({
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
    await run(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))));

    expect(requests).toHaveLength(1);
    const first = requests[0];
    if (first === undefined) throw new Error("Stripe request was not sent");
    const body = new URLSearchParams(await first.text());
    expect(body.get("event_name")).toBe("vm_usage");
    expect(body.get("payload[stripe_customer_id]")).toBe("cus_test");
    expect(body.get("payload[value]")).toBe("293955");
    expect(body.get("identifier")).toMatch(/^cmux-vm-[0-9a-f]{64}$/u);
    expect(body.get("timestamp")).toBe("1792281600");
    expect(new Set(requests.map((request) => request.url))).toEqual(new Set(["https://api.stripe.com/v1/billing/meter_events"]));
    const exported = await pg.query<{ count: string }>("SELECT count(*)::text AS count FROM cmux_vm.usage_exports");
    expect(exported.rows[0]?.count).toBe("1");
  });

  it("sends two later corrections as distinct adjustments", async () => {
    await seedAccount();
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z" });
    const requests: Request[] = [];
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async (request) => { requests.push(request); return new Response("{}", { status: 200 }); } }).pipe(Layer.provide(sqlLayer()));
    const run = () => Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    await run();
    await seedInterval({ started: "2026-10-18T00:30:00Z", ended: "2026-10-18T01:00:00Z", cmux: "vm_00000000000000000000000001" });
    await run();
    await seedInterval({ started: "2026-10-18T00:30:00Z", ended: "2026-10-18T01:00:00Z", cmux: "vm_00000000000000000000000002" });
    await run();
    const adjustments = await pg.query<{ count: string }>("SELECT count(*)::text AS count FROM cmux_vm.usage_adjustments WHERE status = 'exported'");
    expect(adjustments.rows[0]?.count).toBe("2");
    await run();
    expect(requests).toHaveLength(3);
    const values = await Promise.all(requests.map(async (request) => Number(new URLSearchParams(await request.clone().text()).get("payload[value]"))));
    expect(values).toEqual([267232, 133616, 133616]);
  });

  it("aggregates overlapping VMs, clips open intervals at a completed hour, and honors activation", async () => {
    await seedAccount("2026-10-18T00:45:00Z");
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z", cmux: "vm_00000000000000000000000000" });
    await seedInterval({ started: "2026-10-18T00:30:00Z", cmux: "vm_00000000000000000000000001" });
    const requests: Request[] = [];
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async (request) => { requests.push(request); return new Response("{}", { status: 200 }); } }).pipe(Layer.provide(sqlLayer()));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    expect(requests).toHaveLength(1);
    const body = new URLSearchParams(await requests[0]!.text());
    expect(Number(body.get("payload[value]"))).toBe(133616);
    expect(body.get("timestamp")).toBe("1792281600");
  });

  it("keeps a failed hour pending while exporting the next hour", async () => {
    await seedAccount();
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z" });
    await seedInterval({ started: "2026-10-18T01:00:00Z", ended: "2026-10-18T02:00:00Z", cmux: "vm_00000000000000000000000001" });
    const requests: Request[] = [];
    let first = true;
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async (request) => {
      requests.push(request);
      if (first) { first = false; return new Response("temporary", { status: 500 }); }
      return new Response("{}", { status: 200 });
    } }).pipe(Layer.provide(sqlLayer()));
    const run = () => Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T03:00:00Z"))), metering));
    await run();
    await run();
    expect(requests).toHaveLength(3);
    const exported = await pg.query<{ hour_start: string; status: string }>("SELECT hour_start::text, status FROM cmux_vm.usage_exports ORDER BY hour_start");
    expect(exported.rows.map((row) => row.status)).toEqual(["exported", "exported"]);
  });

  it("resends pending base and adjustment rows using their existing identifiers", async () => {
    await seedAccount();
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z" });
    await pg.query(`INSERT INTO cmux_vm.usage_exports (tenant_id, hour_start, stripe_customer_id, identifier, value_microdollars, status)
      VALUES ('team_a', '2026-10-18T00:00:00Z', 'cus_test', 'main-pending', 200000, 'pending')`);
    await pg.query(`INSERT INTO cmux_vm.usage_adjustments (tenant_id, hour_start, stripe_customer_id, identifier, value_microdollars, status)
      VALUES ('team_a', '2026-10-18T00:00:00Z', 'cus_test', 'adj-pending', 67232, 'pending')`);
    const requests: Request[] = [];
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async (request) => { requests.push(request); return new Response("{}", { status: 200 }); } }).pipe(Layer.provide(sqlLayer()));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    const identifiers = await Promise.all(requests.map(async (request) => new URLSearchParams(await request.clone().text()).get("identifier")));
    expect(identifiers).toEqual(["main-pending", "adj-pending"]);
  });

  it("recovers after a crash following Stripe 2xx through a duplicate identifier", async () => {
    await seedAccount();
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z" });
    let calls = 0;
    let duplicate = false;
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async (request) => { calls += 1; if (duplicate) { const body = new URLSearchParams(await request.text()); return new Response(JSON.stringify({ error: { type: "invalid_request_error", message: `An event ALREADY EXISTS with IDENTIFIER ${body.get("identifier")}` } }), { status: 400 }); } return new Response("{}", { status: 200 }); } }).pipe(Layer.provide(sqlLayer("metering.exported.done")));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    duplicate = true;
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    expect(calls).toBe(2);
    const status = await pg.query<{ status: string }>("SELECT status FROM cmux_vm.usage_exports");
    expect(status.rows[0]?.status).toBe("exported");
  });

  it("marks permanent Stripe 4xx failures and does not retry them", async () => {
    await seedAccount();
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z" });
    let calls = 0;
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async () => { calls += 1; return new Response("unknown customer", { status: 400 }); } }).pipe(Layer.provide(sqlLayer()));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    expect(calls).toBe(1);
    const status = await pg.query<{ status: string }>("SELECT status FROM cmux_vm.usage_exports");
    expect(status.rows[0]?.status).toBe("failed");
  });

  it("continues exporting other tenants after one Stripe network failure", async () => {
    await seedAccount();
    await pg.query("INSERT INTO cmux_vm.billing_accounts (tenant_id, stripe_customer_id, status, activated_at) VALUES ('team_b', 'cus_b', 'active', '2026-10-17T00:00:00Z')");
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z", tenant: "team_a" });
    await seedInterval({ started: "2026-10-18T00:00:00Z", ended: "2026-10-18T01:00:00Z", tenant: "team_b", cmux: "vm_00000000000000000000000001" });
    const customers: string[] = [];
    const metering = meteringLayer({ markupBps: 0, stripeSecretKey: "sk_test", stripeMeterEvent: "vm_usage", fetch: async (request) => {
      const body = new URLSearchParams(await request.text());
      const customer = body.get("payload[stripe_customer_id]") ?? "";
      customers.push(customer);
      if (customer === "cus_test") throw new Error("network down");
      return new Response("{}", { status: 200 });
    } }).pipe(Layer.provide(sqlLayer()));
    await Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.exportStripe(new Date("2026-10-18T02:00:00Z"))), metering));
    expect(customers).toContain("cus_b");
    const exported = await pg.query<{ tenant_id: string }>("SELECT tenant_id FROM cmux_vm.usage_exports WHERE status = 'exported'");
    expect(exported.rows.map((row) => row.tenant_id)).toContain("team_b");
  });
});
