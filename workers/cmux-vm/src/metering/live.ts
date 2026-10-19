import { Context, Effect, Layer, Schema } from "effect";
import { SqlClient, StoreError, type SqlParam } from "../db/sql.ts";
import { UsageRecorder, type UsageEvent } from "./recorder.ts";
import {
  MeteringLedger,
  TenantBillingAccounts,
  type MeteringProviderRead,
  type MeteringResource,
  type TenantBillingAccount,
  type TenantBillingAccountsService,
  type UsageQuery,
  type UsageReport,
  type UsageTotals,
} from "./ledger.ts";
import { intervalCostMicrodollars, markedUpMicrodollars, parseMarkupBps, pricesFor, type ProviderPrices } from "./prices.ts";

export interface MeteringConfig {
  readonly provider: string;
  readonly region: string;
  readonly markupBps: number | null;
  readonly stripeSecretKey?: string;
  readonly stripeMeterEvent?: string;
  readonly fetch?: (request: Request) => Promise<Response>;
}

interface Interval {
  readonly id: number;
  readonly tenantId: string;
  readonly provider: string;
  readonly region: string;
  readonly upstreamVmId: string;
  readonly cmuxVmId: string | null;
  readonly startedAt: Date;
  readonly endedAt: Date | null;
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly storageMb: number;
  readonly computeBilled: boolean;
  readonly source: "api" | "reconcile" | "identity";
  readonly endedSource: "api" | "reconcile" | "identity" | null;
}

const DateValue = Schema.Union(Schema.DateFromSelf, Schema.Date);
const NumberValue = Schema.Union(Schema.Number, Schema.NumberFromString);
const IntervalRow = Schema.Struct({
  id: NumberValue,
  tenant_id: Schema.String,
  provider: Schema.String,
  region: Schema.String,
  upstream_vm_id: Schema.String,
  cmux_vm_id: Schema.NullOr(Schema.String),
  started_at: DateValue,
  ended_at: Schema.NullOr(DateValue),
  vcpus: NumberValue,
  memory_mb: NumberValue,
  storage_mb: NumberValue,
  compute_billed: Schema.Boolean,
  source: Schema.Literal("api", "reconcile", "identity"),
  ended_source: Schema.NullOr(Schema.Literal("api", "reconcile", "identity")),
});
const ResourceRow = Schema.Struct({ tenant_id: Schema.String, cmux_id: Schema.String, upstream_id: Schema.String });
const BillingRow = Schema.Struct({ tenant_id: Schema.String, stripe_customer_id: Schema.String, status: Schema.String });
const ExportRow = Schema.Struct({ tenant_id: Schema.String, hour_start: DateValue });

const decodeRows = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

const toInterval = (row: typeof IntervalRow.Type): Interval => ({
  id: Number(row.id),
  tenantId: row.tenant_id,
  provider: row.provider,
  region: row.region,
  upstreamVmId: row.upstream_vm_id,
  cmuxVmId: row.cmux_vm_id,
  startedAt: row.started_at,
  endedAt: row.ended_at,
  vcpus: Number(row.vcpus),
  memoryMb: Number(row.memory_mb),
  storageMb: Number(row.storage_mb),
  computeBilled: row.compute_billed,
  source: row.source,
  endedSource: row.ended_source,
});

const intervalColumns =
  "id, tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, ended_at, vcpus, memory_mb, storage_mb, compute_billed, source, ended_source";

const asShape = (event: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number }) => ({
  vcpus: Math.max(0, Math.round(event.vcpus)),
  memoryMb: Math.max(0, Math.round(event.memoryMb)),
  storageMb: Math.max(0, Math.round(event.storageMb)),
});

const sameShape = (interval: Interval, shape: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number }) =>
  interval.vcpus === shape.vcpus && interval.memoryMb === shape.memoryMb && interval.storageMb === shape.storageMb;

const hourStart = (time: number) => Math.floor(time / 3_600_000) * 3_600_000;

interface HourCharge {
  readonly tenantId: string;
  readonly hourStart: Date;
  valueMicrodollars: number;
}

const addCharge = (charges: Map<string, HourCharge>, interval: Interval, start: number, end: number, prices: ProviderPrices, markupBps: number) => {
  const first = hourStart(start);
  const last = hourStart(Math.max(start, end - 1));
  for (let hour = first; hour <= last; hour += 3_600_000) {
    const overlapStart = Math.max(start, hour);
    const overlapEnd = Math.min(end, hour + 3_600_000);
    if (overlapEnd <= overlapStart) continue;
    const list = intervalCostMicrodollars(interval, (overlapEnd - overlapStart) / 3_600_000, prices);
    const key = `${interval.tenantId}\u0000${hour}`;
    const current = charges.get(key);
    if (current === undefined) {
      charges.set(key, { tenantId: interval.tenantId, hourStart: new Date(hour), valueMicrodollars: markedUpMicrodollars(list, markupBps) });
    } else {
      current.valueMicrodollars += markedUpMicrodollars(list, markupBps);
    }
  }
};

