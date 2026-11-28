import * as Effect from "effect/Effect";
import type { ProviderId } from "./drivers";
import { ProviderStartCapacityError, isProviderStartCapacityRefusal } from "./drivers/types";
import { VmProviderOperationError } from "./errors";
import type { VmRepositoryShape } from "./repository";
import { reportError } from "../observability/report";

/**
 * Fleet-capacity admission for a machine start, and the 80% alerts for team
 * machine quota and fleet machine/start usage.
 *
 * Leo, 2026-11-28 (#general capacity thread): "Add admission checks before
 * starting a run: per-team machine cap, free addresses, and fleet capacity",
 * and "Alert at roughly 80% of team and fleet address/quota usage". The team
 * cap is beginCreate's active limit and free addresses are networkAdmission.ts;
 * this module is the fleet part.
 *
 * Two fleet bounds, both checked before the row, the credit and the provider
 * start are spent:
 *
 * 1. The provider's account-wide start capacity. Freestyle reports none ahead
 *    of time; it answers a start it cannot place with 429
 *    INFRASTRUCTURE_OVERLOADED ("VM start capacity queue wait expired") or a
 *    409 placement refusal, after the caller waited out its queue. Once one
 *    start is refused that way, the next starts on this instance are refused
 *    at admission for a short, growing window (15 s doubling to 2 min) with
 *    the same retryable `vm_provider_capacity` answer and Retry-After, instead
 *    of each queueing at the provider to learn the same thing. The first
 *    start that succeeds closes the window.
 * 2. Fleet-wide machine and in-flight start counts against the account quota,
 *    when the deployment names it (CMUX_VM_FLEET_MAX_LIVE_MACHINES,
 *    CMUX_VM_FLEET_MAX_STARTING). The counts come from our rows, read at most
 *    every 30 s per instance under a 400 ms bound; an unset quota reads
 *    nothing, and an unknown count admits: admission must never be the outage.
 *
 * Alerts go to `cloud_vm_alerts` like the per-network address alert, once an
 * hour per condition: `fleet_start_capacity_refused`, `fleet_machines_high` /
 * `fleet_machines_full`, `fleet_starts_high` / `fleet_starts_full`, and
 * `team_machines_high` (a team past 80% of its machine cap, for caps of 10 or
 * more, where 80% is a warning and not just "the team has its one machine").
 */

export const FLEET_USAGE_ALERT_RATIO = 0.8;
const BREAKER_BASE_MS = 15_000;
const BREAKER_MAX_MS = 120_000;
const FLEET_USAGE_TTL_MS = 30_000;
const FLEET_USAGE_READ_TIMEOUT_MS = 400;
const ALERT_INTERVAL_MS = 60 * 60 * 1000;
/** Team caps below this alert nowhere: at a cap of 2, 80% is every busy team. */
export const TEAM_MACHINE_ALERT_MIN_LIMIT = 10;

type Breaker = { openUntil: number; refusals: number };
const breakers = new Map<ProviderId, Breaker>();
const usageCache = new Map<ProviderId, { at: number; usage: FleetUsage | null }>();
const lastAlertAt = new Map<string, number>();

export type FleetUsage = {
  /** Machines holding provider resources fleet-wide: provisioning, running or paused. */
  readonly liveMachines: number;
  /** Starts in flight fleet-wide: rows still provisioning. */
  readonly starting: number;
};

export type FleetQuota = {
  readonly maxLiveMachines: number | null;
  readonly maxStarting: number | null;
};

type FleetRepo = Partial<Pick<VmRepositoryShape, "fleetCapacityUsage">>;

function positiveInt(value: string | undefined): number | null {
  if (!value) return null;
  const n = Number(value);
  return Number.isInteger(n) && n > 0 ? n : null;
}

export function fleetQuotaFromEnv(env: Record<string, string | undefined> = process.env): FleetQuota {
  return {
    maxLiveMachines: positiveInt(env.CMUX_VM_FLEET_MAX_LIVE_MACHINES),
    maxStarting: positiveInt(env.CMUX_VM_FLEET_MAX_STARTING),
  };
}

/** Decide one bound from a count; pure, so tests pin the thresholds. `held` includes the start being admitted. */
export function fleetBoundVerdict(held: number, max: number | null): "admit" | "alert" | "full" {
  if (max === null) return "admit";
  if (held > max) return "full";
  if (held >= Math.ceil(max * FLEET_USAGE_ALERT_RATIO)) return "alert";
  return "admit";
}

/** Milliseconds the provider's start-capacity window stays open, or 0 when closed. */
export function providerStartWindowMs(provider: ProviderId, now: number = Date.now()): number {
  const breaker = breakers.get(provider);
  return breaker && breaker.openUntil > now ? breaker.openUntil - now : 0;
}

/**
 * Record a provider start's outcome. A start-capacity refusal opens (or
 * lengthens) the provider's window; a start that succeeded closes it; any
 * other failure leaves it as it was.
 */
export function noteProviderStartOutcome(provider: ProviderId, err: unknown | null, now: number = Date.now()): void {
  if (err === null) {
    breakers.delete(provider);
    return;
  }
  if (err instanceof VmProviderOperationError ? !isProviderStartCapacityRefusal(err.cause) : !isProviderStartCapacityRefusal(err)) return;
  // A refusal we raised at admission is not news from the provider.
  if (hasAdmissionRefusal(err)) return;
  const previous = breakers.get(provider);
  const refusals = (previous?.refusals ?? 0) + 1;
  const windowMs = Math.min(BREAKER_BASE_MS * 2 ** (refusals - 1), BREAKER_MAX_MS);
  breakers.set(provider, { refusals, openUntil: now + windowMs });
  alertOnce(`${provider}:start_capacity`, now, "Cloud VM provider refused a start for fleet capacity", {
    code: "fleet_start_capacity_refused",
    provider,
    refusals,
    windowMs,
  });
}

