import { Effect, Layer } from "effect";
import { SqlClient, StoreError, type SqlParam } from "../../src/db/sql.ts";
import { meteringLayer } from "../../src/metering/live.ts";
import { MeteringLedger, type MeteringProviderRead, type MeteringResource } from "../../src/metering/ledger.ts";
import { UsageRecorder, type UsageEvent } from "../../src/metering/recorder.ts";

interface ResourceView {
  readonly tenantId: string;
  readonly cmuxVmId: string;
  readonly upstreamVmId: string;
  readonly provider: string | null;
  readonly region: string | null;
  readonly deletedAt: Date | null;
}

interface IntervalView {
  readonly id: string;
  readonly tenant_id: string;
  readonly provider: string;
  readonly region: string;
  readonly upstream_vm_id: string;
  readonly cmux_vm_id: string | null;
  readonly started_at: Date;
  ended_at: Date | null;
  readonly vcpus: number;
  readonly memory_mb: number;
  readonly storage_mb: number;
  readonly compute_billed: boolean;
  readonly source: "api" | "reconcile" | "identity";
  ended_source: "api" | "reconcile" | "identity" | null;
}

interface BillingView {
  readonly tenant_id: string;
  readonly stripe_customer_id: string;
  readonly status: string;
  readonly activated_at: Date;
}

interface ExportView {
  readonly tenant_id: string;
  readonly hour_start: Date;
  readonly stripe_customer_id: string;
  readonly identifier: string;
  value_microdollars: number;
  status: "pending" | "exported" | "failed";
  last_error: string | null;
}
interface AdjustmentView {
  readonly tenant_id: string;
  readonly hour_start: Date;
  readonly identifier: string;
  readonly value_microdollars: number;
  status: "pending" | "exported" | "failed";
}

const asDate = (value: SqlParam): Date => new Date(String(value));
const sourceOf = (value: string): IntervalView["source"] => value === "identity" ? "identity" : value === "reconcile" ? "reconcile" : "api";
const endedSourceOf = (value: string): IntervalView["ended_source"] => sourceOf(value);