export const meteringLayer = (config: MeteringConfig): Layer.Layer<MeteringLedger | UsageRecorder | TenantBillingAccounts, never, SqlClient> =>
  Layer.effectContext(
    Effect.gen(function* () {
      const sql = yield* SqlClient;

      const queryIntervals = (query: string, params: ReadonlyArray<SqlParam>, operation: string) =>
        sql.query(operation, query, params).pipe(Effect.flatMap(decodeRows(IntervalRow, operation)), Effect.map((rows) => rows.map(toInterval)));

      const openFor = (tenantId: string, upstreamVmId: string) =>
        queryIntervals(
          `SELECT ${intervalColumns} FROM cmux_vm.usage_intervals
           WHERE tenant_id = $1 AND upstream_vm_id = $2 AND ended_at IS NULL LIMIT 1`,
          [tenantId, upstreamVmId],
          "metering.open",
        ).pipe(Effect.map((rows) => rows[0] ?? null));

      const cmuxIdFor = (tenantId: string, upstreamVmId: string) =>
        sql
          .query(
            "metering.cmuxId",
            `SELECT cmux_id FROM cmux_vm.resources
             WHERE tenant_id = $1 AND kind = 'vm' AND upstream_id = $2 AND deleted_at IS NULL LIMIT 1`,
            [tenantId, upstreamVmId],
          )
          .pipe(
            Effect.flatMap((rows) => Schema.decodeUnknown(Schema.Array(Schema.Struct({ cmux_id: Schema.String })))(rows)),
            Effect.map((rows) => rows[0]?.cmux_id ?? null),
            Effect.mapError((cause) => new StoreError({ operation: "metering.cmuxId", cause })),
          );

      const closeOpen = (tenantId: string, upstreamVmId: string, at: Date, source: "api" | "reconcile" | "identity") =>
        sql
          .query(
            "metering.close",
            `UPDATE cmux_vm.usage_intervals
                SET ended_at = $3::timestamptz, ended_source = $4
              WHERE tenant_id = $1 AND upstream_vm_id = $2 AND ended_at IS NULL AND started_at <= $3::timestamptz`,
            [tenantId, upstreamVmId, at.toISOString(), source],
          )
          .pipe(Effect.asVoid);

      const insertInterval = (input: {
        readonly tenantId: string;
        readonly upstreamVmId: string;
        readonly cmuxVmId: string | null;
        readonly at: Date;
        readonly vcpus: number;
        readonly memoryMb: number;
        readonly storageMb: number;
        readonly computeBilled: boolean;
        readonly source: "api" | "reconcile" | "identity";
      }) => {
        const shape = asShape(input);
        return sql
          .query(
            "metering.open",
            `INSERT INTO cmux_vm.usage_intervals
              (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, vcpus, memory_mb, storage_mb, compute_billed, source)
             VALUES ($1, $2, $3, $4, $5, $6::timestamptz, $7, $8, $9, $10, $11)`,
            [
              input.tenantId,
              config.provider,
              config.region,
              input.upstreamVmId,
              input.cmuxVmId,
              input.at.toISOString(),
              shape.vcpus,
              shape.memoryMb,
              shape.storageMb,
              input.computeBilled,
              input.source,
            ],
          )
          .pipe(Effect.asVoid);
      };

      const transition = (
        input: {
          readonly tenantId: string;
          readonly upstreamVmId: string;
          readonly at: Date;
          readonly shape: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number };
          readonly computeBilled: boolean;
          readonly source: "api" | "reconcile" | "identity";
          readonly cmuxVmId?: string | null;
        },
      ) =>
        Effect.gen(function* () {
          const current = yield* openFor(input.tenantId, input.upstreamVmId);
          if (current !== null && current.startedAt.getTime() <= input.at.getTime() && current.computeBilled === input.computeBilled && sameShape(current, input.shape)) return;
          if (current !== null) yield* closeOpen(input.tenantId, input.upstreamVmId, input.at, input.source);
          const cmuxVmId = input.cmuxVmId === undefined ? yield* cmuxIdFor(input.tenantId, input.upstreamVmId) : input.cmuxVmId;
          yield* insertInterval({
            tenantId: input.tenantId,
            upstreamVmId: input.upstreamVmId,
            cmuxVmId,
            at: input.at,
            ...input.shape,
            computeBilled: input.computeBilled,
            source: input.source,
          });
        });

      const recordEvent = (event: UsageEvent) =>
        Effect.gen(function* () {
          switch (event.kind) {
            case "vm_started":
              yield* transition({
                tenantId: event.tenantId,
                upstreamVmId: event.upstreamVmId,
                at: event.at,
                shape: asShape(event),
                computeBilled: true,
                source: "api",
              });
              break;
            case "vm_resized":
              yield* transition({
                tenantId: event.tenantId,
                upstreamVmId: event.upstreamVmId,
                at: event.at,
                shape: asShape(event),
                computeBilled: true,
                source: "api",
              });
              break;
            case "vm_woken_by_identity": {
              const current = yield* openFor(event.tenantId, event.upstreamVmId);
              if (current === null) break;
              yield* transition({
                tenantId: event.tenantId,
                upstreamVmId: event.upstreamVmId,
                at: event.at,
                shape: current,
                computeBilled: true,
                source: "identity",
                cmuxVmId: current.cmuxVmId,
              });
              break;
            }
            case "vm_stopped": {
              const current = yield* openFor(event.tenantId, event.upstreamVmId);
              if (current === null) break;
              if (current.startedAt.getTime() > event.at.getTime()) break;
              if (!current.computeBilled && event.reason !== "delete") break;
              yield* closeOpen(event.tenantId, event.upstreamVmId, event.at, "api");
              if (event.reason !== "delete") {
                yield* insertInterval({
                  tenantId: event.tenantId,
                  upstreamVmId: event.upstreamVmId,
                  cmuxVmId: current.cmuxVmId,
                  at: event.at,
                  vcpus: current.vcpus,
                  memoryMb: current.memoryMb,
                  storageMb: current.storageMb,
                  computeBilled: false,
                  source: "api",
                });
              }
              break;
            }
          }
        }).pipe(
          Effect.catchAll((error) =>
            Effect.logWarning("cmux-vm metering record failed").pipe(
              Effect.annotateLogs({ operation: error instanceof StoreError ? error.operation : "record" }),
              Effect.zipRight(Effect.void),
            ),
          ),
        );

      const accounts: TenantBillingAccountsService = {
        activeForTenant: (tenantId) =>
          sql
            .query(
              "billing_accounts.activeForTenant",
              `SELECT tenant_id, stripe_customer_id, status FROM cmux_vm.billing_accounts
               WHERE tenant_id = $1 AND status = 'active' LIMIT 1`,
              [tenantId],
            )
            .pipe(
              Effect.flatMap(decodeRows(BillingRow, "billing_accounts.activeForTenant")),
              Effect.map((rows) => {
                const row = rows[0];
                return row === undefined ? null : ({ tenantId: row.tenant_id, stripeCustomerId: row.stripe_customer_id, status: row.status } satisfies TenantBillingAccount);
              }),
            ),
        active: () =>
          sql
            .query(
              "billing_accounts.active",
              `SELECT tenant_id, stripe_customer_id, status FROM cmux_vm.billing_accounts WHERE status = 'active'`,
              [],
            )
            .pipe(
              Effect.flatMap(decodeRows(BillingRow, "billing_accounts.active")),
              Effect.map((rows) => rows.map((row) => ({ tenantId: row.tenant_id, stripeCustomerId: row.stripe_customer_id, status: row.status }))),
            ),
      };

      const usage = (query: UsageQuery): Effect.Effect<UsageReport, StoreError> =>
        Effect.gen(function* () {
          const rows = yield* queryIntervals(
            `SELECT ${intervalColumns} FROM cmux_vm.usage_intervals
              WHERE tenant_id = $1 AND started_at < $3::timestamptz
                AND (ended_at IS NULL OR ended_at > $2::timestamptz)
                AND ($4::text IS NULL OR cmux_vm_id = $4)
              ORDER BY started_at, id`,
            [query.tenantId, query.from.toISOString(), query.to.toISOString(), query.vmId],
            "metering.usage",
          );
          const items = new Map<string, {
            vmId: string;
            vcpuHours: number;
            memoryGibHours: number;
            storageGibHours: number;
            listCostMicrodollars: number;
            markedUpCostMicrodollars: number;
          }>();
          const from = query.from.getTime();
          const to = query.to.getTime();
          for (const interval of rows) {
            if (interval.cmuxVmId === null) continue;
            if (query.allowedVmIds !== null && !query.allowedVmIds.has(interval.cmuxVmId)) continue;
            const start = Math.max(from, interval.startedAt.getTime());
            const end = Math.min(to, interval.endedAt?.getTime() ?? to);
            if (end <= start) continue;
            const hours = (end - start) / 3_600_000;
            const prices = pricesFor(interval.provider, interval.region);
            const listCost = intervalCostMicrodollars(interval, hours, prices);
            const current = items.get(interval.cmuxVmId) ?? {
              vmId: interval.cmuxVmId,
              vcpuHours: 0,
              memoryGibHours: 0,
              storageGibHours: 0,
              listCostMicrodollars: 0,
              markedUpCostMicrodollars: 0,
            };
            current.vcpuHours += interval.computeBilled ? interval.vcpus * hours : 0;
            current.memoryGibHours += interval.computeBilled ? (interval.memoryMb / 1024) * hours : 0;
            current.storageGibHours += (interval.storageMb / 1024) * hours;
            current.listCostMicrodollars += listCost;
            current.markedUpCostMicrodollars += markedUpMicrodollars(listCost, config.markupBps ?? 0);
            items.set(interval.cmuxVmId, current);
          }
          const values = [...items.values()];
          const total: UsageTotals = values.reduce(
            (sum, item) => ({
              vcpuHours: sum.vcpuHours + item.vcpuHours,
              memoryGibHours: sum.memoryGibHours + item.memoryGibHours,
              storageGibHours: sum.storageGibHours + item.storageGibHours,
              listCostMicrodollars: sum.listCostMicrodollars + item.listCostMicrodollars,
              markedUpCostMicrodollars: sum.markedUpCostMicrodollars + item.markedUpCostMicrodollars,
            }),
            { vcpuHours: 0, memoryGibHours: 0, storageGibHours: 0, listCostMicrodollars: 0, markedUpCostMicrodollars: 0 },
          );
          return { items: values, total };
        });

      const reconcile = (now: Date, read: (resource: MeteringResource) => Effect.Effect<MeteringProviderRead>) =>
        Effect.gen(function* () {
          const resources = yield* sql
            .query(
              "metering.resources",
              `SELECT tenant_id, cmux_id, upstream_id FROM cmux_vm.resources
                WHERE kind = 'vm' AND deleted_at IS NULL ORDER BY tenant_id, cmux_id`,
              [],
            )
            .pipe(Effect.flatMap(decodeRows(ResourceRow, "metering.resources")));
          yield* Effect.forEach(resources, (row) =>
            Effect.gen(function* () {
              const resource: MeteringResource = { tenantId: row.tenant_id, cmuxVmId: row.cmux_id, upstreamVmId: row.upstream_id };
              const result = yield* read(resource);
              if (result.kind === "unavailable") return;
              const current = yield* openFor(resource.tenantId, resource.upstreamVmId);
              if (result.kind === "gone") {
                if (current !== null) yield* closeOpen(resource.tenantId, resource.upstreamVmId, now, "reconcile");
                return;
              }
              const compute = result.vm.state === "running" || result.vm.state === "starting";
              if (!compute && result.vm.state !== "paused" && result.vm.state !== "stopped") return;
              if (
                current !== null &&
                current.startedAt.getTime() <= now.getTime() &&
                current.computeBilled === compute &&
                current.vcpus === Math.round(result.vm.vcpus) &&
                current.memoryMb === Math.round(result.vm.memoryMb) &&
                current.storageMb === Math.round(result.vm.storageMb)
              ) return;
              yield* transition({
                tenantId: resource.tenantId,
                upstreamVmId: resource.upstreamVmId,
                cmuxVmId: resource.cmuxVmId,
                at: now,
                shape: { vcpus: result.vm.vcpus, memoryMb: result.vm.memoryMb, storageMb: result.vm.storageMb },
                computeBilled: compute,
                source: "reconcile",
              });
            }),
            { concurrency: 8 },
          );
        });

      const exportStripe = (now: Date) =>
        Effect.gen(function* () {
          if (config.markupBps === null || config.stripeSecretKey === undefined || config.stripeMeterEvent === undefined) return;
          const accountsByTenant = new Map((yield* accounts.active()).map((account) => [account.tenantId, account]));
          if (accountsByTenant.size === 0) return;
          const rows = yield* queryIntervals(
            `SELECT ${intervalColumns} FROM cmux_vm.usage_intervals WHERE ended_at IS NOT NULL AND ended_at <= $1::timestamptz`,
            [now.toISOString()],
            "metering.exportIntervals",
          );
          const charges = new Map<string, HourCharge>();
          for (const interval of rows) {
            if (interval.endedAt === null) continue;
            addCharge(charges, interval, interval.startedAt.getTime(), interval.endedAt.getTime(), pricesFor(interval.provider, interval.region), config.markupBps);
          }
          const exported = yield* sql
            .query("metering.exported", "SELECT tenant_id, hour_start FROM cmux_vm.usage_exports", [])
            .pipe(Effect.flatMap(decodeRows(ExportRow, "metering.exported")));
          const exportedKeys = new Set(exported.map((row) => `${row.tenant_id}\u0000${row.hour_start.getTime()}`));
          const sendRequest = config.fetch ?? ((request: Request) => globalThis.fetch(request));
          for (const charge of charges.values()) {
            const account = accountsByTenant.get(charge.tenantId);
            if (account === undefined) continue;
            const key = `${charge.tenantId}\u0000${charge.hourStart.getTime()}`;
            if (exportedKeys.has(key)) continue;
            const identifier = `cmux-vm-${charge.tenantId}-${charge.hourStart.getTime()}`;
            const body = new URLSearchParams({
              event_name: config.stripeMeterEvent,
              "payload[stripe_customer_id]": account.stripeCustomerId,
              "payload[value]": String(charge.valueMicrodollars),
              identifier,
            });
            const response = yield* Effect.tryPromise(() =>
              sendRequest(
                new Request("https://api.stripe.com/v1/billing/meter_events", {
                  method: "POST",
                  headers: { authorization: `Bearer ${config.stripeSecretKey}`, "content-type": "application/x-www-form-urlencoded" },
                  body,
                }),
              ),
            ).pipe(Effect.catchAll(() => Effect.succeed(null)));
            if (response === null || response.status < 200 || response.status > 299) {
              yield* Effect.promise(() => response?.body?.cancel() ?? Promise.resolve());
              continue;
            }
            yield* Effect.promise(() => response.body?.cancel() ?? Promise.resolve());
            yield* sql
              .query(
                "metering.exported.insert",
                `INSERT INTO cmux_vm.usage_exports
                  (tenant_id, hour_start, stripe_customer_id, identifier, value_microdollars, exported_at)
                 VALUES ($1, $2::timestamptz, $3, $4, $5, $6::timestamptz)
                 ON CONFLICT DO NOTHING`,
                [charge.tenantId, charge.hourStart.toISOString(), account.stripeCustomerId, identifier, charge.valueMicrodollars, now.toISOString()],
              )
              .pipe(Effect.asVoid);
            exportedKeys.add(key);
          }
        });

      const ledger = { usage, reconcile, exportStripe };
      return Context.make(UsageRecorder, { record: recordEvent }).pipe(
        Context.add(MeteringLedger, ledger),
        Context.add(TenantBillingAccounts, accounts),
      );
    }),
  );

