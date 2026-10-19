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
  readonly markupBps: number | null;
  readonly stripeSecretKey?: string;
  readonly stripeMeterEvent?: string;
  readonly fetch?: (request: Request) => Promise<Response>;
}

interface Interval {
  readonly id: string;
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

const HOUR_MS = 3_600_000;
const EXPORT_GRACE_MS = 5 * 60_000;
const STRIPE_WINDOW_MS = 35 * 24 * HOUR_MS;
const DateValue = Schema.Union(Schema.DateFromSelf, Schema.Date);
const NumberValue = Schema.Union(Schema.Number, Schema.NumberFromString);
const IntervalRow = Schema.Struct({
  id: Schema.String,
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
const ResourceRow = Schema.Struct({
  tenant_id: Schema.String,
  cmux_id: Schema.String,
  upstream_id: Schema.String,
  provider: Schema.NullOr(Schema.String),
  region: Schema.NullOr(Schema.String),
  deleted_at: Schema.NullOr(DateValue),
});
const BillingRow = Schema.Struct({ tenant_id: Schema.String, stripe_customer_id: Schema.String, status: Schema.String, activated_at: DateValue });
const ExportRow = Schema.Struct({
  tenant_id: Schema.String,
  hour_start: DateValue,
  stripe_customer_id: Schema.String,
  identifier: Schema.String,
  value_microdollars: NumberValue,
  status: Schema.Literal("pending", "exported", "failed"),
});
const AdjustmentRow = Schema.Struct({ tenant_id: Schema.String, hour_start: DateValue, identifier: Schema.String, value_microdollars: NumberValue, status: Schema.Literal("pending", "exported", "failed") });
const WatermarkRow = Schema.Struct({ watermark: Schema.NullOr(DateValue) });
const decodeRows = <A, I>(schema: Schema.Schema<A, I>, operation: string) => (rows: ReadonlyArray<unknown>) =>
  Schema.decodeUnknown(Schema.Array(schema))(rows).pipe(Effect.mapError((cause) => new StoreError({ operation, cause })));

const toInterval = (row: typeof IntervalRow.Type): Interval => ({
  id: row.id,
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
  "id::text, tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, ended_at, vcpus, memory_mb, storage_mb, compute_billed, source, ended_source";
const hourStart = (time: number) => Math.floor(time / HOUR_MS) * HOUR_MS;
const shapeOf = (event: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number }) => ({
  vcpus: Math.max(0, Math.round(event.vcpus)),
  memoryMb: Math.max(0, Math.round(event.memoryMb)),
  storageMb: Math.max(0, Math.round(event.storageMb)),
});
const sameShape = (interval: Interval, shape: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number }) =>
  interval.vcpus === shape.vcpus && interval.memoryMb === shape.memoryMb && interval.storageMb === shape.storageMb;
const unknownPricing = (provider: string, region: string) => new StoreError({ operation: "metering.price", cause: `unknown provider/region ${provider}/${region}` });

interface MutableUsage {
  readonly vmId: string;
  vcpuHours: number;
  memoryGibHours: number;
  storageGibHours: number;
  listCostMicrodollars: number;
  markedUpCostMicrodollars: number;
}

interface HourCharge {
  readonly tenantId: string;
  readonly hourStart: Date;
  valueMicrodollars: number;
}

const addHourCharge = (
  charges: Map<string, HourCharge>,
  interval: Interval,
  start: number,
  end: number,
  markupBps: number,
): ProviderPrices | null => {
  for (let hour = hourStart(start); hour < end; hour += HOUR_MS) {
    const overlapStart = Math.max(start, hour);
    const overlapEnd = Math.min(end, hour + HOUR_MS);
    if (overlapEnd <= overlapStart) continue;
    const prices = pricesFor(interval.provider, interval.region, new Date(hour));
    if (prices === null) return null;
    const list = intervalCostMicrodollars(interval, (overlapEnd - overlapStart) / HOUR_MS, prices);
    const key = `${interval.tenantId}\u0000${hour}`;
    const current = charges.get(key);
    if (current === undefined) {
      charges.set(key, { tenantId: interval.tenantId, hourStart: new Date(hour), valueMicrodollars: markedUpMicrodollars(list, markupBps) });
    } else {
      current.valueMicrodollars += markedUpMicrodollars(list, markupBps);
    }
  }
  return pricesFor(interval.provider, interval.region, new Date(start));
};

const digestIdentifier = (prefix: string, value: string): Effect.Effect<string> =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))).pipe(
    Effect.map((digest) => `${prefix}${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")}`),
  );

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
          "metering.open.find",
        ).pipe(Effect.map((rows) => rows[0] ?? null));

      const resourceFor = (tenantId: string, upstreamVmId: string) =>
        sql
          .query(
            "metering.resource",
              `SELECT tenant_id, cmux_id, upstream_id, provider, region, deleted_at
               FROM cmux_vm.resources
              WHERE tenant_id = $1 AND kind = 'vm' AND upstream_id = $2 LIMIT 1`,
            [tenantId, upstreamVmId],
          )
          .pipe(Effect.flatMap(decodeRows(ResourceRow, "metering.resource")), Effect.map((rows) => rows[0] ?? null));

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
        readonly provider: string;
        readonly region: string;
        readonly upstreamVmId: string;
        readonly cmuxVmId: string | null;
        readonly at: Date;
        readonly vcpus: number;
        readonly memoryMb: number;
        readonly storageMb: number;
        readonly computeBilled: boolean;
        readonly source: "api" | "reconcile" | "identity";
      }) => {
        const shape = shapeOf(input);
        return sql
          .query(
            "metering.open.insert",
            `INSERT INTO cmux_vm.usage_intervals
              (tenant_id, provider, region, upstream_vm_id, cmux_vm_id, started_at, vcpus, memory_mb, storage_mb, compute_billed, source)
             VALUES ($1, $2, $3, $4, $5, $6::timestamptz, $7, $8, $9, $10, $11)`,
            [input.tenantId, input.provider, input.region, input.upstreamVmId, input.cmuxVmId, input.at.toISOString(), shape.vcpus, shape.memoryMb, shape.storageMb, input.computeBilled, input.source],
          )
          .pipe(Effect.asVoid);
      };

      const transition = (input: {
        readonly tenantId: string;
        readonly upstreamVmId: string;
        readonly at: Date;
        readonly shape: { readonly vcpus: number; readonly memoryMb: number; readonly storageMb: number };
        readonly computeBilled: boolean;
        readonly source: "api" | "reconcile" | "identity";
        readonly cmuxVmId?: string | null;
        readonly provider?: string | null;
        readonly region?: string | null;
      }) =>
        Effect.gen(function* () {
          const current = yield* openFor(input.tenantId, input.upstreamVmId);
          const resource = yield* resourceFor(input.tenantId, input.upstreamVmId);
          if (resource !== null && resource.deleted_at !== null) {
            if (current !== null) yield* closeOpen(input.tenantId, input.upstreamVmId, new Date(Math.max(current.startedAt.getTime(), resource.deleted_at.getTime())), "reconcile");
            return;
          }
          if (current !== null && current.startedAt.getTime() > input.at.getTime()) return;
          if (current !== null && current.computeBilled === input.computeBilled && sameShape(current, input.shape)) return;
          const provider = input.provider ?? resource?.provider ?? "freestyle";
          const region = input.region ?? resource?.region ?? "*";
          if (current !== null) yield* closeOpen(input.tenantId, input.upstreamVmId, input.at, input.source);
          yield* insertInterval({
            tenantId: input.tenantId,
            provider,
            region,
            upstreamVmId: input.upstreamVmId,
            cmuxVmId: input.cmuxVmId ?? resource?.cmux_id ?? current?.cmuxVmId ?? null,
            at: input.at,
            ...input.shape,
            computeBilled: input.computeBilled,
            source: input.source,
          });
        });

      const recordEvent = (event: UsageEvent) => {
        if (event.upstreamVmId.startsWith("vm_")) {
          return Effect.logError("cmux-vm metering rejected a cmux id where an upstream id was required").pipe(Effect.annotateLogs({ operation: event.kind }), Effect.asVoid);
        }
        return Effect.gen(function* () {
          switch (event.kind) {
            case "vm_started":
            case "vm_resized":
              yield* transition({ tenantId: event.tenantId, upstreamVmId: event.upstreamVmId, at: event.at, shape: shapeOf(event), computeBilled: true, source: "api" });
              break;
            case "vm_woken_by_identity": {
              const current = yield* openFor(event.tenantId, event.upstreamVmId);
              if (current !== null) yield* transition({ tenantId: event.tenantId, upstreamVmId: event.upstreamVmId, at: event.at, shape: current, computeBilled: true, source: "identity", cmuxVmId: current.cmuxVmId, provider: current.provider, region: current.region });
              break;
            }
            case "vm_stopped": {
              const current = yield* openFor(event.tenantId, event.upstreamVmId);
              if (current === null || current.startedAt.getTime() > event.at.getTime()) break;
              yield* closeOpen(event.tenantId, event.upstreamVmId, event.at, "api");
              if (event.reason !== "delete") yield* insertInterval({ tenantId: event.tenantId, provider: current.provider, region: current.region, upstreamVmId: event.upstreamVmId, cmuxVmId: current.cmuxVmId, at: event.at, vcpus: current.vcpus, memoryMb: current.memoryMb, storageMb: current.storageMb, computeBilled: false, source: "api" });
              break;
            }
          }
        }).pipe(
          Effect.catchAll((error) => Effect.logError("cmux-vm metering record failed").pipe(Effect.annotateLogs({ operation: error instanceof StoreError ? error.operation : "record" }), Effect.asVoid)),
        );
      };

      const accounts: TenantBillingAccountsService = {
        activeForTenant: (tenantId) =>
          sql.query("billing_accounts.activeForTenant", `SELECT tenant_id, stripe_customer_id, status, activated_at FROM cmux_vm.billing_accounts WHERE tenant_id = $1 AND status = 'active' AND activated_at IS NOT NULL LIMIT 1`, [tenantId]).pipe(
            Effect.flatMap(decodeRows(BillingRow, "billing_accounts.activeForTenant")),
            Effect.map((rows) => {
              const row = rows[0];
              return row === undefined ? null : ({ tenantId: row.tenant_id, stripeCustomerId: row.stripe_customer_id, status: row.status, activatedAt: row.activated_at } satisfies TenantBillingAccount);
            }),
          ),
        active: () =>
          sql.query("billing_accounts.active", `SELECT tenant_id, stripe_customer_id, status, activated_at FROM cmux_vm.billing_accounts WHERE status = 'active' AND activated_at IS NOT NULL`, []).pipe(
            Effect.flatMap(decodeRows(BillingRow, "billing_accounts.active")),
            Effect.map((rows) => rows.map((row) => ({ tenantId: row.tenant_id, stripeCustomerId: row.stripe_customer_id, status: row.status, activatedAt: row.activated_at }))),
          ),
      };

      const usage = (query: UsageQuery): Effect.Effect<UsageReport, StoreError> =>
        Effect.gen(function* () {
          const endLimit = Math.min(query.to.getTime(), query.now.getTime());
          const rows = yield* queryIntervals(
            `SELECT ${intervalColumns} FROM cmux_vm.usage_intervals
              WHERE tenant_id = $1 AND started_at < $3::timestamptz
                AND (ended_at IS NULL OR ended_at > $2::timestamptz)
                AND ($4::text IS NULL OR cmux_vm_id = $4)
              ORDER BY started_at, id`,
            [query.tenantId, query.from.toISOString(), new Date(endLimit).toISOString(), query.vmId],
            "metering.usage",
          );
          const items = new Map<string, MutableUsage>();
          for (const interval of rows) {
            if (interval.cmuxVmId === null || (query.allowedVmIds !== null && !query.allowedVmIds.has(interval.cmuxVmId))) continue;
            const start = Math.max(query.from.getTime(), interval.startedAt.getTime());
            const end = Math.min(endLimit, interval.endedAt?.getTime() ?? endLimit);
            if (end <= start) continue;
            for (let hour = hourStart(start); hour < end; hour += HOUR_MS) {
              const overlapStart = Math.max(start, hour);
              const overlapEnd = Math.min(end, hour + HOUR_MS);
              if (overlapEnd <= overlapStart) continue;
              const prices = pricesFor(interval.provider, interval.region, new Date(hour));
              if (prices === null) return yield* Effect.fail(unknownPricing(interval.provider, interval.region));
              const hours = (overlapEnd - overlapStart) / HOUR_MS;
              const listCost = intervalCostMicrodollars(interval, hours, prices);
              const current = items.get(interval.cmuxVmId) ?? { vmId: interval.cmuxVmId, vcpuHours: 0, memoryGibHours: 0, storageGibHours: 0, listCostMicrodollars: 0, markedUpCostMicrodollars: 0 };
              current.vcpuHours += interval.computeBilled ? interval.vcpus * hours : 0;
              current.memoryGibHours += interval.computeBilled ? (interval.memoryMb / 1024) * hours : 0;
              current.storageGibHours += (interval.storageMb / 1024) * hours;
              current.listCostMicrodollars += listCost;
              current.markedUpCostMicrodollars += markedUpMicrodollars(listCost, config.markupBps ?? 0);
              items.set(interval.cmuxVmId, current);
            }
          }
          const values = [...items.values()];
          const total: UsageTotals = values.reduce((sum, item) => ({ vcpuHours: sum.vcpuHours + item.vcpuHours, memoryGibHours: sum.memoryGibHours + item.memoryGibHours, storageGibHours: sum.storageGibHours + item.storageGibHours, listCostMicrodollars: sum.listCostMicrodollars + item.listCostMicrodollars, markedUpCostMicrodollars: sum.markedUpCostMicrodollars + item.markedUpCostMicrodollars }), { vcpuHours: 0, memoryGibHours: 0, storageGibHours: 0, listCostMicrodollars: 0, markedUpCostMicrodollars: 0 });
          return { items: values, total };
        });

      const reconcile = (runStartedAt: Date, read: (resource: MeteringResource) => Effect.Effect<MeteringProviderRead>) =>
        Effect.gen(function* () {
          const resources = yield* sql.query("metering.resources", `SELECT r.tenant_id, r.cmux_id, r.upstream_id, r.provider, r.region, r.deleted_at FROM cmux_vm.resources r WHERE r.kind = 'vm' AND (r.deleted_at IS NULL OR EXISTS (SELECT 1 FROM cmux_vm.usage_intervals u WHERE u.tenant_id = r.tenant_id AND u.upstream_vm_id = r.upstream_id AND u.ended_at IS NULL)) ORDER BY r.tenant_id, r.cmux_id`, []).pipe(Effect.flatMap(decodeRows(ResourceRow, "metering.resources")));
          yield* Effect.forEach(resources, (row) => {
            const one = Effect.gen(function* () {
              const resource: MeteringResource = { tenantId: row.tenant_id, cmuxVmId: row.cmux_id, upstreamVmId: row.upstream_id, provider: row.provider, region: row.region, deletedAt: row.deleted_at };
              const observedAt = new Date(Math.max(runStartedAt.getTime(), Date.now()));
              const current = yield* openFor(resource.tenantId, resource.upstreamVmId);
              if (resource.deletedAt !== null) {
                if (current !== null) yield* closeOpen(resource.tenantId, resource.upstreamVmId, new Date(Math.max(current.startedAt.getTime(), resource.deletedAt.getTime())), "reconcile");
                return;
              }
              const provider = resource.provider ?? "freestyle";
              const region = resource.region ?? "*";
              const result = yield* read(resource);
              if (result.kind === "unavailable") return;
              if (result.kind === "gone") {
                if (current !== null) yield* closeOpen(resource.tenantId, resource.upstreamVmId, observedAt, "reconcile");
                return;
              }
              const compute = result.vm.state === "running" || result.vm.state === "starting";
              if (!compute && result.vm.state !== "paused" && result.vm.state !== "stopped") return;
              yield* transition({ tenantId: resource.tenantId, upstreamVmId: resource.upstreamVmId, cmuxVmId: resource.cmuxVmId, provider, region, at: observedAt, shape: { vcpus: result.vm.vcpus, memoryMb: result.vm.memoryMb, storageMb: result.vm.storageMb }, computeBilled: compute, source: "reconcile" });
            });
            return one.pipe(Effect.catchAll((error) => Effect.logError("cmux-vm metering reconcile row failed").pipe(Effect.annotateLogs({ operation: error instanceof StoreError ? error.operation : "reconcile" }), Effect.asVoid)));
          }, { concurrency: 8 });
        });

      const exportStripe = (now: Date) =>
        Effect.gen(function* () {
          if (config.markupBps === null) {
            yield* Effect.logError("cmux-vm Stripe export disabled: CMUX_VM_MARKUP_BPS is invalid");
            return;
          }
          if (config.stripeSecretKey === undefined || config.stripeMeterEvent === undefined || config.fetch === undefined) return;
          const accountsRows = yield* accounts.active();
          const markupBps = config.markupBps;
          if (markupBps === null) return;
          const cutoff = now.getTime() - EXPORT_GRACE_MS;
          const lower = now.getTime() - STRIPE_WINDOW_MS;
          const exported = yield* sql.query("metering.exported", `SELECT tenant_id, hour_start, stripe_customer_id, identifier, value_microdollars, status FROM cmux_vm.usage_exports WHERE hour_start >= $1::timestamptz`, [new Date(lower).toISOString()]).pipe(Effect.flatMap(decodeRows(ExportRow, "metering.exported")));
          const adjustments = yield* sql.query("metering.adjustments", `SELECT tenant_id, hour_start, identifier, value_microdollars, status FROM cmux_vm.usage_adjustments WHERE hour_start >= $1::timestamptz`, [new Date(lower).toISOString()]).pipe(Effect.flatMap(decodeRows(AdjustmentRow, "metering.adjustments")));
          const exportedByHour = new Map(exported.map((row) => [`${row.tenant_id}\u0000${row.hour_start.getTime()}`, row]));
          const adjustmentsByHour = new Map<string, ReadonlyArray<typeof AdjustmentRow.Type>>();
          for (const row of adjustments) adjustmentsByHour.set(`${row.tenant_id}\u0000${row.hour_start.getTime()}`, [...(adjustmentsByHour.get(`${row.tenant_id}\u0000${row.hour_start.getTime()}`) ?? []), row]);
          const sendEvent = (account: TenantBillingAccount, value: number, identifier: string, hour: Date) =>
            Effect.tryPromise({
              try: async () => {
                const response = await config.fetch!(new Request("https://api.stripe.com/v1/billing/meter_events", { method: "POST", headers: { authorization: `Bearer ${config.stripeSecretKey}`, "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ event_name: config.stripeMeterEvent!, "payload[stripe_customer_id]": account.stripeCustomerId, "payload[value]": String(value), identifier, timestamp: String(Math.floor(hour.getTime() / 1000)) }) }));
                return { status: response.status, body: await response.text() };
              },
              catch: (cause) => new StoreError({ operation: "metering.stripe", cause }),
            });
          const isDuplicate = (result: { readonly status: number; readonly body: string }, identifier: string) => {
            if (result.status !== 400) return false;
            try {
              const parsed: unknown = JSON.parse(result.body);
              if (typeof parsed !== "object" || parsed === null) return false;
              const error = Reflect.get(parsed, "error");
              if (typeof error !== "object" || error === null) return false;
              if (Reflect.get(error, "code") === "duplicate_meter_event") return true;
              return Reflect.get(error, "type") === "invalid_request_error" && typeof Reflect.get(error, "message") === "string" && String(Reflect.get(error, "message")).includes(`already exists with identifier ${identifier}`);
            } catch { return false; }
          };
          yield* Effect.forEach(accountsRows, (account) => Effect.gen(function* () {
            const watermarkRows = yield* sql.query("metering.exportWatermark", `SELECT min(hour_start) AS watermark FROM cmux_vm.usage_exports WHERE tenant_id = $1 AND status <> 'exported'`, [account.tenantId]).pipe(Effect.flatMap(decodeRows(WatermarkRow, "metering.exportWatermark")));
            const nonFinal = watermarkRows[0]?.watermark?.getTime();
            const start = hourStart(nonFinal === undefined || nonFinal === null ? now.getTime() - 72 * HOUR_MS : Math.min(now.getTime() - 72 * HOUR_MS, nonFinal));
            const rows = yield* queryIntervals(`SELECT ${intervalColumns} FROM cmux_vm.usage_intervals WHERE tenant_id = $1 AND started_at < $2::timestamptz AND (ended_at IS NULL OR ended_at > $3::timestamptz)`, [account.tenantId, new Date(cutoff).toISOString(), new Date(start).toISOString()], "metering.exportIntervals");
            const charges = new Map<string, HourCharge>();
            for (const interval of rows) {
              const from = Math.max(interval.startedAt.getTime(), account.activatedAt.getTime(), start);
              const to = Math.min(interval.endedAt?.getTime() ?? cutoff, cutoff);
              if (to > from && addHourCharge(charges, interval, from, to, markupBps) === null) yield* Effect.fail(unknownPricing(interval.provider, interval.region));
            }
            for (const charge of [...charges.values()].sort((left, right) => left.hourStart.getTime() - right.hourStart.getTime())) {
              if (charge.hourStart.getTime() + HOUR_MS > cutoff) continue;
              const key = `${charge.tenantId}\u0000${charge.hourStart.getTime()}`;
              const prior = exportedByHour.get(key);
              if (prior?.status === "failed") continue;
              const baseIdentifier = prior?.identifier ?? (yield* digestIdentifier("cmux-vm-", key));
              const baseSent = prior?.value_microdollars ?? charge.valueMicrodollars;
              let baseReady = prior?.status === "exported";
              if (prior === undefined) yield* sql.query("metering.exported.pending", `INSERT INTO cmux_vm.usage_exports (tenant_id, hour_start, stripe_customer_id, identifier, value_microdollars, status, attempts) VALUES ($1, $2::timestamptz, $3, $4, $5, 'pending', 0) ON CONFLICT DO NOTHING`, [account.tenantId, charge.hourStart.toISOString(), account.stripeCustomerId, baseIdentifier, baseSent]);
              if (!baseReady) {
                const result = yield* sendEvent(account, baseSent, baseIdentifier, charge.hourStart);
                if (result.status >= 200 && result.status < 300 || isDuplicate(result, baseIdentifier)) {
                  yield* sql.query("metering.exported.done", `UPDATE cmux_vm.usage_exports SET status = 'exported', exported_at = $3::timestamptz, attempts = attempts + 1 WHERE tenant_id = $1 AND hour_start = $2::timestamptz`, [account.tenantId, charge.hourStart.toISOString(), now.toISOString()]);
                  baseReady = true;
                } else if (result.status >= 400 && result.status < 500) {
                  yield* sql.query("metering.exported.failed", `UPDATE cmux_vm.usage_exports SET status = 'failed', attempts = attempts + 1, last_error = $3 WHERE tenant_id = $1 AND hour_start = $2::timestamptz`, [account.tenantId, charge.hourStart.toISOString(), result.body.slice(0, 500)]);
                  continue;
                } else continue;
              }
              if (!baseReady) continue;
              const priorAdjustments = adjustmentsByHour.get(key) ?? [];
              const pendingAdjustment = priorAdjustments.find((row) => row.status === "pending");
              if (pendingAdjustment !== undefined) {
                const retry = yield* sendEvent(account, Number(pendingAdjustment.value_microdollars), pendingAdjustment.identifier, charge.hourStart);
                if (retry.status >= 200 && retry.status < 300 || isDuplicate(retry, pendingAdjustment.identifier)) yield* sql.query("metering.adjustment.done", `UPDATE cmux_vm.usage_adjustments SET status = 'exported', exported_at = $3::timestamptz, attempts = attempts + 1 WHERE tenant_id = $1 AND hour_start = $2::timestamptz AND identifier = $4`, [account.tenantId, charge.hourStart.toISOString(), now.toISOString(), pendingAdjustment.identifier]);
                else continue;
              }
              const sentAdjustments = priorAdjustments.filter((row) => row.status === "exported" || row.status === "pending").reduce((sum, row) => sum + Number(row.value_microdollars), 0);
              const delta = charge.valueMicrodollars - baseSent - sentAdjustments;
              if (delta === 0) continue;
              if (delta < 0) { yield* Effect.logError("cmux-vm usage correction is not exportable as a negative Stripe meter value"); continue; }
              const sequence = priorAdjustments.length;
              const adjustmentIdentifier = yield* digestIdentifier("cmux-vm-adj-", `${baseIdentifier}\u0000${String(sequence)}`);
              const existingAdjustment = priorAdjustments.find((row) => row.identifier === adjustmentIdentifier);
              if (existingAdjustment?.status === "failed" || existingAdjustment?.status === "exported") continue;
              if (existingAdjustment === undefined) yield* sql.query("metering.adjustment.pending", `INSERT INTO cmux_vm.usage_adjustments (tenant_id, hour_start, stripe_customer_id, identifier, value_microdollars, status, attempts) VALUES ($1, $2::timestamptz, $3, $4, $5, 'pending', 0) ON CONFLICT DO NOTHING`, [account.tenantId, charge.hourStart.toISOString(), account.stripeCustomerId, adjustmentIdentifier, delta]);
              const correction = yield* sendEvent(account, delta, adjustmentIdentifier, charge.hourStart);
              if (correction.status >= 200 && correction.status < 300 || isDuplicate(correction, adjustmentIdentifier)) yield* sql.query("metering.adjustment.done", `UPDATE cmux_vm.usage_adjustments SET status = 'exported', exported_at = $3::timestamptz, attempts = attempts + 1 WHERE tenant_id = $1 AND hour_start = $2::timestamptz AND identifier = $4`, [account.tenantId, charge.hourStart.toISOString(), now.toISOString(), adjustmentIdentifier]);
              else if (correction.status >= 400 && correction.status < 500) yield* sql.query("metering.adjustment.failed", `UPDATE cmux_vm.usage_adjustments SET status = 'failed', attempts = attempts + 1, last_error = $3 WHERE tenant_id = $1 AND hour_start = $2::timestamptz AND identifier = $4`, [account.tenantId, charge.hourStart.toISOString(), correction.body.slice(0, 500), adjustmentIdentifier]);
            }
          }).pipe(Effect.catchAll((error) => Effect.logError("cmux-vm Stripe export tenant failed").pipe(Effect.annotateLogs({ operation: error instanceof StoreError ? error.operation : "export" }), Effect.asVoid))), { concurrency: 1 });
        });

      const ledger = { usage, reconcile, exportStripe };
      return Context.make(UsageRecorder, { record: recordEvent }).pipe(Context.add(MeteringLedger, ledger), Context.add(TenantBillingAccounts, accounts));
    }),
  );

export const noopMeteringLayer = Layer.mergeAll(
  Layer.succeed(MeteringLedger, { usage: (): Effect.Effect<UsageReport, never> => Effect.succeed({ items: [], total: { vcpuHours: 0, memoryGibHours: 0, storageGibHours: 0, listCostMicrodollars: 0, markedUpCostMicrodollars: 0 } }), reconcile: () => Effect.void, exportStripe: () => Effect.void }),
  Layer.succeed(TenantBillingAccounts, { activeForTenant: () => Effect.succeed(null), active: () => Effect.succeed([]) }),
  Layer.succeed(UsageRecorder, { record: () => Effect.void }),
);

export const meteringConfig = (env: { readonly CMUX_VM_MARKUP_BPS?: string; readonly STRIPE_SECRET_KEY?: string; readonly CMUX_VM_STRIPE_METER_EVENT?: string }, fetcher?: (request: Request) => Promise<Response>): MeteringConfig => {
  const secret = env.STRIPE_SECRET_KEY?.trim();
  const meterEvent = env.CMUX_VM_STRIPE_METER_EVENT?.trim();
  return { markupBps: parseMarkupBps(env.CMUX_VM_MARKUP_BPS), ...(secret === undefined || secret.length === 0 ? {} : { stripeSecretKey: secret }), ...(meterEvent === undefined || meterEvent.length === 0 ? {} : { stripeMeterEvent: meterEvent }), ...(fetcher === undefined ? {} : { fetch: fetcher }) };
};
