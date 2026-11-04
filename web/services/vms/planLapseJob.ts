import { and, asc, eq } from "drizzle-orm";
import * as Effect from "effect/Effect";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { isVmFreeProvisioningAllowed } from "./entitlements";
import { VmDatabaseError } from "./errors";
import { GO_PAUSE_INTENT_KEY, pausePlanLapsedVm } from "./goPause";
import {
  decideVmPlanLapse,
  lookupVmOwnerPlanFacts,
  stripeSaysStillLive,
  type VmOwnerPlanLookup,
  type VmPlanLapseDecision,
} from "./planLapse";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository, type CloudVmRow } from "./repository";

/** The rest wait for the next run. */
export const VM_PLAN_LAPSE_MAX_PAUSES_PER_RUN = 50;
/** More lapsed owners than this and this share of all owners looks like a bad read, not churn. */
export const VM_PLAN_LAPSE_TRIP_MIN_OWNERS = 10;
export const VM_PLAN_LAPSE_TRIP_OWNER_SHARE = 0.25;
const OWNER_LOOKUP_CONCURRENCY = 8;
const OWNER_LOOKUP_TIMEOUT_MS = 20_000;
const PAUSE_CONCURRENCY = 4;
// The route's maxDuration is 300 s, and one started pause can take 60 s more.
const LOOKUP_BUDGET_MS = 120_000;
const PAUSE_BUDGET_MS = 220_000;

/** Dry run unless an operator turns it on, so people can be told first. */
export function vmPlanLapseEnforced(env: Record<string, string | undefined> = process.env): boolean {
  return env.CMUX_VM_PLAN_LAPSE_PAUSE?.trim() === "enforce";
}

export type VmPlanLapseCandidate = { readonly vmId: string; readonly providerVmId: string; readonly userId: string };

export type VmPlanLapseSummary = {
  readonly mode: "enforce" | "dry_run" | "off_free_provisioning";
  readonly checked: number;
  readonly owners: number;
  readonly decisions: Partial<Record<VmPlanLapseDecision, number>>;
  /** Owner unknown here, a lookup failed, or the run ran out of time: never paused. */
  readonly unknown: number;
  readonly lookupErrors: number;
  /** Stripe said live while the local table did not. */
  readonly stripeMirrorStale: number;
  readonly lapsed: readonly VmPlanLapseCandidate[];
  /** Too many owners looked lapsed, so nothing paused. */
  readonly tripped: boolean;
  readonly paused: number;
  readonly deferred: number;
  /** Changed since the decision (a person paused it, or another job has it). */
  readonly skipped: number;
  readonly errors: number;
};

type Dependencies = {
  readonly lookup?: VmOwnerPlanLookup;
  readonly confirmStillLive?: (userId: string, teamIds: readonly string[]) => Promise<boolean>;
  readonly listRunning?: () => Promise<readonly CloudVmRow[]>;
  readonly stillPausable?: (vm: CloudVmRow) => Promise<boolean>;
  readonly env?: Record<string, string | undefined>;
  readonly now?: () => number;
};

const listRunningFreestyleVms = () => cloudDb().select().from(cloudVms)
  .where(and(eq(cloudVms.status, "running"), eq(cloudVms.provider, "freestyle")))
  .orderBy(asc(cloudVms.createdAt)) as unknown as Promise<readonly CloudVmRow[]>;

const rowStillPausable = async (vm: CloudVmRow): Promise<boolean> => {
  const [row] = await cloudDb().select({ status: cloudVms.status, providerMetadata: cloudVms.providerMetadata })
    .from(cloudVms).where(eq(cloudVms.id, vm.id)).limit(1);
  return row?.status === "running" && row.providerMetadata[GO_PAUSE_INTENT_KEY] == null;
};

/** A name only: a lookup error's message can carry account details. */
function errorName(error: unknown): string {
  const inner = (error as { error?: unknown }).error ?? error;
  return inner instanceof Error ? inner.name : String((inner as { _tag?: unknown })?._tag ?? "unknown");
}

/**
 * The `vm-plan-lapse` cron body: pause running machines whose owner no longer
 * pays and holds no grant. A machine pauses only on positive evidence: every
 * lookup answered, the owner exists, and Stripe itself agrees. Anything else
 * leaves it running and is counted.
 */
