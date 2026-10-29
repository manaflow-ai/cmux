import * as Effect from "effect/Effect";
import { VmDatabaseError } from "./errors";
import {
  decideVmIdlePause,
  parseVmIdleProbe,
  vmIdleEpochFromRow,
  vmIdleObservationFromRow,
  vmIdlePauseClaimFromRow,
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
import {
  isPersonsPauseSince,
  pauseIdleVmRow,
  readIdleProviderState,
  recordIdlePauseAt,
  resumeAfterLostIdlePause,
} from "./workflows";

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
  /** Paused at the provider, but a write landed meanwhile and won (see undoLostPause). */
  readonly aborted: number;
  readonly errors: number;
};

type Outcome = "paused" | "idle" | "active" | "unknown" | "off" | "aborted" | "error";

/**
 * The `vm-idle-pause` cron body (services/vms/idlePause.ts): probe each running
 * Freestyle machine, decide, and pause the idle ones through the same pause
 * path the Pause Machine action uses. A machine set to Off, or without a
 * private address, is not probed.
 */
export function enforceVmIdlePause(input: { readonly now?: () => number; readonly limit?: number } = {}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const candidates = repo.idlePauseCandidates;
    if (!candidates || !repo.recordIdleObservation || !repo.claimIdlePause || !repo.claimIdleResume || !providers.pause) {
      return yield* Effect.fail(new VmDatabaseError({ operation: "idle_pause_candidates", cause: new Error("idle pause is unavailable") }));
    }
    const limit = input.limit ?? VM_IDLE_PAUSE_BATCH_LIMIT;
    const startedAt = Date.now();
    const rows = yield* candidates({ limit });
    const outcomes = yield* Effect.forEach(
      rows,
      (vm) => checkMachine(vm, input.now ?? Date.now).pipe(
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
      aborted: tally("aborted"),
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

function checkMachine(vm: CloudVmRow, now: () => number) {
  return Effect.gen(function* () {
    const providerVmId = vm.providerVmId;
    if (!providerVmId || vm.status === "destroyed") return "off" as const;
    // A claim an earlier run left is resolved first, whatever the row's status now.
    if (vmIdlePauseClaimFromRow(vm) !== null) return yield* settleLeftClaim(vm, providerVmId, now());
    if (vm.status !== "running") return "off" as const;
    const minutes = vmIdlePauseMinutesFromRow(vm);
    const addresses = vmIdlePrivateAddressesFromRow(vm);
    const decide = (probe: VmIdleProbe | null, at: number) => decideVmIdlePause({
      providerVmId,
      minutes,
      probe,
      previous: vmIdleObservationFromRow(vm),
      lastApiActivityAt: vmLastApiActivityFromRow(vm),
      privateAddressKnown: addresses.length > 0,
      now: at,
    });
    const probe = minutes > 0 && addresses.length > 0 ? yield* probeMachine(vm, providerVmId, addresses) : null;
    const checkedAt = now();
    const decision = decide(probe, checkedAt);
    const claimed = decision.pause ? yield* claimPause(vm, providerVmId) : null;
    if (claimed) {
      // Guest activity (typing, a command, ssh, a forwarded port) moves no fence, so look once more
      // just before the provider pause. What starts within the provider call itself is not seen.
      const recheck = decide(yield* probeMachine(vm, providerVmId, addresses), now());
      if (!recheck.pause) {
        console.info("[VM] idle pause skipped: the re-probe was not idle", JSON.stringify({ vmId: vm.id, reason: recheck.reason }));
        yield* recordObservation(vm, providerVmId, null, checkedAt, claimed.epoch);
        return recheck.reason.startsWith("unknown:") ? "unknown" as const : "active" as const;
      }
      const paused = yield* pauseIdleVmRow(claimed.row, providerVmId, claimed.epoch);
      if (!paused) return yield* undoLostPause(vm, providerVmId, claimed.epoch);
      console.info("[VM] idle pause", JSON.stringify({ vmId: vm.id, minutes, reason: decision.reason, idleSince: decision.observation?.idleSince }));
      return "paused" as const;
    }
    // Every checked machine records when it was checked, so the next run starts with the others.
    const observation = decision.pause ? null : decision.observation;
    yield* recordObservation(vm, providerVmId, observation, checkedAt, vmIdleEpochFromRow(vm));
    // A pause skipped because the row moved: something used the machine since the candidate read.
    return decision.pause ? "active" as const : outcomeOf(decision);
  });
}

/**
 * The cron's last check before pausing: the row re-read and claimed at the
 * idle fence it had when the cron read it. Null when it is no longer the same
 * running machine, it changed since the candidate read (an attach or resume
 * bumps updatedAt), or anything moved the fence since (an exec, files or
 * attach call, a setting change, a status write, another run's observation).
 * `epoch` is the claimed fence the pause record must still find.
 */
function claimPause(vm: CloudVmRow, providerVmId: string) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const current = yield* repo.findUserVm({ userId: vm.userId, billingTeamId: vm.ownerTeamId, providerVmId, provider: vm.provider });
    if (!current || current.id !== vm.id || current.status !== "running" || current.providerVmId !== providerVmId) return null;
    if (current.updatedAt.getTime() !== vm.updatedAt.getTime()) return null;
    if (vmLastApiActivityFromRow(current) !== vmLastApiActivityFromRow(vm)) return null;
    if (vmIdleEpochFromRow(current) !== vmIdleEpochFromRow(vm)) return null;
    const epoch = yield* repo.claimIdlePause!({ id: vm.id, providerVmId, epoch: vmIdleEpochFromRow(vm) });
    return epoch === null ? null : { row: current, epoch };
  });
}