export const noopMeteringLayer = Layer.mergeAll(
  Layer.succeed(MeteringLedger, {
    usage: (): Effect.Effect<UsageReport, never> => Effect.succeed({
      items: [],
      total: { vcpuHours: 0, memoryGibHours: 0, storageGibHours: 0, listCostMicrodollars: 0, markedUpCostMicrodollars: 0 },
    }),
    reconcile: () => Effect.void,
    exportStripe: () => Effect.void,
  }),
  Layer.succeed(TenantBillingAccounts, { activeForTenant: () => Effect.succeed(null), active: () => Effect.succeed([]) }),
  Layer.succeed(UsageRecorder, { record: () => Effect.void }),
);

export const meteringConfig = (env: {
  readonly CMUX_VM_PROVIDER?: string;
  readonly CMUX_VM_PROVIDER_REGION?: string;
  readonly CMUX_VM_MARKUP_BPS?: string;
  readonly STRIPE_SECRET_KEY?: string;
  readonly CMUX_VM_STRIPE_METER_EVENT?: string;
}): MeteringConfig => {
  const secret = env.STRIPE_SECRET_KEY?.trim();
  const meterEvent = env.CMUX_VM_STRIPE_METER_EVENT?.trim();
  return {
    provider: env.CMUX_VM_PROVIDER?.trim() || "freestyle",
    region: env.CMUX_VM_PROVIDER_REGION?.trim() || "*",
    markupBps: parseMarkupBps(env.CMUX_VM_MARKUP_BPS),
    ...(secret === undefined || secret.length === 0 ? {} : { stripeSecretKey: secret }),
    ...(meterEvent === undefined || meterEvent.length === 0 ? {} : { stripeMeterEvent: meterEvent }),
  };
};