export function enforceVmPlanLapse(dependencies: Dependencies = {}) {
  return Effect.gen(function* () {
    const env = dependencies.env ?? process.env;
    const empty = { checked: 0, owners: 0, decisions: {}, unknown: 0, lookupErrors: 0, stripeMirrorStale: 0, lapsed: [], tripped: false, paused: 0, deferred: 0, skipped: 0, errors: 0 };
    // Where free machines are allowed, a free owner has not lapsed from anything.
    if (isVmFreeProvisioningAllowed(env)) return { mode: "off_free_provisioning", ...empty } satisfies VmPlanLapseSummary;
    const enforce = vmPlanLapseEnforced(env);
    const lookup = dependencies.lookup ?? lookupVmOwnerPlanFacts;
    const confirmStillLive = dependencies.confirmStillLive ?? stripeSaysStillLive;
    const stillPausable = dependencies.stillPausable ?? rowStillPausable;
    const now = dependencies.now ?? Date.now;
    const startedAt = now();
    const rows = yield* Effect.tryPromise({
      try: () => (dependencies.listRunning ?? listRunningFreestyleVms)(),
      catch: (cause) => new VmDatabaseError({ operation: "plan_lapse_candidates", cause }),
    });

    const byOwner = new Map<string, CloudVmRow[]>();
    for (const row of rows) {
      const key = `${row.userId}\u0000${row.billingTeamId ?? ""}`;
      const group = byOwner.get(key);
      if (group) group.push(row);
      else byOwner.set(key, [row]);
    }

    const decisions: Partial<Record<VmPlanLapseDecision, number>> = {};
    let unknown = 0;
    let lookupErrors = 0;
    let stripeMirrorStale = 0;
    const lapsedRows: CloudVmRow[] = [];
    yield* Effect.forEach([...byOwner.values()], (group) => Effect.tryPromise(async () => {
      if (now() - startedAt > LOOKUP_BUDGET_MS) {
        unknown += group.length;
        return;
      }
      const { userId, billingTeamId } = group[0]!;
      const facts = await lookup({ userId, billingTeamId });
      if (!facts) {
        unknown += group.length;
        return;
      }
      const decision = decideVmPlanLapse(facts);
      if (decision === "lapsed" && await confirmStillLive(userId, facts.teamIds)) {
        stripeMirrorStale += group.length;
        decisions.keep_stripe = (decisions.keep_stripe ?? 0) + group.length;
        return;
      }
      decisions[decision] = (decisions[decision] ?? 0) + group.length;
      if (decision === "lapsed") lapsedRows.push(...group);
    }).pipe(
      Effect.timeoutFail({ duration: OWNER_LOOKUP_TIMEOUT_MS, onTimeout: () => new Error("owner lookup timed out") }),
      Effect.catchAll((error) => Effect.sync(() => {
        lookupErrors += 1;
        unknown += group.length;
        console.error("[VM] plan lapse lookup failed", { userId: group[0]!.userId, error: errorName(error) });
      })),
    ), { concurrency: OWNER_LOOKUP_CONCURRENCY });

    const pausable = lapsedRows.filter((row) => row.providerVmId);
    const lapsed = pausable.map((row) => ({ vmId: row.id, providerVmId: row.providerVmId!, userId: row.userId }));
    const lapsedOwners = new Set(pausable.map((row) => row.userId)).size;
    const tripped = enforce &&
      env.CMUX_VM_PLAN_LAPSE_ALLOW_LARGE_RUN?.trim() !== "1" &&
      lapsedOwners > VM_PLAN_LAPSE_TRIP_MIN_OWNERS &&
      lapsedOwners > byOwner.size * VM_PLAN_LAPSE_TRIP_OWNER_SHARE;
    const toPause = enforce && !tripped ? pausable.slice(0, VM_PLAN_LAPSE_MAX_PAUSES_PER_RUN) : [];
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const outcomes = yield* Effect.forEach(toPause, (vm) => Effect.gen(function* () {
      if (now() - startedAt > PAUSE_BUDGET_MS) return "deferred" as const;
      const pausableNow = yield* Effect.tryPromise({
        try: () => stillPausable(vm),
        catch: (cause) => new VmDatabaseError({ operation: "plan_lapse_reread", cause }),
      });
      if (!pausableNow) return "skipped" as const;
      yield* pausePlanLapsedVm(repo, providers, vm, vm.providerVmId!);
      return "paused" as const;
    }).pipe(
      Effect.catchAll((error) => Effect.sync(() => {
        console.error("[VM] plan lapse pause failed", { vmId: vm.id, error: errorName(error) });
        return "error" as const;
      })),
    ), { concurrency: PAUSE_CONCURRENCY });

    const count = (outcome: (typeof outcomes)[number]) => outcomes.filter((value) => value === outcome).length;
    return {
      mode: enforce ? "enforce" : "dry_run",
      checked: rows.length,
      owners: byOwner.size,
      decisions,
      unknown,
      lookupErrors,
      stripeMirrorStale,
      lapsed,
      tripped,
      paused: count("paused"),
      deferred: enforce && !tripped ? lapsed.length - toPause.length + count("deferred") : 0,
      skipped: count("skipped"),
      errors: count("error"),
    } satisfies VmPlanLapseSummary;
  });
}
