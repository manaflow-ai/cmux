import * as Effect from "effect/Effect";
import type { ProviderId } from "./drivers";
import { providerConflictKind } from "./drivers/types";
import { VmProviderOperationError } from "./errors";
import type { VmRepositoryShape } from "./repository";
import { reportError } from "../observability/report";

/**
 * Fleet-capacity admission and quota alerts for a new machine.
 *
 * Leo, 2026-11-28 (capacity thread): "Add admission checks before starting a
 * run: per-team machine cap, free addresses, and fleet capacity", and "Alert
 * at roughly 80% of team and fleet address/quota usage". The team cap lives in
 * repository beginCreate and free addresses in networkAdmission.ts; this
 * module covers the fleet:
 *
 * - The provider's start capacity. It reports no free count, so the only
 *   signals are its 409 placement refusal and its 429 start-capacity throttle. After one, new creates on that provider
 *   are refused here for FLEET_CAPACITY_COOLDOWN_MS with the same capacity
 *   answer, so a burst does not spend a row, a credit and a provider round
 *   trip per refused start. The cooldown is per web instance (in memory).
 * - An optional fleet machine cap, `CMUX_VM_FLEET_MAX_ACTIVE_VMS`: live rows
 *   (provisioning, running, paused) on the provider past the cap are refused,
 *   and 80% of it alerts. Unset means no fleet cap and no extra count.
 * - The team machine quota at 80%, from the count beginCreate already read.
 */

export const FLEET_CAPACITY_COOLDOWN_MS = 20_000;
export const FLEET_QUOTA_ALERT_RATIO = 0.8;
const FLEET_ALERT_INTERVAL_MS = 60 * 60 * 1000;
const capacityRefusedAt = new Map<ProviderId, number>();
const lastAlertAt = new Map<string, number>();

/** Usage at or past this many of `limit` alerts. */
export function quotaAlertThreshold(limit: number): number {
  return Math.ceil(limit * FLEET_QUOTA_ALERT_RATIO);
}

const START_CAPACITY_THROTTLE_MESSAGE = /start capacity|infrastructure overloaded/i;

/**
 * A provider start refused for capacity: a 409 placement refusal
 * (providerConflictKind), or the account-wide 429 "infrastructure overloaded:
 * VM start capacity" throttle, which no other classifier reads.
 */
export function isProviderStartCapacityRefusal(err: unknown): boolean {
  if (providerConflictKind(err) === "capacity") return true;
  let current = err;
  for (let depth = 0; depth < 8 && current && typeof current === "object"; depth += 1) {
    const record = current as { status?: unknown; message?: unknown; body?: { message?: unknown }; cause?: unknown };
    if (typeof record.status === "number") {
      if (record.status !== 429) return false;
      const message = typeof record.message === "string" ? record.message : typeof record.body?.message === "string" ? record.body.message : "";
      return START_CAPACITY_THROTTLE_MESSAGE.test(message);
    }
    current = record.cause;
  }
  return false;
}

/** Remember a provider start refused for capacity; later creates wait out the cooldown. */
export function noteProviderStartRefusal(provider: ProviderId, cause: unknown, now = Date.now()): boolean {
  if (!isProviderStartCapacityRefusal(cause)) return false;
  capacityRefusedAt.set(provider, now);
  alertOnce(`start_capacity:${provider}`, "Cloud VM provider refused a start for capacity", {
    code: "provider_start_capacity",
    provider,
  }, now);
  return true;
}

/** Milliseconds left in the provider's capacity cooldown, or 0. */
export function providerCapacityCooldownMs(provider: ProviderId, now = Date.now()): number {
  const at = capacityRefusedAt.get(provider);
  if (at === undefined) return 0;
  const left = at + FLEET_CAPACITY_COOLDOWN_MS - now;
  if (left <= 0) {
    capacityRefusedAt.delete(provider);
    return 0;
  }
  return left;
}

/** The fleet machine cap from the environment, or null when unset or invalid. */
export function fleetMaxActiveVms(env: Record<string, string | undefined> = process.env): number | null {
  const raw = env.CMUX_VM_FLEET_MAX_ACTIVE_VMS?.trim();
  if (!raw || !/^\d+$/.test(raw)) return null;
  const value = Number(raw);
  return value > 0 ? value : null;
}