function hasAdmissionRefusal(err: unknown): boolean {
  let current = err;
  for (let depth = 0; depth < 8 && current; depth += 1) {
    if (current instanceof ProviderStartCapacityError) return current.atAdmission;
    current = typeof current === "object" ? (current as { cause?: unknown }).cause : undefined;
  }
  return false;
}

function refuse(provider: ProviderId, operation: string, message: string, retryAfterMs: number): VmProviderOperationError {
  return new VmProviderOperationError({
    provider,
    operation,
    cause: new ProviderStartCapacityError(provider, `${operation}: ${message}; admission refused before the provider start`, {
      atAdmission: true,
      retryAfterMs,
    }),
  });
}

function readFleetUsage(repo: FleetRepo, provider: ProviderId, now: number): Effect.Effect<FleetUsage | null> {
  const cached = usageCache.get(provider);
  if (cached && now - cached.at < FLEET_USAGE_TTL_MS) return Effect.succeed(cached.usage);
  const read = repo.fleetCapacityUsage;
  if (!read) return Effect.succeed(null);
  return read({ provider }).pipe(
    Effect.timeoutTo({ duration: FLEET_USAGE_READ_TIMEOUT_MS, onSuccess: (u) => u as FleetUsage | null, onTimeout: () => null }),
    Effect.catchAll(() => Effect.succeed(null)),
    Effect.tap((usage) => Effect.sync(() => usageCache.set(provider, { at: now, usage }))),
  );
}

/**
 * Fails with a retryable provider-capacity refusal when the fleet has no room
 * for one more start; the route answers `vm_provider_capacity` exactly as it
 * does when the provider itself refuses, but before any provider call.
 */
export function admitFleetCapacity(
  repo: FleetRepo,
  input: { readonly provider: ProviderId; readonly operation: "create" | "resume"; readonly quota?: FleetQuota; readonly now?: number },
): Effect.Effect<FleetUsage | null, VmProviderOperationError> {
  return Effect.gen(function* () {
    const now = input.now ?? Date.now();
    const openMs = providerStartWindowMs(input.provider, now);
    if (openMs > 0) {
      return yield* Effect.fail(refuse(input.provider, input.operation, "the provider refused a recent start for capacity", openMs));
    }
    const quota = input.quota ?? fleetQuotaFromEnv();
    if (quota.maxLiveMachines === null && quota.maxStarting === null) return null;
    const usage = yield* readFleetUsage(repo, input.provider, now);
    if (!usage) return null;
    // A resume brings back a machine that is already counted live.
    const live = fleetBoundVerdict(usage.liveMachines + (input.operation === "create" ? 1 : 0), quota.maxLiveMachines);
    const starting = fleetBoundVerdict(usage.starting + 1, quota.maxStarting);
    const fields = { provider: input.provider, ...usage, ...quota };
    if (live !== "admit") {
      alertOnce(`${input.provider}:machines:${live}`, now, live === "full" ? "Cloud VM fleet at its machine quota" : "Cloud VM fleet past 80% of its machine quota", { code: live === "full" ? "fleet_machines_full" : "fleet_machines_high", ...fields });
    }
    if (starting !== "admit") {
      alertOnce(`${input.provider}:starts:${starting}`, now, starting === "full" ? "Cloud VM fleet at its start quota" : "Cloud VM fleet past 80% of its start quota", { code: starting === "full" ? "fleet_starts_full" : "fleet_starts_high", ...fields });
    }
    if (live === "full") {
      return yield* Effect.fail(refuse(input.provider, input.operation, `the fleet holds ${usage.liveMachines} of ${quota.maxLiveMachines} machines`, BREAKER_BASE_MS));
    }
    if (starting === "full") {
      return yield* Effect.fail(refuse(input.provider, input.operation, `the fleet has ${usage.starting} of ${quota.maxStarting} starts in flight`, BREAKER_BASE_MS));
    }
    return usage;
  });
}

/** Alert when a create leaves a team at or past 80% of its machine cap. `active` includes the new machine. */
export function alertTeamMachineQuota(input: {
  readonly provider: ProviderId;
  readonly billingTeamId: string;
  readonly active: number;
  readonly limit: number | null;
  readonly now?: number;
}): "admit" | "alert" | "full" {
  const { limit } = input;
  if (limit === null || limit < TEAM_MACHINE_ALERT_MIN_LIMIT) return "admit";
  const verdict = input.active >= limit ? "full" : input.active >= Math.ceil(limit * FLEET_USAGE_ALERT_RATIO) ? "alert" : "admit";
  if (verdict === "admit") return verdict;
  alertOnce(`team:${input.billingTeamId}`, input.now ?? Date.now(), "Cloud VM team past 80% of its machine cap", {
    code: "team_machines_high",
    provider: input.provider,
    billingTeamId: input.billingTeamId,
    active: input.active,
    limit,
  });
  return verdict;
}

function alertOnce(key: string, now: number, message: string, fields: Record<string, unknown> & { readonly code: string }): void {
  const last = lastAlertAt.get(key);
  if (last !== undefined && now - last < ALERT_INTERVAL_MS) return;
  lastAlertAt.set(key, now);
  reportError(new Error(message), { subsystem: "cloud_vm_alerts", ...fields });
}

/** Test seam: close every window and forget caches and alert de-duplication. */
export function resetFleetAdmissionForTest(): void {
  breakers.clear();
  usageCache.clear();
  lastAlertAt.clear();
}