export const makeLiveMetering = (
  resources: () => ReadonlyArray<ResourceView>,
  markupBps = 0,
) => {
  const intervals: IntervalView[] = [];
  const billingAccounts = new Map<string, BillingView>();
  const exports = new Map<string, ExportView>();
  const adjustments = new Map<string, AdjustmentView>();

  const query = (operation: string, params: ReadonlyArray<SqlParam>): ReadonlyArray<unknown> => {
    switch (operation) {
      case "metering.resources":
        return resources().map((row) => ({ tenant_id: row.tenantId, cmux_id: row.cmuxVmId, upstream_id: row.upstreamVmId, provider: row.provider, region: row.region, deleted_at: row.deletedAt }));
      case "metering.resource": {
        const found = resources().find((row) => row.tenantId === String(params[0]) && row.upstreamVmId === String(params[1]));
        return found === undefined ? [] : [{ tenant_id: found.tenantId, cmux_id: found.cmuxVmId, upstream_id: found.upstreamVmId, provider: found.provider, region: found.region, deleted_at: found.deletedAt }];
      }
      case "metering.open.find":
        {
          const found = intervals.find((row) => row.tenant_id === String(params[0]) && row.upstream_vm_id === String(params[1]) && row.ended_at === null);
          return found === undefined ? [] : [found];
        }
      case "metering.close": {
        const tenant = String(params[0]);
        const upstream = String(params[1]);
        const at = asDate(params[2] ?? null);
        const source = endedSourceOf(String(params[3]));
        for (const row of intervals) if (row.tenant_id === tenant && row.upstream_vm_id === upstream && row.ended_at === null && row.started_at <= at) { row.ended_at = at; row.ended_source = source; }
        return [];
      }
      case "metering.open.insert": {
        if (intervals.some((row) => row.tenant_id === String(params[0]) && row.upstream_vm_id === String(params[3]) && row.ended_at === null)) throw new Error("unique open interval");
        const row: IntervalView = {
          id: crypto.randomUUID(),
          tenant_id: String(params[0]),
          provider: String(params[1]),
          region: String(params[2]),
          upstream_vm_id: String(params[3]),
          cmux_vm_id: params[4] === null ? null : String(params[4]),
          started_at: asDate(params[5] ?? null),
          ended_at: null,
          vcpus: Number(params[6]),
          memory_mb: Number(params[7]),
          storage_mb: Number(params[8]),
          compute_billed: Boolean(params[9]),
          source: sourceOf(String(params[10])),
          ended_source: null,
        };
        intervals.push(row);
        return [];
      }
      case "metering.usage":
      case "metering.exportIntervals": {
        const tenant = operation === "metering.usage" ? String(params[0]) : String(params[0]);
        const from = operation === "metering.usage" ? asDate(params[1] ?? null).getTime() : asDate(params[2] ?? null).getTime();
        const to = operation === "metering.usage" ? asDate(params[2] ?? null).getTime() : asDate(params[1] ?? null).getTime();
        const vmId = operation === "metering.usage" && params[3] !== null ? String(params[3]) : null;
        return intervals.filter((row) => (tenant === null || row.tenant_id === tenant) && row.started_at.getTime() < to && (row.ended_at === null || row.ended_at.getTime() > from) && (vmId === null || row.cmux_vm_id === vmId));
      }
      case "billing_accounts.activeForTenant": {
        const row = billingAccounts.get(String(params[0]));
        return row !== undefined && row.status === "active" ? [row] : [];
      }
      case "billing_accounts.active":
        return [...billingAccounts.values()].filter((row) => row.status === "active");
      case "metering.exported":
        return [...exports.values()];
      case "metering.exportWatermark": {
        const rows = [...exports.values()].filter((row) => row.tenant_id === String(params[0]) && row.status !== "exported");
        return [{ watermark: rows.length === 0 ? null : rows.reduce((earliest, row) => row.hour_start < earliest ? row.hour_start : earliest, rows[0]!.hour_start) }];
      }
      case "metering.adjustments":
        return [...adjustments.values()];
      case "metering.exported.pending": {
        const key = `${String(params[0])}\u0000${String(params[1])}`;
        if (!exports.has(key)) exports.set(key, { tenant_id: String(params[0]), hour_start: asDate(params[1] ?? null), stripe_customer_id: String(params[2]), identifier: String(params[3]), value_microdollars: Number(params[4]), status: "pending", last_error: null });
        return [];
      }
      case "metering.exported.pending.update": {
        const key = `${String(params[0])}\u0000${String(params[1])}`;
        const row = exports.get(key);
        if (row !== undefined && row.status === "pending") row.value_microdollars = Number(params[2]);
        return [];
      }
      case "metering.exported.done": {
        const key = `${String(params[0])}\u0000${String(params[1])}`;
        const row = exports.get(key);
        if (row !== undefined) { row.status = "exported"; row.last_error = null; }
        return [];
      }
      case "metering.exported.failed": {
        const key = `${String(params[0])}\u0000${String(params[1])}`;
        const row = exports.get(key);
        if (row !== undefined) { row.status = "failed"; row.last_error = String(params[2]); }
        return [];
      }
      case "metering.adjustment.pending":
        {
          const key = String(params[3]);
          if (!adjustments.has(key)) adjustments.set(key, { tenant_id: String(params[0]), hour_start: asDate(params[1] ?? null), identifier: key, value_microdollars: Number(params[4]), status: "pending" });
          return [];
        }
      case "metering.adjustment.done": {
        const row = adjustments.get(String(params[3]));
        if (row !== undefined) row.status = "exported";
        return [];
      }
      case "metering.adjustment.failed": {
        const row = adjustments.get(String(params[3]));
        if (row !== undefined) row.status = "failed";
        return [];
      }
      default:
        throw new Error(`unsupported metering SQL operation ${operation}`);
    }
  };

  const sql = Layer.succeed(SqlClient, {
    query: (operation: string, _text: string, params: ReadonlyArray<SqlParam>) =>
      Effect.try({ try: () => query(operation, params), catch: (cause) => new StoreError({ operation, cause }) }),
  });
  const layer = meteringLayer({ markupBps, fetch: async () => new Response("{}", { status: 200 }) }).pipe(Layer.provide(sql));
  const record = (event: UsageEvent) => Effect.runPromise(Effect.provide(Effect.flatMap(UsageRecorder, (recorder) => recorder.record(event)), layer));
  const reconcile = (now: Date, read: (resource: MeteringResource) => Effect.Effect<MeteringProviderRead>) =>
    Effect.runPromise(Effect.provide(Effect.flatMap(MeteringLedger, (ledger) => ledger.reconcile(now, read)), layer));
  return { layer, intervals, billingAccounts, exports, sql, record, reconcile };
};