/**
 * A capacity refusal shaped like the provider's own (409 PLACEMENT_REJECTED),
 * so providerConflictKind and the route answer it exactly as a provider refusal.
 */
export class FleetCapacityAdmissionError extends Error {
  readonly status = 409;
  readonly code = "PLACEMENT_REJECTED";
  constructor(message: string) {
    super(message);
    this.name = "FleetCapacityAdmissionError";
  }
}

type FleetRepo = Pick<VmRepositoryShape, "countLiveProviderVms">;

export type FleetAdmissionInput = {
  readonly provider: ProviderId;
  readonly env?: Record<string, string | undefined>;
  readonly now?: number;
};

/**
 * Refuses before any provider call while the provider's capacity cooldown runs
 * or the fleet is past its cap. A count that cannot be read admits: the
 * provider's refusal stays the backstop, and admission must never be the outage.
 */
export function admitFleetCapacity(
  repo: FleetRepo,
  input: FleetAdmissionInput,
): Effect.Effect<{ readonly live: number | null; readonly cap: number | null }, VmProviderOperationError> {
  return Effect.gen(function* () {
    const now = input.now ?? Date.now();
    const cooldown = providerCapacityCooldownMs(input.provider, now);
    if (cooldown > 0) {
      return yield* Effect.fail(refusal(input.provider, `create: no manager has enough capacity (the provider refused a start ${Math.round((FLEET_CAPACITY_COOLDOWN_MS - cooldown) / 1000)}s ago; admission waits ${Math.ceil(cooldown / 1000)}s more before trying it)`));
    }
    const cap = fleetMaxActiveVms(input.env);
    const countLive = repo.countLiveProviderVms;
    if (cap === null || !countLive) return { live: null, cap };
    const live = yield* countLive({ provider: input.provider }).pipe(Effect.catchAll(() => Effect.succeed(null)));
    if (live === null) return { live: null, cap };
    if (live >= quotaAlertThreshold(cap)) {
      alertOnce(`fleet_quota:${input.provider}:${live > cap ? "full" : "high"}`, live > cap ? "Cloud VM fleet cap reached at admission" : "Cloud VM fleet past 80% of its machine cap", {
        code: live > cap ? "fleet_machine_cap_full" : "fleet_machine_cap_high",
        provider: input.provider,
        live,
        cap,
      }, now);
    }
    // `live` includes the row this create inserted.
    if (live > cap) {
      return yield* Effect.fail(refusal(input.provider, `create: no manager has enough capacity (fleet holds ${live - 1} of ${cap} machines; admission refused before the provider start)`));
    }
    return { live, cap };
  });
}

/** Alert once the team's machine count (this create included) reaches 80% of its plan limit. */
export function alertTeamQuotaUsage(input: {
  readonly provider: ProviderId;
  readonly billingTeamId: string | null | undefined;
  readonly activeAfter: number;
  readonly limit: number | null;
  readonly now?: number;
}): boolean {
  if (input.limit === null || input.limit <= 0 || !input.billingTeamId) return false;
  if (input.activeAfter < quotaAlertThreshold(input.limit)) return false;
  return alertOnce(`team_quota:${input.billingTeamId}`, "Cloud VM team past 80% of its machine limit", {
    code: "team_machine_quota_high",
    provider: input.provider,
    billingTeamId: input.billingTeamId,
    active: input.activeAfter,
    limit: input.limit,
  }, input.now ?? Date.now());
}

function refusal(provider: ProviderId, message: string): VmProviderOperationError {
  return new VmProviderOperationError({ provider, operation: "create", cause: new FleetCapacityAdmissionError(message) });
}

function alertOnce(key: string, message: string, fields: Record<string, unknown>, now: number): boolean {
  const last = lastAlertAt.get(key);
  if (last !== undefined && now - last < FLEET_ALERT_INTERVAL_MS) return false;
  lastAlertAt.set(key, now);
  reportError(new Error(message), { subsystem: "cloud_vm_alerts", ...fields });
  return true;
}

/** Test seam: forget cooldowns and alert de-duplication. */
export function resetFleetAdmissionForTest(): void {
  capacityRefusedAt.clear();
  lastAlertAt.clear();
}
