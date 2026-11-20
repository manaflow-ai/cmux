import * as Clock from "effect/Clock";
import * as Effect from "effect/Effect";
import type { ProviderId } from "../drivers";
import type { VmWorkflowError } from "../errors";
import { VmProviderGateway } from "../providerGateway";
import { VmRepository, type VmRepositoryShape } from "../repository";
import { sanitizeDetail } from "./sanitize";
import { classifyVmHealth, vmWorkload, type VmHealthThresholds } from "./classify";
import type {
  ProviderInventoryVm,
  VmHealthReport,
  VmHealthSweepError,
  VmProbeRecord,
} from "./types";

/**
 * The staff Cloud VM health sweep. Read-only toward the provider: it lists
 * VMs and TLS rules and sends one bounded `fs/stat` per running VM. It never
 * pauses, stops, deletes, or edits a VM or a rule, and it does not repair DB
 * drift (the reconcile cron owns repair). Its only write is its own snapshot.
 */
export const VM_HEALTH_PROVIDER: ProviderId = "freestyle";
export const VM_HEALTH_DEFAULT_BUDGET_MS = 200_000;
export const VM_HEALTH_DEFAULT_PROBE_TIMEOUT_MS = 10_000;
export const VM_HEALTH_DEFAULT_PROBE_CONCURRENCY = 16;
export const VM_HEALTH_SNAPSHOT_RETENTION_MS = 3 * 24 * 60 * 60 * 1000;
const PROBE_GUARD_SLACK_MS = 2_000;

export type VmHealthSweepOptions = {
  /** Wall-clock budget for the whole sweep; no probe starts once it cannot finish inside it. */
  readonly budgetMs?: number;
  readonly probeTimeoutMs?: number;
  readonly probeConcurrency?: number;
  /**
   * Probe VMs that have a finite idle timeout. Off by default: a control-path
   * request every five minutes could count as activity and keep a VM from
   * idling out, which would change another workload's behavior.
   */
  readonly probeIdleVms?: boolean;
  readonly thresholds?: Partial<VmHealthThresholds>;
};

export type VmHealthSweepResult = {
  readonly snapshotId: string | null;
  /** Why the snapshot was not stored, when the insert failed. */
  readonly storeError: string | null;
  readonly report: VmHealthReport;
  readonly pruned: number;
};

export function sweepVmHealth(
  options: VmHealthSweepOptions = {},
): Effect.Effect<VmHealthSweepResult, VmWorkflowError, VmRepository | VmProviderGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const startedAtMs = yield* Clock.currentTimeMillis;
    const deadlineAtMs = startedAtMs + (options.budgetMs ?? VM_HEALTH_DEFAULT_BUDGET_MS);
    const errors: VmHealthSweepError[] = [];
    const step = <A>(stage: VmHealthSweepError["stage"], run: (() => Effect.Effect<A, unknown>) | undefined) =>
      run ? recordFailure(run(), stage, errors) : Effect.succeed(null);
    const bounded = <A>(stage: VmHealthSweepError["stage"], run: (() => Effect.Effect<A, unknown>) | undefined) =>
      step(stage, run && (() => untilDeadline(run(), deadlineAtMs)));

    const previous = yield* step("previous_snapshot", repo.latestVmHealthSnapshot);
    const inventory = yield* bounded("inventory", providers.listAccountVms && (() => providers.listAccountVms!(VM_HEALTH_PROVIDER, { deadlineAtMs })));
    const tlsRules = yield* bounded("tls_rules", providers.listAccountTlsRules && (() => providers.listAccountTlsRules!(VM_HEALTH_PROVIDER, { deadlineAtMs })));
    const cmuxIds = (inventory?.vms ?? []).filter((vm) => vmWorkload(vm.metadata) === "cmux_cloud").map((vm) => vm.id);
    const dbRows = yield* step("db_rows", repo.vmHealthDbRows && (() => repo.vmHealthDbRows!({ provider: VM_HEALTH_PROVIDER, providerVmIds: cmuxIds })));

    const probes = yield* probeRunningVms(inventory?.vms ?? [], {
      deadlineAtMs,
      probeTimeoutMs: options.probeTimeoutMs ?? VM_HEALTH_DEFAULT_PROBE_TIMEOUT_MS,
      concurrency: Math.max(1, options.probeConcurrency ?? VM_HEALTH_DEFAULT_PROBE_CONCURRENCY),
      probeIdleVms: options.probeIdleVms ?? false,
    });

    const nowMs = yield* Clock.currentTimeMillis;
    const report = classifyVmHealth({
      now: new Date(nowMs),
      startedAt: new Date(startedAtMs),
      inventory,
      tlsRules,
      dbRows: dbRows ?? [],
      probes,
      previousHung: previous?.report.hung ?? [],
      previousTransitions: previous?.report.transitions ?? [],
      errors,
      thresholds: options.thresholds,
    });
    return { report, ...yield* storeReport(repo, report, nowMs) };
  });
}

