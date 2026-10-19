import { Effect, Layer } from "effect";
import {
  MeteringLedger,
  TenantBillingAccounts,
  type MeteringProviderRead,
  type MeteringResource,
  type UsageQuery,
  type UsageReport,
  type UsageTotals,
} from "../../src/metering/ledger.ts";
import { UsageRecorder, type UsageEvent } from "../../src/metering/recorder.ts";
import { intervalCostMicrodollars, markedUpMicrodollars, pricesFor } from "../../src/metering/prices.ts";

interface MemoryInterval {
  readonly tenantId: string;
  readonly upstreamVmId: string;
  readonly cmuxVmId: string | null;
  readonly startedAt: Date;
  endedAt: Date | null;
  readonly vcpus: number;
  readonly memoryMb: number;
  readonly storageMb: number;
  readonly computeBilled: boolean;
}

interface MemoryResource {
  readonly tenantId: string;
  readonly cmuxVmId: string;
  readonly upstreamVmId: string;
}

interface MutableSummary {
  readonly vmId: string;
  vcpuHours: number;
  memoryGibHours: number;
  storageGibHours: number;
  listCostMicrodollars: number;
  markedUpCostMicrodollars: number;
}

export const makeMemoryMetering = (resources: () => ReadonlyArray<MemoryResource>, markupBps = 0) => {
  const intervals: MemoryInterval[] = [];
  const events: UsageEvent[] = [];
  const billingAccounts = new Map<string, string>();

  const open = (tenantId: string, upstreamVmId: string) =>
    intervals.find((interval) => interval.tenantId === tenantId && interval.upstreamVmId === upstreamVmId && interval.endedAt === null);
  const cmuxId = (tenantId: string, upstreamVmId: string) =>
    resources().find((row) => row.tenantId === tenantId && row.upstreamVmId === upstreamVmId)?.cmuxVmId ?? null;
  const close = (tenantId: string, upstreamVmId: string, at: Date) => {
    const current = open(tenantId, upstreamVmId);
    if (current !== undefined && current.startedAt <= at) current.endedAt = at;
    return current;
  };
  const start = (input: Omit<MemoryInterval, "endedAt">) => intervals.push({ ...input, endedAt: null });
  const storageFrom = (current: MemoryInterval, at: Date, computeBilled: boolean) =>
    start({
      tenantId: current.tenantId,
      upstreamVmId: current.upstreamVmId,
      cmuxVmId: current.cmuxVmId,
      startedAt: at,
      vcpus: current.vcpus,
      memoryMb: current.memoryMb,
      storageMb: current.storageMb,
      computeBilled,
    });

  const record = (event: UsageEvent) => {
    events.push(event);
    if (event.kind === "vm_started" || event.kind === "vm_resized") {
      const current = open(event.tenantId, event.upstreamVmId);
      if (
        current !== undefined &&
        current.startedAt <= event.at &&
        current.computeBilled &&
        current.vcpus === event.vcpus &&
        current.memoryMb === event.memoryMb &&
        current.storageMb === event.storageMb
      ) return;
      close(event.tenantId, event.upstreamVmId, event.at);
      start({
        tenantId: event.tenantId,
        upstreamVmId: event.upstreamVmId,
        cmuxVmId: cmuxId(event.tenantId, event.upstreamVmId),
        startedAt: event.at,
        vcpus: event.vcpus,
        memoryMb: event.memoryMb,
        storageMb: event.storageMb,
        computeBilled: true,
      });
      return;
    }
    if (event.kind === "vm_woken_by_identity") {
      const current = open(event.tenantId, event.upstreamVmId);
      if (current === undefined || current.computeBilled) return;
      close(event.tenantId, event.upstreamVmId, event.at);
      storageFrom(current, event.at, true);
      return;
    }
    const current = open(event.tenantId, event.upstreamVmId);
    if (current === undefined || (!current.computeBilled && event.reason !== "delete")) return;
    close(event.tenantId, event.upstreamVmId, event.at);
    if (event.reason !== "delete") storageFrom(current, event.at, false);
  };

  const usage = (query: UsageQuery): UsageReport => {
    const byVm = new Map<string, MutableSummary>();
    for (const interval of intervals) {
      if (interval.cmuxVmId === null || interval.tenantId !== query.tenantId) continue;
      if (query.vmId !== null && query.vmId !== interval.cmuxVmId) continue;
      if (query.allowedVmIds !== null && !query.allowedVmIds.has(interval.cmuxVmId)) continue;
      const startAt = Math.max(query.from.getTime(), interval.startedAt.getTime());
      const endAt = Math.min(query.to.getTime(), interval.endedAt?.getTime() ?? query.to.getTime());
      if (endAt <= startAt) continue;
      const hours = (endAt - startAt) / 3_600_000;
      const list = intervalCostMicrodollars(interval, hours, pricesFor("freestyle", "*"));
      const current = byVm.get(interval.cmuxVmId) ?? {
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
      current.listCostMicrodollars += list;
      current.markedUpCostMicrodollars += markedUpMicrodollars(list, markupBps);
      byVm.set(interval.cmuxVmId, current);
    }
    const items = [...byVm.values()];
    const total: UsageTotals = items.reduce(
      (sum, item) => ({
        vcpuHours: sum.vcpuHours + item.vcpuHours,
        memoryGibHours: sum.memoryGibHours + item.memoryGibHours,
        storageGibHours: sum.storageGibHours + item.storageGibHours,
        listCostMicrodollars: sum.listCostMicrodollars + item.listCostMicrodollars,
        markedUpCostMicrodollars: sum.markedUpCostMicrodollars + item.markedUpCostMicrodollars,
      }),
      { vcpuHours: 0, memoryGibHours: 0, storageGibHours: 0, listCostMicrodollars: 0, markedUpCostMicrodollars: 0 },
    );
    return { items, total };
  };

  const reconcile = (now: Date, read: (resource: MeteringResource) => Effect.Effect<MeteringProviderRead>) =>
    Effect.forEach(resources(), (resource) =>
      read(resource).pipe(
        Effect.flatMap((result) => {
          if (result.kind === "unavailable") return Effect.void;
          if (result.kind === "gone") {
            if (open(resource.tenantId, resource.upstreamVmId) !== undefined) close(resource.tenantId, resource.upstreamVmId, now);
            return Effect.void;
          }
          const compute = result.vm.state === "running" || result.vm.state === "starting";
          if (!compute && result.vm.state !== "paused" && result.vm.state !== "stopped") return Effect.void;
          if (compute) {
            record({
              kind: "vm_started",
              tenantId: resource.tenantId,
              upstreamVmId: resource.upstreamVmId,
              at: now,
              vcpus: result.vm.vcpus,
              memoryMb: result.vm.memoryMb,
              storageMb: result.vm.storageMb,
            });
          } else {
            record({
              kind: "vm_stopped",
              tenantId: resource.tenantId,
              upstreamVmId: resource.upstreamVmId,
              at: now,
              reason: result.vm.state === "paused" ? "pause" : "stop",
            });
          }
          return Effect.void;
        }),
      ),
    );

  const layer = Layer.mergeAll(
    Layer.succeed(UsageRecorder, { record: (event: UsageEvent) => Effect.sync(() => record(event)) }),
    Layer.succeed(MeteringLedger, { usage: (query: UsageQuery) => Effect.sync(() => usage(query)), reconcile, exportStripe: () => Effect.void }),
    Layer.succeed(TenantBillingAccounts, {
      activeForTenant: (tenantId: string) => {
        const stripeCustomerId = billingAccounts.get(tenantId);
        return Effect.succeed(stripeCustomerId === undefined ? null : { tenantId, stripeCustomerId, status: "active" });
      },
      active: () => Effect.succeed([...billingAccounts].map(([tenantId, stripeCustomerId]) => ({ tenantId, stripeCustomerId, status: "active" }))),
    }),
  );
  return { layer, events, intervals, billingAccounts, record, usage, reconcile };
};
