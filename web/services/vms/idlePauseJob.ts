import * as Effect from "effect/Effect";
import { VmDatabaseError } from "./errors";
import {
  decideVmIdlePause,
  parseVmIdleProbe,
  vmIdleAutoPauseEnabled,
  vmIdleObservationFromRow,
  vmIdlePauseMinutesFromRow,
  vmIdlePrivateAddressesFromRow,
  vmIdleProbeCommand,
  vmLastApiActivityFromRow,
  VM_IDLE_PROBE_TIMEOUT_MS,
  type VmIdleDecision,
  type VmIdleProbe,
} from "./idlePause";
import { VmProviderGateway } from "./providerGateway";
import { VmRepository, type CloudVmRow } from "./repository";
import { pauseVmRow } from "./workflows";

/** Machines one run probes; the rest wait for the next run (least recently checked first). */
export const VM_IDLE_PAUSE_BATCH_LIMIT = 500;
const PROBE_CONCURRENCY = 8;
/** A run longer than this is close to the cron route's maxDuration (300 s). */
const VM_IDLE_PAUSE_SLOW_RUN_MS = 240_000;
/** The exec's own budget: the guest timeout plus the provider round trip. */
const PROBE_EXEC_BUDGET_MS = VM_IDLE_PROBE_TIMEOUT_MS + 10_000;

export type VmIdlePauseSummary = {
  readonly checked: number;
  readonly paused: number;
  readonly idle: number;
  readonly active: number;
  readonly unknown: number;
  readonly off: number;
  readonly errors: number;
};

type Outcome = "paused" | "idle" | "active" | "unknown" | "off" | "error";

/**
 * The `vm-idle-pause` cron body (services/vms/idlePause.ts): probe each running
 * Freestyle machine, decide, and pause the idle ones through the same pause
 * path the Pause Machine action uses. A machine set to Off, or without a
 * private address, is not probed; with the kill switch off
 * ({@link vmIdleAutoPauseEnabled}, the default) no machine is.
 */
export function enforceVmIdlePause(input: { readonly now?: () => number; readonly limit?: number } = {}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const candidates = repo.idlePauseCandidates;
    if (!candidates || !repo.recordIdleObservation || !repo.recordIdleCheck || !providers.pause) {
      return yield* Effect.fail(new VmDatabaseError({ operation: "idle_pause_candidates", cause: new Error("idle pause is unavailable") }));
    }
    const limit = input.limit ?? VM_IDLE_PAUSE_BATCH_LIMIT;
    const startedAt = Date.now();
    const rows = yield* candidates({ limit });
    const autoPause = vmIdleAutoPauseEnabled();
    const outcomes = yield* Effect.forEach(
      rows,
      (vm) => checkMachine(vm, input.now ?? Date.now, autoPause).pipe(
        Effect.catchAll((error) => Effect.sync((): Outcome => {
          console.error("[VM] idle pause failed", { vmId: vm.id, error });
          return "error";
        })),
      ),
      { concurrency: PROBE_CONCURRENCY },
    );
    warnIfSaturated(rows.length, limit, Date.now() - startedAt);
    const tally = (outcome: Outcome) => outcomes.filter((o) => o === outcome).length;
    return {
      checked: rows.length,
      paused: tally("paused"),
      idle: tally("idle"),
      active: tally("active"),
      unknown: tally("unknown"),
      off: tally("off"),
      errors: tally("error"),
    } satisfies VmIdlePauseSummary;
  });
}

/**
 * A run that hit the cap or ran long: with more running machines than about
 * two runs check, a machine is checked less often than every
 * VM_IDLE_OBSERVATION_MAX_GAP_MS, its idle stretch never carries, and nothing
 * pauses. Logged so the cap gets raised before that goes unnoticed.
 */
function warnIfSaturated(checked: number, limit: number, elapsedMs: number) {
  if (checked < limit && elapsedMs < VM_IDLE_PAUSE_SLOW_RUN_MS) return;
  console.warn("[VM] idle pause run saturated", JSON.stringify({ checked, limit, elapsedMs }));
}