/** Run one optional sweep stage; a failure is recorded on the report and the sweep goes on. */
function recordFailure<A>(
  effect: Effect.Effect<A, unknown>,
  stage: VmHealthSweepError["stage"],
  errors: VmHealthSweepError[],
): Effect.Effect<A | null> {
  return effect.pipe(Effect.catchAll((cause) => Effect.sync(() => {
    errors.push({ stage, message: errorMessage(cause) });
    return null;
  })));
}

/**
 * Bound a provider listing by the sweep deadline. Paging checks the deadline
 * only between pages, and one SDK request can poll a backgrounded result for
 * a long time; interruption aborts its signal.
 */
function untilDeadline<A, E>(effect: Effect.Effect<A, E>, deadlineAtMs: number): Effect.Effect<A, E | Error> {
  return Effect.flatMap(Clock.currentTimeMillis, (nowMs) => effect.pipe(Effect.timeoutFail({
    duration: Math.max(0, deadlineAtMs - nowMs),
    onTimeout: () => new Error("listing did not finish inside the sweep budget"),
  })));
}

/**
 * Store the report and prune old ones. A failed insert still returns the
 * report, so the cron can alert on what this sweep found.
 */
function storeReport(
  repo: VmRepositoryShape,
  report: VmHealthReport,
  nowMs: number,
): Effect.Effect<Omit<VmHealthSweepResult, "report">> {
  return Effect.gen(function* () {
    const insert = repo.insertVmHealthSnapshot;
    const stored = insert
      ? yield* insert(report).pipe(Effect.either)
      : null;
    const pruned = repo.pruneVmHealthSnapshots
      ? yield* repo.pruneVmHealthSnapshots({ before: new Date(nowMs - VM_HEALTH_SNAPSHOT_RETENTION_MS) }).pipe(
        Effect.catchAll(() => Effect.succeed(0)),
      )
      : 0;
    if (stored && stored._tag === "Left") return { snapshotId: null, storeError: errorMessage(stored.left), pruned };
    return { snapshotId: stored?.right.id ?? null, storeError: null, pruned };
  });
}

/**
 * Probe every running VM with bounded concurrency. A probe starts only while
 * its full timeout still fits before the deadline; the rest are recorded as
 * skipped so the report says coverage was partial instead of calling them
 * healthy.
 */
export function probeRunningVms(
  vms: readonly ProviderInventoryVm[],
  options: {
    readonly deadlineAtMs: number;
    readonly probeTimeoutMs: number;
    readonly concurrency: number;
    readonly probeIdleVms: boolean;
  },
): Effect.Effect<VmProbeRecord[], never, VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const running = vms.filter((vm) => vm.state === "running");
    const probe = providers.probeVmControl;
    const probeOne = (vm: ProviderInventoryVm): Effect.Effect<VmProbeRecord> => {
      if (!options.probeIdleVms && hasFiniteIdleTimeout(vm)) return Effect.succeed({ vmId: vm.id, outcome: "skipped_idle" });
      return Effect.flatMap(Clock.currentTimeMillis, (nowMs): Effect.Effect<VmProbeRecord> => {
        if (!probe || nowMs + options.probeTimeoutMs > options.deadlineAtMs) {
          return Effect.succeed({ vmId: vm.id, outcome: "skipped_budget" });
        }
        return probe(VM_HEALTH_PROVIDER, vm.id, { timeoutMs: options.probeTimeoutMs }).pipe(
          // The driver already bounds the request; this guards a fetch that ignores its signal.
          Effect.timeoutFail({
            duration: options.probeTimeoutMs + PROBE_GUARD_SLACK_MS,
            onTimeout: () => new Error(`timeout after ${options.probeTimeoutMs}ms`),
          }),
          Effect.map((outcome): VmProbeRecord => ({ vmId: vm.id, ...outcome })),
          Effect.catchAll((cause) => Effect.succeed(probeFailure(vm.id, cause, options.probeTimeoutMs))),
        );
      });
    };
    return yield* Effect.forEach(running, probeOne, { concurrency: options.concurrency });
  });
}

function probeFailure(vmId: string, cause: unknown, timeoutMs: number): VmProbeRecord {
  const message = errorMessage(cause);
  // Only our own guard timeout means the VM did not answer; anything else is
  // a probe that could not be sent and says nothing about the VM.
  if (message.startsWith("timeout after")) return { vmId, outcome: "hung", latencyMs: timeoutMs, detail: message };
  return { vmId, outcome: "error", latencyMs: 0, detail: message };
}

function hasFiniteIdleTimeout(vm: ProviderInventoryVm): boolean {
  return typeof vm.idleTimeoutSeconds === "number" && vm.idleTimeoutSeconds >= 0;
}

function errorMessage(cause: unknown): string {
  const tagged = cause as { readonly _tag?: unknown; readonly operation?: unknown; readonly cause?: unknown; readonly message?: unknown };
  const inner = tagged?.cause instanceof Error ? tagged.cause.message : undefined;
  const base = typeof tagged?._tag === "string"
    ? `${tagged._tag}${typeof tagged.operation === "string" ? ` ${tagged.operation}` : ""}${inner ? `: ${inner}` : ""}`
    : cause instanceof Error ? cause.message : String(cause);
  return sanitizeDetail(base);
}