/**
 * The provider paused, but the pause record lost the fence the cron claimed
 * (`claimEpoch`): something landed meanwhile. Re-read the row to see what.
 * A person's own pause recorded after the claim is theirs: kept. Replaced or
 * gone: left alone. Anything else (still running after an exec, files or
 * attach call or a switch to Off, or paused by the status reconciler, which
 * states no reason) is resumed through the fenced compensating resume, which
 * itself yields to a person's pause that lands while it runs. Logged with
 * what the cron found.
 */
function undoLostPause(vm: CloudVmRow, providerVmId: string, claimEpoch: number) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const current = yield* repo.findUserVm({ userId: vm.userId, billingTeamId: vm.ownerTeamId, providerVmId, provider: vm.provider });
    if (!current || current.id !== vm.id || current.providerVmId !== providerVmId) {
      console.info("[VM] idle pause lost; the machine was replaced or is gone", JSON.stringify({ vmId: vm.id }));
      return "aborted" as const;
    }
    if (isPersonsPauseSince(current, claimEpoch)) {
      console.info("[VM] idle pause lost to a person's pause; kept", JSON.stringify({ vmId: vm.id }));
      return "aborted" as const;
    }
    const resumed = yield* resumeAfterLostIdlePause(current, providerVmId, claimEpoch).pipe(Effect.either);
    if (resumed._tag === "Left") {
      // A user-open path probes the provider and resumes it (forceProviderProbe).
      console.error("[VM] idle pause lost; resume failed", { vmId: vm.id, status: current.status, error: resumed.left });
      return "error" as const;
    }
    console.info("[VM] idle pause lost to a newer write; compensated", JSON.stringify({ vmId: vm.id, status: current.status, result: resumed.right }));
    return "aborted" as const;
  });
}

/**
 * A claim an earlier run left: its provider pause answered with an error and
 * the read-back could not show a pause, or its compensating resume lost to
 * Off, activity or the status reconciler and has to retry. The row may be
 * running or already marked paused by the reconciler, whose write keeps the
 * claim. Read the provider again. Running: the
 * pause never happened, so clear the claim (the next run checks the machine
 * as usual). Paused, with nothing moved since the claim: record it as the idle
 * pause. Paused with the fence moved: undo it like a lost pause. Unreadable:
 * leave the claim for the next run.
 */
function settleLeftClaim(vm: CloudVmRow, providerVmId: string, checkedAt: number) {
  return Effect.gen(function* () {
    const claim = vmIdlePauseClaimFromRow(vm) ?? 0;
    const state = yield* readIdleProviderState(vm, providerVmId);
    console.info("[VM] idle pause claim left by an earlier run", JSON.stringify({ vmId: vm.id, claim, provider: state ?? "unreadable" }));
    if (state === null) return "unknown" as const;
    if (state === "running") {
      yield* recordObservation(vm, providerVmId, null, checkedAt, vmIdleEpochFromRow(vm));
      return "unknown" as const;
    }
    if (vmIdleEpochFromRow(vm) === claim && (yield* recordIdlePauseAt(vm, providerVmId, claim))) return "paused" as const;
    return yield* undoLostPause(vm, providerVmId, claim);
  });
}

/** Fenced on `epoch` (the idle epoch the cron read, or its claim): a probe that overlapped any newer write stores nothing. */
function recordObservation(vm: CloudVmRow, providerVmId: string, observation: VmIdleDecision["observation"], probedAt: number, epoch: number) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const stored = yield* repo.recordIdleObservation!({ id: vm.id, providerVmId, observation, probedAt, epoch });
    if (!stored) console.info("[VM] idle observation dropped: the row moved during the probe", JSON.stringify({ vmId: vm.id }));
  });
}

/** The probe's answer; null (unknown) when the exec failed, timed out or printed nothing usable. */
function probeMachine(vm: CloudVmRow, providerVmId: string, addresses: readonly string[]): Effect.Effect<VmIdleProbe | null, never, VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const result = yield* providers.exec(vm.provider, providerVmId, vmIdleProbeCommand(addresses), {
      asRoot: true,
      timeoutMs: VM_IDLE_PROBE_TIMEOUT_MS,
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