function checkMachine(vm: CloudVmRow, now: () => number, autoPause: boolean) {
  return Effect.gen(function* () {
    const providerVmId = vm.providerVmId;
    if (!providerVmId || vm.status !== "running" || !autoPause) return "off" as const;
    const minutes = vmIdlePauseMinutesFromRow(vm);
    const addresses = vmIdlePrivateAddressesFromRow(vm);
    const probe = minutes > 0 && addresses.length > 0 ? yield* probeMachine(vm, providerVmId, addresses) : null;
    const checkedAt = now();
    const decision = decideVmIdlePause({
      providerVmId,
      minutes,
      probe,
      previous: vmIdleObservationFromRow(vm),
      lastApiActivityAt: vmLastApiActivityFromRow(vm),
      privateAddressKnown: addresses.length > 0,
      now: checkedAt,
    });
    const current = decision.pause ? yield* stillUnchanged(vm, providerVmId) : null;
    if (current) {
      yield* pauseVmRow(current, providerVmId, "idle");
      console.info("[VM] idle pause", JSON.stringify({ vmId: vm.id, minutes, idleSince: decision.observation?.idleSince }));
      return "paused" as const;
    }
    // A pause candidate that lost its row fence must keep the prior idle
    // stretch. Writing a null observation here would restart the timeout on
    // every run when unrelated metadata keeps changing updatedAt.
    if (decision.pause) {
      const repo = yield* VmRepository;
      yield* repo.recordIdleCheck!({ id: vm.id, providerVmId, probedAt: checkedAt });
      return "active" as const;
    }
    // Every checked machine records when it was checked, so the next run starts with the others.
    yield* recordObservation(vm.id, providerVmId, decision.observation, checkedAt);
    return outcomeOf(decision);
  });
}

/**
 * The row re-read just before pausing, or null when it is no longer the same
 * running machine, it changed since the candidate read (an attach or resume
 * bumps updatedAt), or an exec, files or attach call landed since.
 */
function stillUnchanged(vm: CloudVmRow, providerVmId: string) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const current = yield* repo.findUserVm({ userId: vm.userId, billingTeamId: vm.ownerTeamId, providerVmId, provider: vm.provider });
    if (!current || current.id !== vm.id || current.status !== "running" || current.providerVmId !== providerVmId) return null;
    // This branch predates the dedicated idle epoch fence. Keep updatedAt as
    // its lifecycle fence until the complete claim protocol is ported.
    if (current.updatedAt.getTime() !== vm.updatedAt.getTime()) return null;
    if (vmLastApiActivityFromRow(current) !== vmLastApiActivityFromRow(vm)) return null;
    // Addresses are probe inputs; reject a change even if its writer did not
    // advance the lifecycle timestamp.
    if (vmIdlePrivateAddressesFromRow(current).join("\u0000") !== vmIdlePrivateAddressesFromRow(vm).join("\u0000")) return null;
    return current;
  });
}

function recordObservation(id: string, providerVmId: string, observation: VmIdleDecision["observation"], probedAt: number) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    yield* repo.recordIdleObservation!({ id, providerVmId, observation, probedAt });
  });
}

/** The probe's answer; null (unknown) when the exec failed, timed out or printed nothing usable. */
function probeMachine(vm: CloudVmRow, providerVmId: string, addresses: readonly string[]): Effect.Effect<VmIdleProbe | null, never, VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const result = yield* providers.exec(vm.provider, providerVmId, vmIdleProbeCommand(addresses), {
      asRoot: true,
      timeoutMs: VM_IDLE_PROBE_TIMEOUT_MS,
      // Effect.timeout only interrupts the fiber; this makes the gateway abort the provider request too.
      cancelOnInterrupt: true,
    }).pipe(Effect.timeout(PROBE_EXEC_BUDGET_MS));
    return result.exitCode === 0 ? parseVmIdleProbe(result.stdout) : null;
  }).pipe(Effect.catchAll(() => Effect.succeed(null)));
}

function outcomeOf(decision: VmIdleDecision): Exclude<Outcome, "paused" | "error"> {
  if (decision.reason === "off") return "off";
  if (decision.reason.startsWith("unknown:")) return "unknown";
  if (decision.reason.startsWith("active:")) return "active";
  return "idle";
}
