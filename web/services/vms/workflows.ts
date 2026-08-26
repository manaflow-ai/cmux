import { createHash, randomUUID } from "node:crypto";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import type {
  AttachEndpoint,
  AttachOptions,
  ExecResult,
  ProviderId,
  SSHEndpoint,
  VMStatus,
} from "./drivers";
import {
  VmBillingGateway,
  VmBillingGatewayLive,
  type BillingCustomerType,
  type VmCreateCreditGrant,
  type VmCreateCreditReservation,
  type VmBillingGatewayShape,
} from "./billingGateway";
import {
  VmBillingError,
  VmAccountDeletionIdentityRevocationError,
  VmCreateFailedError,
  VmCreateInProgressError,
  VmNotFoundError,
  VmProviderOperationError,
  VmSnapshotNotFoundError,
  isVmCreateCreditsInsufficientError,
  isVmLimitExceededError,
  type VmDatabaseError,
  type VmWorkflowError,
} from "./errors";
import { maxActiveVmsForPlan } from "./entitlements";
import { isProviderIdentityNotFoundError, isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, VmProviderGatewayLive, type VmProviderGatewayShape } from "./providerGateway";
import {
  STUCK_PROVISIONING_FAILURE_CODE,
  VmRepository,
  VmRepositoryLive,
  type BeginCreateResult,
  type BeginBaseCreateResult,
  type CloudVmBaseGenerationRow,
  type CloudVmBaseRow,
  type CloudVmAccessLeaseRow,
  type CloudVmCreditReservationStatus,
  type CloudVmSessionRow,
  type CloudVmStatus,
  type CloudVmLeaseKind,
  type CloudVmRow,
  type StaleCreditReservation,
  type VmRepositoryShape,
} from "./repository";
import { bestEffort, reportBestEffortFailure, type BestEffortContext } from "./bestEffort";
import { measureVmEffect, type VmTimingSink } from "./timings";

export type VmEntry = {
  readonly providerVmId: string;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly status: CloudVmStatus;
  readonly createdAt: number;
  readonly displayName: string | null;
};

export type BaseVmEntry = VmEntry & {
  readonly baseId: string;
  readonly baseName: string;
  readonly generation: number;
  readonly retainedProviderVmId: string | null;
};

export type CloudVmSessionEntry = CloudVmSessionRow;

export const VmWorkflowLive = Layer.mergeAll(VmRepositoryLive, VmProviderGatewayLive, VmBillingGatewayLive);

const EXPIRED_IDENTITY_REVOKE_BATCH = 5;
const EXPIRED_IDENTITY_REVOKE_RETRY_BACKOFF_MS = 10 * 60 * 1000;
const IDENTITY_REVOKE_PROVIDER_TIMEOUT = "5 seconds";
const ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT = 8;
const ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH = 8;
const VM_STATUS_RECONCILE_BATCH_LIMIT = 200;
const PREVIEW_ENDPOINT_LEASE_TTL_MS = 12 * 60 * 60 * 1000;
// A provisioning row without a providerVmId older than this is a crashed
// create: no live create waits 30 minutes on a provider call.
const STUCK_PROVISIONING_TTL_MS = 30 * 60 * 1000;
const STUCK_PROVISIONING_SWEEP_LIMIT = 100;
// Reservations are only touched by the cron well after any live create
// finished; the workflow itself resolves them within seconds.
const CREDIT_RESERVATION_RECONCILE_TTL_MS = 15 * 60 * 1000;
const CREDIT_RESERVATION_RECONCILE_LIMIT = 100;

type ExistingVmAccessInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly provider?: ProviderId;
};

export type VmProviderStatusReconcileResult = {
  readonly checked: number;
  readonly updated: number;
  readonly destroyed: number;
  readonly skipped: number;
  readonly skippedNoGetStatus: boolean;
};

/** Result of running a VM workflow: success value, or the typed workflow error. */
export type VmWorkflowResult<A> =
  | { readonly ok: true; readonly value: A }
  | { readonly ok: false; readonly error: VmWorkflowError };

/**
 * The single Effect-to-Promise boundary for VM workflows. Runs the program to
 * an Exit and matches on its Cause: an expected failure comes back as the
 * tagged `VmWorkflowError` in a discriminated union; a defect or interruption
 * (a bug, not a modeled failure) is rethrown raw so the route boundary
 * returns a 500 and captures it. No FiberFailure ever escapes, so callers
 * never need to unwrap Effect runtime internals.
 */
export async function runVmWorkflowExit<A>(
  program: Effect.Effect<A, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway>,
): Promise<VmWorkflowResult<A>> {
  const exit = await Effect.runPromiseExit(program.pipe(Effect.provide(VmWorkflowLive)));
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value };
  const failure = Cause.failureOption(exit.cause);
  if (Option.isSome(failure)) return { ok: false, error: failure.value };
  throw Cause.squash(exit.cause);
}

/**
 * Promise adapter over `runVmWorkflowExit` for route handlers: resolves with
 * the success value, rejects with the tagged `VmWorkflowError` itself.
 */
export async function runVmWorkflow<A>(
  program: Effect.Effect<A, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway>,
): Promise<A> {
  const result = await runVmWorkflowExit(program);
  if (result.ok) return result.value;
  throw result.error;
}

export function listUserVms(userId: string, billingTeamId?: string | null) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const rows = yield* repo.listUserVms(userId, billingTeamId);
    return rows.filter((row) => row.providerVmId).map(vmEntryFromRow);
  });
}

export function getVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    const providerVmId = vm.providerVmId ?? input.providerVmId;
    const getStatus = providers.getStatus;
    if (!getStatus) return vmEntryFromRow(vm);

    const providerStatus = yield* getStatus(vm.provider, providerVmId).pipe(
      Effect.catchAll((err) =>
        isProviderNotFoundError(err)
          ? Effect.succeed("destroyed" as const)
          : Effect.fail(err),
      ),
    );
    if (providerStatus !== "creating") {
      const dbStatus = observedDbStatus(vm, providerStatus);
      if (dbStatus !== vm.status) {
        const didUpdate = yield* repo.markProviderObservedStatus({
          id: vm.id,
          providerVmId,
          status: dbStatus,
        });
        if (didUpdate) return vmEntryFromRow({ ...vm, status: dbStatus, updatedAt: new Date() });
      }
    }
    return vmEntryFromRow(vm);
  });
}

/** Sets or clears the user-facing label on a machine the caller owns. The
 * provider VM id stays the machine's address; this is display-only. */
export function renameVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly displayName: string | null;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireUserVm(input);
    yield* repo.setDisplayName({ id: vm.id, displayName: input.displayName });
    return vmEntryFromRow({ ...vm, displayName: input.displayName, updatedAt: new Date() });
  });
}

export function reconcileVmProviderStatuses(input: {
  readonly limit?: number;
} = {}): Effect.Effect<VmProviderStatusReconcileResult, VmWorkflowError, VmRepository | VmProviderGateway> {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const getStatus = providers.getStatus;
    if (!getStatus) {
      return {
        checked: 0,
        updated: 0,
        destroyed: 0,
        skipped: 0,
        skippedNoGetStatus: true,
      };
    }

    const repo = yield* VmRepository;
    const candidates = yield* repo.reconciliationCandidates({
      limit: boundedVmStatusReconcileLimit(input.limit),
    });
    const outcomes = yield* Effect.forEach(
      candidates,
      (vm) => reconcileObservedProviderStatus(repo, getStatus, vm, "provider_status_cron"),
      { concurrency: 10 },
    );
    let updated = 0;
    let destroyed = 0;
    let skipped = 0;
    for (const outcome of outcomes) {
      if (outcome === "updated") updated += 1;
      else if (outcome === "destroyed") destroyed += 1;
      else if (outcome === "skipped") skipped += 1;
    }
    return {
      checked: candidates.length,
      updated,
      destroyed,
      skipped,
      skippedNoGetStatus: false,
    };
  });
}

export type VmStuckProvisioningSweepResult = {
  readonly swept: number;
  readonly supported: boolean;
};

/**
 * Fails provisioning rows that never received a provider VM id within the TTL.
 * A crash between the provisioning insert and markCreateRunning leaves a row
 * that counts against the active-VM limit forever while being invisible to
 * provider-status reconciliation (it has no providerVmId to poll). Each swept
 * row is reported: the crash may also have leaked an unrecorded provider VM
 * that only the provider console can confirm.
 */
export function sweepStuckProvisioningVms(input: {
  readonly now?: Date;
  readonly olderThanMs?: number;
  readonly limit?: number;
} = {}): Effect.Effect<VmStuckProvisioningSweepResult, VmWorkflowError, VmRepository> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const sweep = repo.sweepStuckProvisioning;
    if (!sweep) return { swept: 0, supported: false };
    const now = input.now ?? new Date();
    const olderThan = new Date(now.getTime() - (input.olderThanMs ?? STUCK_PROVISIONING_TTL_MS));
    const swept = yield* sweep({
      olderThan,
      limit: Math.max(1, Math.min(input.limit ?? STUCK_PROVISIONING_SWEEP_LIMIT, STUCK_PROVISIONING_SWEEP_LIMIT)),
    });
    for (const vm of swept) {
      reportBestEffortFailure(
        "stuck_provisioning_swept",
        new Error("Cloud VM create crashed before provider provisioning was recorded"),
        { vmId: vm.id, provider: vm.provider, ageMs: now.getTime() - vm.createdAt.getTime() },
      );
      yield* repo.recordUsageEvent({
        userId: vm.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: "vm.create.failed",
        provider: vm.provider,
        imageId: vm.imageId,
        metadata: { operation: STUCK_PROVISIONING_FAILURE_CODE, source: "stuck_provisioning_sweeper" },
      }).pipe(bestEffort("usage_event.vm.create.failed", { vmId: vm.id, provider: vm.provider }));
    }
    return { swept: swept.length, supported: true };
  });
}

export type VmCreditReservationReconcileResult = {
  readonly checked: number;
  readonly committed: number;
  readonly refunded: number;
  readonly refundFailed: number;
  readonly abandoned: number;
  readonly skipped: number;
  readonly supported: boolean;
};

/**
 * Resolves credit reservations left behind by a crash. A reservation records
 * the intent (pending) and the fact (debited) of a Stack create-credit debit;
 * when the request dies between the debit and the provider outcome, this cron
 * settles the money: a VM that runs commits the debit, a failed create gets
 * the credit back, and an unknowable pre-debit crash is reported for manual
 * review instead of guessed at. Refunds are claimed with an atomic status
 * transition so the cron and a live request can never both refund one debit.
 */
export function reconcileCreditReservations(input: {
  readonly now?: Date;
  readonly olderThanMs?: number;
  readonly limit?: number;
} = {}): Effect.Effect<VmCreditReservationReconcileResult, VmWorkflowError, VmRepository | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const billing = yield* VmBillingGateway;
    const stale = repo.staleCreditReservations;
    const transition = repo.transitionCreditReservation;
    if (!stale || !transition) {
      return { checked: 0, committed: 0, refunded: 0, refundFailed: 0, abandoned: 0, skipped: 0, supported: false };
    }
    const now = input.now ?? new Date();
    const olderThan = new Date(now.getTime() - (input.olderThanMs ?? CREDIT_RESERVATION_RECONCILE_TTL_MS));
    const rows = yield* stale({
      olderThan,
      limit: Math.max(1, Math.min(input.limit ?? CREDIT_RESERVATION_RECONCILE_LIMIT, CREDIT_RESERVATION_RECONCILE_LIMIT)),
    });

    let committed = 0;
    let refunded = 0;
    let refundFailed = 0;
    let abandoned = 0;
    let skipped = 0;
    for (const row of rows) {
      const outcome = yield* reconcileOneCreditReservation(repo, billing, transition, row);
      if (outcome === "committed") committed += 1;
      else if (outcome === "refunded") refunded += 1;
      else if (outcome === "refund_failed") refundFailed += 1;
      else if (outcome === "abandoned") abandoned += 1;
      else skipped += 1;
    }
    return { checked: rows.length, committed, refunded, refundFailed, abandoned, skipped, supported: true };
  });
}

type CreditReservationReconcileOutcome =
  | "committed"
  | "refunded"
  | "refund_failed"
  | "abandoned"
  | "skipped";

function reconcileOneCreditReservation(
  repo: VmRepositoryShape,
  billing: VmBillingGatewayShape,
  transition: NonNullable<VmRepositoryShape["transitionCreditReservation"]>,
  row: StaleCreditReservation,
): Effect.Effect<CreditReservationReconcileOutcome, never> {
  return Effect.gen(function* () {
    const { reservation, vm } = row;
    const context = {
      reservationId: reservation.id,
      vmId: reservation.vmId,
      itemId: reservation.itemId,
      amount: reservation.amount,
      reservationStatus: reservation.status,
    };
    const tryTransition = (
      from: readonly CloudVmCreditReservationStatus[],
      to: CloudVmCreditReservationStatus,
    ) =>
      transition({ id: reservation.id, from, to }).pipe(
        Effect.catchAll((err) => {
          reportBestEffortFailure("credit_reservation_reconcile_transition", err, context);
          return Effect.succeed(false);
        }),
      );

    if (!vm) {
      // The VM row vanished; the debit outcome cannot be tied to anything.
      yield* tryTransition([reservation.status], "abandoned");
      reportBestEffortFailure(
        "credit_reservation_vm_missing",
        new Error("credit reservation has no VM row; manual review required"),
        context,
      );
      return "abandoned" as const;
    }
    if (vm.status === "running" || vm.status === "paused") {
      // The create ultimately succeeded (the commit write was lost); the
      // debit is legitimately spent.
      const did = yield* tryTransition(["pending", "debited"], "committed");
      return did ? ("committed" as const) : ("skipped" as const);
    }
    if (vm.status === "provisioning") {
      // Still in flight or waiting for the stuck-provisioning sweeper to
      // declare it dead; never refund a create that may still succeed.
      return "skipped" as const;
    }

    // vm.status is failed or destroyed: the create did not produce a usable VM.
    if (reservation.status === "pending" || reservation.status === "refunding") {
      // pending: the crash happened around the debit RPC, so whether money
      // moved is unknowable (Stack debits are not idempotent or queryable
      // per-request). refunding: a refund was in flight with an unknown
      // outcome. Refunding either could hand out a free credit; report for
      // manual review instead.
      const did = yield* tryTransition([reservation.status], "abandoned");
      if (did) {
        reportBestEffortFailure(
          "credit_reservation_uncertain",
          new Error(`credit reservation outcome uncertain (was ${reservation.status}); manual review required`),
          context,
        );
      }
      return did ? ("abandoned" as const) : ("skipped" as const);
    }

    // debited or refund_failed: the debit definitely happened and no usable VM
    // exists. Claim it, then refund.
    const claimed = yield* tryTransition([reservation.status], "refunding");
    if (!claimed) return "skipped" as const;
    const refundOutcome = yield* billing.refundCreate({
      kind: "stack_item",
      itemId: reservation.itemId,
      customerType: reservation.billingCustomerType === "team" ? "team" : "user",
      customerId: reservation.billingCustomerId,
      amount: reservation.amount,
    }).pipe(
      Effect.as("refunded" as const),
      Effect.catchAll((err) => {
        reportBestEffortFailure("billing.refund_create", err, context);
        return Effect.succeed("refund_failed" as const);
      }),
    );
    yield* tryTransition(["refunding"], refundOutcome);
    if (refundOutcome === "refunded") {
      yield* repo.recordUsageEvent({
        userId: vm.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: "vm.create.credit.refunded",
        provider: vm.provider,
        imageId: vm.imageId,
        metadata: {
          itemId: reservation.itemId,
          amount: reservation.amount,
          customerType: reservation.billingCustomerType,
          source: "credit_reservation_reconcile",
        },
      }).pipe(bestEffort("usage_event.vm.create.credit.refunded", context));
    }
    return refundOutcome;
  });
}

/** Stable per-user home volume name; the volume, not the sandbox, is the durable machine. */
export function homeVolumeNameForUser(userId: string): string {
  const digest = createHash("sha256").update(userId).digest("hex").slice(0, 12);
  return `cmux-home-${digest}`;
}

/**
 * Per-machine home volume template. The driver substitutes the generated
 * machine name for `{machine}` once the name is final, so every fresh machine
 * gets its own durable home instead of contending for the single user volume.
 */
export function homeVolumeTemplateForUser(userId: string): string {
  return `${homeVolumeNameForUser(userId)}-{machine}`;
}

export function createVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly idempotencyKey?: string;
  readonly bakedFreestyleSignedAdmin?: boolean;
  /**
   * "Your computer" semantics: mount a per-user persistent volume as the machine's home so
   * the sandbox is disposable compute around durable data. The volume name is derived from
   * the user id, so recreating the machine (TTL expiry, provider loss) finds the same home.
   */
  readonly persistentHome?: boolean;
  /**
   * Fresh-machine semantics: instead of the single shared user volume, mount a
   * volume derived from the machine's own generated name, so any number of
   * machines (up to the plan limit) each keep their own durable home.
   */
  readonly perMachineHome?: boolean;
  /** Runtime memory requested by the caller, in MB. Providers may ignore it. */
  readonly memoryMb?: number;
  readonly timing?: VmTimingSink;
}): Effect.Effect<VmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const create = yield* beginCreateWithLazyProviderRefresh(repo, providers, input);

    if (!create.inserted) {
      const existing = create.vm;
      if (existing.status === "failed") {
        return yield* Effect.fail(
          new VmCreateFailedError({
            idempotencyKey: input.idempotencyKey ?? "",
            code: existing.failureCode,
            message: existing.failureMessage ?? "previous VM create failed",
          }),
        );
      }
      if (!existing.providerVmId) {
        return yield* Effect.fail(
          new VmCreateInProgressError({ idempotencyKey: input.idempotencyKey ?? "" }),
        );
      }
      return vmEntryFromRow(existing);
    }

    const credit = yield* reserveCreateCredit(billing, repo, input, create.vm);
    yield* recordCreateRequestedEvents(repo, input, create.vm, credit.reservation);

    const running = yield* compensated({
      createHandle: measureVmEffect(
        input.timing,
        "provider_create",
        providers.create(input.provider, {
          image: input.image,
          providerMetadata: create.vm.providerMetadata,
          bakedFreestyleSignedAdmin: input.bakedFreestyleSignedAdmin,
          homeVolume: input.perMachineHome
            ? homeVolumeTemplateForUser(input.userId)
            : input.persistentHome
              ? homeVolumeNameForUser(input.userId)
              : undefined,
          memoryMb: input.memoryMb,
        }),
      ),
      finalize: (handle) =>
        measureVmEffect(
          input.timing,
          "mark_running",
          repo.markCreateRunning({
            id: create.vm.id,
            providerVmId: handle.providerVmId,
            image: handle.image,
            imageVersion: input.imageVersion ?? null,
            providerMetadata: handle.providerMetadata ?? create.vm.providerMetadata,
          }),
        ),
      destroyOrphan: (handle) => providers.destroy(input.provider, handle.providerVmId),
      refund: refundCredit(billing, repo, create.vm, credit),
      markFailed: (failure) =>
        repo.markCreateFailed({ id: create.vm.id, code: failure.code, message: failure.message }),
      createFailureEvent: (failure) =>
        recordCreateFailureEvent(repo, input, create.vm, failure.code, failure.message),
      finalizeFailureMessage: "Cloud VM state update failed.",
      context: { vmId: create.vm.id, provider: input.provider },
    });

    yield* commitCreditReservation(repo, credit, { vmId: running.id, provider: input.provider });
    yield* recordCreateSuccessEvents(repo, input, running);

    return vmEntryFromRow(running);
  });
}

export function openBaseVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly baseName?: string;
  readonly bakedFreestyleSignedAdmin?: boolean;
  readonly timing?: VmTimingSink;
}): Effect.Effect<BaseVmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const create = yield* measureVmEffect(
      input.timing,
      "begin_base_open",
      repo.beginBaseOpen(input),
    );
    return yield* finishBaseCreate(repo, providers, billing, input, create);
  });
}

export function resetBaseVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion?: string | null;
  readonly baseName?: string;
  readonly reason?: string | null;
  readonly bakedFreestyleSignedAdmin?: boolean;
  readonly timing?: VmTimingSink;
}): Effect.Effect<BaseVmEntry, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway> {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const create = yield* measureVmEffect(
      input.timing,
      "begin_base_reset",
      repo.beginBaseReset(input),
    );
    return yield* finishBaseCreate(repo, providers, billing, input, create);
  });
}

function finishBaseCreate(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  billing: VmBillingGatewayShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly maxActiveVms: number;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly baseName?: string;
    readonly bakedFreestyleSignedAdmin?: boolean;
    readonly timing?: VmTimingSink;
  },
  create: BeginBaseCreateResult,
): Effect.Effect<BaseVmEntry, VmWorkflowError, never> {
  return Effect.gen(function* () {
    if (create.kind === "existing") {
      const existing = create.vm;
      if (existing.status === "failed") {
        return yield* Effect.fail(
          new VmCreateFailedError({
            idempotencyKey: existing.idempotencyKey ?? "",
            code: existing.failureCode ?? null,
            message: existing.failureMessage ?? "previous Base create failed",
          }),
        );
      }
      if (!existing.providerVmId) {
        return yield* Effect.fail(
          new VmCreateInProgressError({ idempotencyKey: existing.idempotencyKey ?? "" }),
        );
      }
      const replacement = yield* reopenBaseIfProviderDeleted(
        repo,
        providers,
        input,
        create,
        existing,
        existing.providerVmId,
      );
      if (replacement) {
        return yield* finishBaseCreate(repo, providers, billing, input, replacement);
      }
      return baseVmEntryFromRows(create.base, create.generation, existing, null);
    }

    const idempotencyKey = create.vm.idempotencyKey ?? undefined;
    const credit = yield* reserveCreateCredit(billing, repo, {
      ...input,
      idempotencyKey,
    }, create.vm);
    yield* recordCreateRequestedEvents(repo, {
      ...input,
      idempotencyKey,
    }, create.vm, credit.reservation);

    const running = yield* compensated({
      createHandle: measureVmEffect(
        input.timing,
        "provider_create",
        providers.create(input.provider, {
          image: input.image,
          providerMetadata: create.vm.providerMetadata,
          bakedFreestyleSignedAdmin: input.bakedFreestyleSignedAdmin,
        }),
      ),
      finalize: (handle) =>
        measureVmEffect(
          input.timing,
          "mark_base_running",
          repo.markBaseCreateRunning({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            providerVmId: handle.providerVmId,
            image: handle.image,
            imageVersion: input.imageVersion ?? null,
            providerMetadata: handle.providerMetadata ?? create.vm.providerMetadata,
            userId: input.userId,
          }),
        ),
      destroyOrphan: (handle) => providers.destroy(input.provider, handle.providerVmId),
      refund: refundCredit(billing, repo, create.vm, credit),
      markFailed: (failure) =>
        repo.markBaseCreateFailed({
          baseId: create.base.id,
          generation: create.generation.generation,
          vmId: create.vm.id,
          userId: input.userId,
          code: failure.code,
          message: failure.message,
        }),
      createFailureEvent: (failure) =>
        repo.recordUsageEvent({
          userId: input.userId,
          billingTeamId: input.billingTeamId,
          billingPlanId: input.billingPlanId,
          vmId: create.vm.id,
          eventType: "vm.base.create.failed",
          provider: input.provider,
          imageId: input.image,
          metadata: { operation: failure.code, message: failure.message, baseName: input.baseName ?? "base" },
        }),
      finalizeFailureEvent: (failure) =>
        recordCreateFailureEvent(
          repo,
          {
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            provider: input.provider,
            image: input.image,
          },
          create.vm,
          failure.code,
          failure.message,
        ),
      finalizeFailureMessage: "Cloud VM Base state update failed.",
      context: { vmId: create.vm.id, provider: input.provider },
    });

    yield* commitCreditReservation(repo, credit, { vmId: running.id, provider: input.provider });
    yield* recordCreateSuccessEvents(repo, { ...input, idempotencyKey }, running);
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      vmId: running.id,
      eventType: create.previousVm ? "vm.base.reset" : "vm.base.opened",
      provider: input.provider,
      imageId: input.image,
      metadata: {
        baseName: input.baseName ?? "base",
        generation: create.generation.generation,
        retainedProviderVmId: create.previousVm?.providerVmId ?? null,
      },
    }).pipe(bestEffort("usage_event.vm.base.lifecycle", { vmId: running.id, provider: input.provider }));

    return baseVmEntryFromRows(
      create.base,
      create.generation,
      running,
      create.previousVm?.providerVmId ?? null,
    );
  });
}

function reopenBaseIfProviderDeleted(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: Parameters<VmRepositoryShape["beginBaseOpen"]>[0] & { readonly timing?: VmTimingSink },
  create: Extract<BeginBaseCreateResult, { readonly kind: "existing" }>,
  existing: CloudVmRow,
  providerVmId: string,
): Effect.Effect<BeginBaseCreateResult | null, VmWorkflowError, never> {
  const getStatus = providers.getStatus;
  if (!getStatus) return Effect.succeed(null);
  return getStatus(existing.provider, providerVmId).pipe(
    Effect.as(null),
    Effect.catchAll((err) =>
      isProviderNotFoundError(err)
        ? Effect.gen(function* () {
          const markedDestroyed = yield* repo.markProviderObservedStatus({
            id: existing.id,
            providerVmId,
            status: "destroyed",
          });
          if (!markedDestroyed) {
            return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
          }
          yield* repo.recordUsageEvent({
            userId: existing.userId,
            billingTeamId: existing.billingTeamId,
            billingPlanId: existing.billingPlanId,
            vmId: existing.id,
            eventType: "vm.destroyed",
            provider: existing.provider,
            imageId: existing.imageId,
            metadata: {
              source: "base_open_provider_missing",
              baseName: input.baseName ?? "base",
              generation: create.generation.generation,
            },
          }).pipe(bestEffort("usage_event.vm.destroyed", { vmId: existing.id, provider: existing.provider }));
          return yield* measureVmEffect(
            input.timing,
            "begin_base_open",
            repo.beginBaseOpen(input),
          );
        })
        : Effect.succeed(null)
    ),
  );
}

export function snapshotVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly name?: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    const snapshot = yield* (providers.snapshot
      ? providers.snapshot(vm.provider, vm.providerVmId ?? input.providerVmId, input.name)
      : Effect.fail(new VmProviderOperationError({
        provider: vm.provider,
        operation: "snapshot",
        cause: new Error("Cloud VM snapshots are not supported by this provider gateway"),
      })));
    yield* repo.recordUsageEvent({
      userId: vm.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.snapshot.created",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { snapshotId: snapshot.id, named: !!input.name, name: input.name ?? null },
    });
    return snapshot;
  });
}

export function restoreVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly provider: ProviderId;
  readonly snapshotId: string;
  readonly idempotencyKey?: string;
  readonly timing?: VmTimingSink;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const hasSnapshot = yield* repo.hasOwnedSnapshot({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      provider: input.provider,
      snapshotId: input.snapshotId,
    });
    if (!hasSnapshot) {
      return yield* Effect.fail(new VmSnapshotNotFoundError({ snapshotId: input.snapshotId }));
    }
    return yield* createVm({
      userId: input.userId,
      billingCustomerType: input.billingCustomerType,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      maxActiveVms: input.maxActiveVms,
      provider: input.provider,
      image: input.snapshotId,
      imageVersion: null,
      idempotencyKey: input.idempotencyKey,
      bakedFreestyleSignedAdmin: false,
      timing: input.timing,
    });
  });
}

export function forkVm(input: {
  readonly userId: string;
  readonly billingCustomerType: BillingCustomerType;
  readonly billingTeamId: string;
  readonly teamIds?: readonly string[];
  readonly billingPlanId: string;
  readonly maxActiveVms: number;
  readonly providerVmId: string;
  readonly name?: string;
  readonly idempotencyKey?: string;
  readonly timing?: VmTimingSink;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const source = yield* requireUserVm(input);
    yield* preflightResumeIfSuspended(repo, providers, source, input.providerVmId, "fork");

    if (source.provider === "freestyle" && providers.fork) {
      const create = yield* beginCreateWithLazyProviderRefresh(repo, providers, {
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: source.provider,
        image: source.imageId,
        imageVersion: source.imageVersion,
        maxActiveVms: input.maxActiveVms,
        idempotencyKey: input.idempotencyKey,
        timing: input.timing,
      });

      if (!create.inserted) {
        const existing = create.vm;
        if (existing.status === "failed") {
          return yield* Effect.fail(
            new VmCreateFailedError({
              idempotencyKey: input.idempotencyKey ?? "",
              code: existing.failureCode ?? null,
              message: existing.failureMessage ?? "previous VM fork failed",
            }),
          );
        }
        if (!existing.providerVmId) {
          return yield* Effect.fail(
            new VmCreateInProgressError({ idempotencyKey: input.idempotencyKey ?? "" }),
          );
        }
        return { snapshot: null, fork: vmEntryFromRow(existing) };
      }

      const credit = yield* reserveCreateCredit(billing, repo, {
        userId: input.userId,
        billingCustomerType: input.billingCustomerType,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: source.provider,
        image: source.imageId,
        imageVersion: source.imageVersion,
        idempotencyKey: input.idempotencyKey,
        timing: input.timing,
      }, create.vm);
      yield* recordCreateRequestedEvents(repo, {
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: source.provider,
        image: source.imageId,
        imageVersion: source.imageVersion,
        idempotencyKey: input.idempotencyKey,
        timing: input.timing,
      }, create.vm, credit.reservation);

      const running = yield* compensated({
        createHandle: measureVmEffect(
          input.timing,
          "provider_create",
          providers.fork(source.provider, source.providerVmId ?? input.providerVmId),
        ),
        finalize: (handle) =>
          measureVmEffect(
            input.timing,
            "mark_running",
            repo.markCreateRunning({
              id: create.vm.id,
              providerVmId: handle.providerVmId,
              image: source.imageId,
              imageVersion: source.imageVersion,
              providerMetadata: handle.providerMetadata ?? source.providerMetadata,
            }),
          ),
        destroyOrphan: (handle) => providers.destroy(source.provider, handle.providerVmId),
        refund: refundCredit(billing, repo, create.vm, credit),
        markFailed: (failure) =>
          repo.markCreateFailed({ id: create.vm.id, code: failure.code, message: failure.message }),
        createFailureEvent: (failure) =>
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.create.failed",
            provider: source.provider,
            imageId: source.imageId,
            metadata: { operation: failure.code, message: failure.message, sourceProviderVmId: source.providerVmId },
          }),
        finalizeFailureEvent: (failure) =>
          recordCreateFailureEvent(
            repo,
            {
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              provider: source.provider,
              image: source.imageId,
            },
            create.vm,
            failure.code,
            failure.message,
          ),
        finalizeFailureMessage: "Cloud VM fork state update failed.",
        context: { vmId: create.vm.id, provider: source.provider },
      });

      yield* commitCreditReservation(repo, credit, { vmId: running.id, provider: source.provider });
      yield* recordCreateSuccessEvents(repo, input, running);
      const fork = vmEntryFromRow(running);
      yield* repo.recordUsageEvent({
        userId: source.userId,
        billingTeamId: source.billingTeamId,
        billingPlanId: source.billingPlanId,
        vmId: source.id,
        eventType: "vm.forked",
        provider: source.provider,
        imageId: source.imageId,
        metadata: {
          native: true,
          sourceProviderVmId: source.providerVmId,
          forkProviderVmId: fork.providerVmId,
          idempotencyKeySet: !!input.idempotencyKey,
        },
      }).pipe(bestEffort("usage_event.vm.forked", { vmId: source.id, provider: source.provider }));
      return { snapshot: null, fork };
    }

    const snapshot = yield* snapshotVm({
      userId: input.userId,
      teamIds: input.teamIds,
      billingTeamId: source.billingTeamId,
      providerVmId: input.providerVmId,
      name: input.name,
    });
    const fork = yield* createVm({
      userId: input.userId,
      billingCustomerType: input.billingCustomerType,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      maxActiveVms: input.maxActiveVms,
      provider: source.provider,
      image: snapshot.id,
      imageVersion: null,
      idempotencyKey: input.idempotencyKey,
      timing: input.timing,
    });
    yield* repo.recordUsageEvent({
      userId: source.userId,
      billingTeamId: source.billingTeamId,
      billingPlanId: source.billingPlanId,
      vmId: source.id,
      eventType: "vm.forked",
      provider: source.provider,
      imageId: source.imageId,
      metadata: {
        snapshotId: snapshot.id,
        forkProviderVmId: fork.providerVmId,
        idempotencyKeySet: !!input.idempotencyKey,
      },
    }).pipe(bestEffort("usage_event.vm.forked", { vmId: source.id, provider: source.provider }));
    return { snapshot, fork };
  });
}

function beginCreateWithLazyProviderRefresh(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly timing?: VmTimingSink;
  } & Parameters<VmRepositoryShape["beginCreate"]>[0],
): Effect.Effect<BeginCreateResult, VmWorkflowError, never> {
  return measureVmEffect(input.timing, "begin_create", repo.beginCreate(input)).pipe(
    Effect.catchAll((err) => {
      if (!isVmLimitExceededError(err)) return Effect.fail(err);
      return Effect.gen(function* () {
        yield* measureVmEffect(
          input.timing,
          "limit_reconcile",
          refreshActiveLimitProviderStatuses(repo, providers, input),
        ).pipe(bestEffort("active_limit_provider_refresh", { userId: input.userId, billingTeamId: input.billingTeamId }));
        return yield* measureVmEffect(input.timing, "begin_create", repo.beginCreate(input));
      });
    }),
  );
}

function refreshActiveLimitProviderStatuses(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
  },
): Effect.Effect<void, VmDatabaseError, never> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    if (!getStatus) return;

    const candidates = yield* repo.activeLimitCandidates({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
    });
    yield* Effect.forEach(candidates, (vm) => {
      const providerVmId = vm.providerVmId;
      if (vm.provider !== "freestyle" || !providerVmId) return Effect.void;
      return reconcileObservedProviderStatus(repo, getStatus, vm, "provider_status_refresh").pipe(
        Effect.asVoid,
      );
    }, { concurrency: "unbounded", discard: true });
  });
}

function dbStatusFromProviderStatus(status: "running" | "paused" | "destroyed"): CloudVmStatus {
  return status;
}

// A provider 404 on a machine with a persistent home volume means the compute is gone but
// the machine is still resurrectable on the next attach — it is asleep, not destroyed.
// Only machines without a durable home actually die with their sandbox.
function observedDbStatus(
  vm: Pick<CloudVmRow, "providerMetadata">,
  providerStatus: "running" | "paused" | "destroyed",
): CloudVmStatus {
  if (providerStatus === "destroyed") {
    const homeVolume = vm.providerMetadata?.["homeVolume"];
    if (typeof homeVolume === "string" && homeVolume.length > 0) return "paused";
  }
  return dbStatusFromProviderStatus(providerStatus);
}

type ProviderStatusReconcileOutcome = "updated" | "destroyed" | "unchanged" | "skipped";

function reconcileObservedProviderStatus(
  repo: VmRepositoryShape,
  getStatus: NonNullable<VmProviderGatewayShape["getStatus"]>,
  vm: CloudVmRow,
  usageEventSource: string,
): Effect.Effect<ProviderStatusReconcileOutcome, never> {
  return Effect.gen(function* () {
    const providerVmId = vm.providerVmId;
    if (!providerVmId) return "skipped" as const;
    const providerStatus = yield* getStatus(vm.provider, providerVmId).pipe(
      Effect.catchAll((err) =>
        isProviderNotFoundError(err)
          ? Effect.succeed("destroyed" as const)
          : Effect.succeed(null),
      ),
    );
    if (!providerStatus || providerStatus === "creating") return "skipped" as const;
    const dbStatus = observedDbStatus(vm, providerStatus);
    if (dbStatus === vm.status) return "unchanged" as const;
    const didUpdate = yield* repo.markProviderObservedStatus({
      id: vm.id,
      providerVmId,
      status: dbStatus,
    }).pipe(Effect.catchAll(() => Effect.succeed(false)));
    if (!didUpdate) return "skipped" as const;
    if (dbStatus === "destroyed") {
      yield* repo.recordUsageEvent({
        userId: vm.userId,
        billingTeamId: vm.billingTeamId,
        billingPlanId: vm.billingPlanId,
        vmId: vm.id,
        eventType: "vm.destroyed",
        provider: vm.provider,
        imageId: vm.imageId,
        metadata: { source: usageEventSource },
      }).pipe(bestEffort("usage_event.vm.destroyed", { vmId: vm.id, provider: vm.provider }));
      return "destroyed" as const;
    }
    return "updated" as const;
  });
}

function boundedVmStatusReconcileLimit(limit: number | undefined): number {
  if (limit === undefined || !Number.isFinite(limit)) return VM_STATUS_RECONCILE_BATCH_LIMIT;
  return Math.max(1, Math.min(VM_STATUS_RECONCILE_BATCH_LIMIT, Math.trunc(limit)));
}

const RESUME_STATUS_PROBE_TIMEOUT = "5 seconds";
const RESUME_SETTLE_ATTEMPTS = 10;
const RESUME_SETTLE_INTERVAL = "1 second";
type VmResumeSource = "exec" | "attach" | "ssh" | "fork" | "open_port";

// resume() can legitimately return a not-yet-running handle (Freestyle maps a
// post-start "starting" state to "creating"), so poll briefly until the VM is
// observably running; never record a running transition for a VM that has not
// settled, and fail without a durable write if it does not.
function waitForRunningStatus(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<boolean, never> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    if (!getStatus) return true;
    for (let attempt = 0; attempt < RESUME_SETTLE_ATTEMPTS; attempt += 1) {
      const status = yield* getStatus(vm.provider, providerVmId).pipe(
        Effect.timeoutFail({
          duration: RESUME_STATUS_PROBE_TIMEOUT,
          onTimeout: () =>
            new VmProviderOperationError({
              provider: vm.provider,
              operation: `getStatus(${providerVmId})`,
              cause: new Error("status probe timed out"),
            }),
        }),
        Effect.catchAll(() => Effect.succeed(null as VMStatus | null)),
      );
      if (status === "running") return true;
      yield* Effect.sleep(RESUME_SETTLE_INTERVAL);
    }
    return false;
  });
}

function bestEffortPause(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<void, never> {
  const pause = providers.pause;
  if (!pause) return Effect.void;
  return pause(vm.provider, providerVmId).pipe(
    bestEffort("provider_pause_rollback", { vmId: vm.id, provider: vm.provider }),
  );
}

function resumeUntilRunning(
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<void, VmWorkflowError> {
  return Effect.gen(function* () {
    const resume = providers.resume;
    if (!resume) return;
    const handle = yield* resume(vm.provider, providerVmId);
    if (handle.status === "running") return;
    const settled = yield* waitForRunningStatus(providers, vm, providerVmId);
    if (settled) return;
    // The provider start already happened; roll back so a started-but-
    // unrecorded VM is never left running outside Postgres accounting.
    yield* bestEffortPause(providers, vm, providerVmId);
    return yield* Effect.fail(
      new VmProviderOperationError({
        provider: vm.provider,
        operation: `resume(${providerVmId})`,
        cause: new Error("VM did not reach running after resume"),
      }),
    );
  });
}

function reservePausedResumeIfTeam(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  providerVmId: string,
): Effect.Effect<boolean, VmWorkflowError> {
  if (!vm.billingTeamId) return Effect.succeed(false);
  return Effect.gen(function* () {
    const reserved = yield* repo.reservePausedResume({
      id: vm.id,
      userId: vm.userId,
      billingTeamId: vm.billingTeamId,
      providerVmId,
      maxActiveVms: maxActiveVmsForPlan(vm.billingPlanId),
    });
    if (!reserved) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
    }
    if (reserved.status !== "running") {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: `reservePausedResume(${providerVmId})`,
          cause: new Error(`VM resume reservation returned ${reserved.status}`),
        }),
      );
    }
    return vm.status === "paused";
  });
}

function rollbackPausedResumeReservation(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  providerVmId: string,
  reserved: boolean,
): Effect.Effect<void, never> {
  if (!reserved) return Effect.void;
  return repo.markProviderObservedStatus({
    id: vm.id,
    providerVmId,
    status: "paused",
  }).pipe(bestEffort("resume_reservation_rollback", { vmId: vm.id, provider: vm.provider }));
}

function recordResumeUsageEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  resumeSource: VmResumeSource,
): Effect.Effect<void, never> {
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType: "vm.resumed",
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: { source: resumeSource },
  }).pipe(bestEffort("usage_event.vm.resumed", { vmId: vm.id, provider: vm.provider }));
}

// Active-limit note: the control-plane-owned paused-row resume path is
// limit-gated for billing teams by reservePausedResume before the provider
// resume starts. Freestyle can still resume a VM outside the control plane
// (for example through its SSH gateway); those already-running observations
// are reconciled durably here, and beginCreate re-counts provider-running VMs
// before allocating another active slot.
function preflightResumeIfSuspended(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  resumeSource: VmResumeSource,
): Effect.Effect<boolean, VmWorkflowError> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    const resume = providers.resume;
    if (!getStatus || !resume) return false;

    const status = yield* getStatus(vm.provider, providerVmId).pipe(
      Effect.timeoutFail({
        duration: RESUME_STATUS_PROBE_TIMEOUT,
        onTimeout: () =>
          new VmProviderOperationError({
            provider: vm.provider,
            operation: `getStatus(${providerVmId})`,
            cause: new Error("status probe timed out"),
          }),
      }),
      Effect.catchAll((err) =>
        // Fail closed when the row durably says paused and the probe cannot
        // prove otherwise: minting endpoints against a suspended VM would
        // hand out unusable credentials and record leases/usage for it.
        vm.status === "paused"
          ? Effect.fail(err)
          : Effect.succeed(null as VMStatus | null),
      ),
    );
    if (status === "creating") {
      // Another caller's resume is in flight; wait for it rather than
      // minting endpoints or running commands against a not-yet-ready VM.
      const settled = yield* waitForRunningStatus(providers, vm, providerVmId);
      if (!settled) {
        return yield* Effect.fail(
          new VmProviderOperationError({
            provider: vm.provider,
            operation: `getStatus(${providerVmId})`,
            cause: new Error("VM stayed in a resuming state"),
          }),
        );
      }
      // Persist the observed running state ourselves in case the resuming
      // caller dies before its own durable write. An already-running row
      // still matches the update (returns true); false means the row was
      // destroyed or replaced concurrently, so fail closed. No pause
      // rollback here: the caller that started the VM owns compensation.
      const recorded = yield* repo.markProviderObservedStatus({
        id: vm.id,
        providerVmId,
        status: "running",
      });
      if (!recorded) {
        return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
      }
      return false;
    }
    if (status === "running") {
      // Freestyle's SSH gateway can resume a VM entirely outside the control
      // plane; if the durable row still says paused, record the observed
      // running state so active-limit reconciliation can see the VM.
      if (vm.status === "paused") {
        const recorded = yield* repo.markProviderObservedStatus({
          id: vm.id,
          providerVmId,
          status: "running",
        });
        if (!recorded) {
          return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
        }
      }
      return false;
    }
    if (status !== "paused") return false;

    const reserved = yield* reservePausedResumeIfTeam(repo, vm, providerVmId);
    yield* resumeUntilRunning(providers, vm, providerVmId).pipe(
      Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
    );
    yield* recordRunningTransition(
      repo,
      providers,
      vm,
      providerVmId,
      new VmNotFoundError({ vmId: providerVmId }),
    ).pipe(
      Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
    );
    if (reserved) yield* recordResumeUsageEvent(repo, vm, resumeSource);
    return true;
  });
}

function withResumeOnSuspendedAfterFailure<A>(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  resumeSource: VmResumeSource,
  op: Effect.Effect<A, VmWorkflowError>,
): Effect.Effect<A, VmWorkflowError> {
  return op.pipe(
    Effect.catchAll((originalError) => {
      const getStatus = providers.getStatus;
      const resume = providers.resume;
      if (!getStatus || !resume) return Effect.fail(originalError);

      return Effect.gen(function* () {
        const status = yield* getStatus(vm.provider, providerVmId).pipe(
          Effect.catchAll(() => Effect.succeed(null as VMStatus | null)),
        );
        if (status === "creating") {
          const settled = yield* waitForRunningStatus(providers, vm, providerVmId);
          if (!settled) return yield* Effect.fail(originalError);
          const recorded = yield* repo.markProviderObservedStatus({
            id: vm.id,
            providerVmId,
            status: "running",
          }).pipe(Effect.catchAll(() => Effect.succeed(false)));
          if (!recorded) return yield* Effect.fail(originalError);
          return yield* op;
        }
        if (status !== "paused") {
          return yield* Effect.fail(originalError);
        }

        const reserved = yield* reservePausedResumeIfTeam(repo, vm, providerVmId);
        yield* resumeUntilRunning(providers, vm, providerVmId).pipe(
          Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
          Effect.catchAll(() => Effect.fail(originalError)),
        );
        yield* recordRunningTransition(repo, providers, vm, providerVmId, originalError).pipe(
          Effect.tapError(() => rollbackPausedResumeReservation(repo, vm, providerVmId, reserved)),
        );
        if (reserved) yield* recordResumeUsageEvent(repo, vm, resumeSource);
        return yield* op;
      });
    }),
  );
}

// After a successful provider resume, Postgres must record the running
// transition before the workflow proceeds. When the write fails (or the row
// was destroyed concurrently), roll the provider back to the durable state
// with a best-effort pause so a running VM is never left invisible to
// active-limit accounting; Freestyle's idle auto-suspend (~10s) is the
// backstop if the pause itself fails.
function recordRunningTransition<E extends VmWorkflowError>(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  staleRowError: E,
): Effect.Effect<void, VmDatabaseError | E> {
  const rollbackPause = (): Effect.Effect<void, never> => {
    const pause = providers.pause;
    if (!pause) return Effect.void;
    return pause(vm.provider, providerVmId).pipe(
      bestEffort("provider_pause_rollback", { vmId: vm.id, provider: vm.provider }),
    );
  };
  return Effect.gen(function* () {
    const didUpdate = yield* repo.markProviderObservedStatus({
      id: vm.id,
      providerVmId,
      status: "running",
    }).pipe(
      Effect.tapError(() => rollbackPause()),
    );
    if (!didUpdate) {
      yield* rollbackPause();
      return yield* Effect.fail(staleRowError);
    }
  });
}

export function destroyVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly provider?: ProviderId;
  readonly afterProviderDestroy?: () => void;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);

    yield* revokeActiveIdentities(vm, { failOnCleanupError: true });
    yield* providers.destroy(vm.provider, vm.providerVmId ?? input.providerVmId).pipe(
      Effect.catchAll((err) => {
        if (isProviderNotFoundError(err.cause)) return Effect.void;
        return Effect.fail(err);
      }),
    );
    yield* Effect.sync(() => {
      input.afterProviderDestroy?.();
    });
    yield* repo.markDestroyed(vm.id);
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.destroyed",
      provider: vm.provider,
      imageId: vm.imageId,
    }).pipe(bestEffort("usage_event.vm.destroyed", { vmId: vm.id, provider: vm.provider }));
  });
}

export function revokeExpiredIdentityLeases(input: {
  readonly now?: Date;
  readonly limit?: number;
} = {}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const expiredIdentityLeases = repo.expiredIdentityLeases;
    if (!expiredIdentityLeases) return 0;
    const now = input.now ?? new Date();
    const leases = yield* expiredIdentityLeases({
      now,
      limit: input.limit ?? EXPIRED_IDENTITY_REVOKE_BATCH,
    });
    const revokedIds: string[] = [];
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle;
      if (!identityHandle) continue;
      const retryAfter = new Date(now.getTime() + EXPIRED_IDENTITY_REVOKE_RETRY_BACKOFF_MS);
      yield* (repo.markLeaseRevocationRetry?.({
        id: lease.id,
        retryAfter,
        error: "revoke pending",
      }) ?? Effect.void).pipe(bestEffort("lease_revocation_retry_mark", { provider: lease.provider }));
      const revoked = yield* revokeSSHIdentityForCleanup(providers, lease.provider, identityHandle).pipe(
        Effect.as(true),
        Effect.catchAll((err) => {
          if (isProviderIdentityNotFoundError(err.cause)) return Effect.succeed(true);
          return Effect.succeed(false);
        }),
      );
      if (revoked) revokedIds.push(lease.id);
    }
    yield* repo.markLeasesRevoked(revokedIds);
    return revokedIds.length;
  });
}

export function revokeUserIdentityLeasesForAccountDeletion(
  userId: string,
  input: {
    readonly limit?: number;
    readonly afterBatch?: () => Effect.Effect<void, VmWorkflowError>;
  } = {},
) {
  const limit = boundedAccountDeletionIdentityRevokeLimit(input.limit);
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    let revokedCount = 0;
    for (;;) {
      const leases = yield* repo.accountDeletionIdentityLeases({ userId, limit });
      if (leases.length === 0) return revokedCount;

      const revokedIds: string[] = [];
      for (const lease of leases) {
        const identityHandle = lease.providerIdentityHandle;
        if (!identityHandle) {
          revokedIds.push(lease.id);
          continue;
        }
        const revoked = yield* revokeSSHIdentityForCleanup(providers, lease.provider, identityHandle).pipe(
          Effect.as(true),
          Effect.catchAll((err) => {
            if (isProviderIdentityNotFoundError(err.cause)) return Effect.succeed(true);
            return repo.markLeasesRevoked(revokedIds).pipe(
              bestEffort("account_deletion.mark_leases_revoked", { userId }),
              Effect.andThen(Effect.fail(new VmAccountDeletionIdentityRevocationError({ cause: err }))),
            );
          }),
        );
        if (revoked) revokedIds.push(lease.id);
      }

      yield* markAccountDeletionLeasesRevoked(repo, revokedIds);
      revokedCount += revokedIds.length;
      if (input.afterBatch) yield* input.afterBatch();
      if (leases.length < limit) return revokedCount;
    }
  });
}

function markAccountDeletionLeasesRevoked(
  repo: VmRepositoryShape,
  revokedIds: readonly string[],
): Effect.Effect<void, VmWorkflowError> {
  return repo.markLeasesRevoked(revokedIds).pipe(
    Effect.catchAll((err): Effect.Effect<never, VmWorkflowError> =>
      Effect.fail(
        revokedIds.length > 0
          ? new VmAccountDeletionIdentityRevocationError({ cause: err })
          : err,
      )
    ),
  );
}

function boundedAccountDeletionIdentityRevokeLimit(limit: number | undefined): number {
  if (typeof limit !== "number" || !Number.isFinite(limit)) return ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH;
  return Math.max(1, Math.min(Math.floor(limit), ACCOUNT_DELETION_IDENTITY_REVOKE_BATCH));
}

export function execVm(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly command: string;
  readonly timeoutMs: number;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "exec",
    );
    const result = yield* providers.exec(vm.provider, input.providerVmId, input.command, {
      timeoutMs: input.timeoutMs,
    });
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.exec",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { commandLength: input.command.length, exitCode: result.exitCode },
    }).pipe(bestEffort("usage_event.vm.exec", { vmId: vm.id, provider: vm.provider }));
    return result satisfies ExecResult;
  });
}

export function getVmStats(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    // No resume preflight on purpose: a reading must never wake a sleeping machine.
    if (!providers.getStats) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "getStats",
          cause: new Error("machine stats are not supported by this deployment"),
        }),
      );
    }
    return yield* providers.getStats(vm.provider, input.providerVmId);
  });
}

export function openVmPort(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly port: number;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
      "open_port",
    );
    if (!providers.openPort) {
      return yield* Effect.fail(
        new VmProviderOperationError({
          provider: vm.provider,
          operation: "openPort",
          cause: new Error("open-port is not supported by this deployment"),
        }),
      );
    }
    const endpoint = yield* providers.openPort(vm.provider, input.providerVmId, input.port);
    // Keep the preview token in the same revocation ledger as terminal/RPC
    // endpoints. The raw token is never persisted; only its hash is needed to
    // identify and invalidate this account's lease during sign-out.
    yield* repo.recordLease({
      vmId: vm.id,
      userId: input.userId,
      kind: "preview",
      tokenHash: hashToken(endpoint.token),
      expiresAt: new Date(Date.now() + PREVIEW_ENDPOINT_LEASE_TTL_MS),
      transport: "https",
      metadata: { port: input.port },
    }).pipe(
      Effect.catchAll((err) => {
        const cleanup = providers.revokeEndpointLeases
          ? providers.revokeEndpointLeases(vm.provider, input.providerVmId).pipe(
            bestEffort("endpoint_lease_rollback", { vmId: vm.id, provider: vm.provider }),
          )
          : Effect.void;
        return cleanup.pipe(Effect.andThen(Effect.fail(err)));
      }),
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.open_port",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { port: input.port },
    }).pipe(bestEffort("usage_event.vm.open_port", { vmId: vm.id, provider: vm.provider }));
    return endpoint;
  });
}

export type VmAccessRevocationResult = {
  readonly revoked: number;
  readonly cleanupFailures: number;
};

/**
 * Invalidates endpoint credentials issued to one signed-in account.
 *
 * Lease rows are account-scoped even when the VM itself is team-owned. This
 * keeps signing out one team member from revoking another member's session,
 * while the provider hook closes the concrete daemon/preview credentials that
 * were already handed to this client.
 */
export function revokeUserVmAccess(input: { readonly userId: string }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const loadLeases = repo.activeAccessLeasesForUser;
    if (!loadLeases) return { revoked: 0, cleanupFailures: 0 } satisfies VmAccessRevocationResult;

    const leases = yield* loadLeases(input.userId);
    const byVm = new Map<string, CloudVmAccessLeaseRow[]>();
    for (const lease of leases) {
      const existing = byVm.get(lease.vmId) ?? [];
      existing.push(lease);
      byVm.set(lease.vmId, existing);
    }

    let cleanupFailures = 0;
    if (providers.revokeEndpointLeases) {
      for (const vmLeases of byVm.values()) {
        const first = vmLeases[0];
        if (!first) continue;
        yield* providers.revokeEndpointLeases(first.provider, first.providerVmId).pipe(
          Effect.catchAll(() =>
            Effect.sync(() => {
              cleanupFailures += 1;
            })
          ),
        );
      }
    }

    const leaseIDs = leases.map((lease) => lease.id);
    yield* repo.markLeasesRevoked(leaseIDs);
    return {
      revoked: leaseIDs.length,
      cleanupFailures,
    } satisfies VmAccessRevocationResult;
  });
}

type OpenAttachEndpointInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly options?: AttachOptions;
  readonly sessionTitle?: string | null;
};

export function openAttachEndpoint(input: OpenAttachEndpointInput) {
  return Effect.gen(function* () {
    const result = yield* openAttachEndpointResult(input);
    return result.endpoint;
  });
}

export function openVmSession(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
  readonly sessionId?: string;
  readonly attachmentId?: string;
  readonly title?: string | null;
}) {
  const sessionId = input.sessionId?.trim() || `session-${randomUUID()}`;
  const attachmentId = input.attachmentId?.trim() || `attach-${randomUUID()}`;
  return openAttachEndpointResult({
    userId: input.userId,
    billingTeamId: input.billingTeamId,
    teamIds: input.teamIds,
    providerVmId: input.providerVmId,
    sessionTitle: input.title,
    options: {
      requireDaemon: true,
      sessionId,
      attachmentId,
    },
  });
}

export function listVmSessions(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* requireUserVm(input);
    return yield* repo.listVmSessions({ userId: input.userId, vmId: vm.id });
  });
}

function openAttachEndpointResult(input: OpenAttachEndpointInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "attach");
    // Once preflight records the VM as running, that state is externally
    // visible to concurrent attach/SSH requests. Later cleanup failures must
    // fail closed without pausing a VM another request may have attached to.
    yield* revokeActiveIdentities(vm, { failOnCleanupError: true });
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      "attach",
      providers.openAttach(vm.provider, input.providerVmId, {
        ...(input.options ?? {}),
        providerMetadata: vm.providerMetadata,
      }),
    );
    yield* storeEndpointLeases(vm, endpoint).pipe(
      Effect.catchAll((err) =>
        revokeEndpointIdentity(vm.provider, endpoint).pipe(
          Effect.andThen(Effect.fail(err)),
        ),
      ),
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.attach",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: {
        transport: endpoint.transport,
        requireDaemon: input.options?.requireDaemon === true,
        requestedSessionId: input.options?.sessionId ?? null,
        daemonAvailable: endpoint.transport === "websocket" && !!endpoint.daemon,
      },
    }).pipe(bestEffort("usage_event.vm.attach", { vmId: vm.id, provider: vm.provider }));
    const session = endpoint.transport === "websocket"
      ? yield* repo.upsertVmSession({
        vmId: vm.id,
        userId: input.userId,
        providerSessionId: endpoint.sessionId,
        title: input.sessionTitle ?? null,
        status: "running",
        attachmentCount: 1,
        metadata: {
          transport: endpoint.transport,
          daemonAvailable: !!endpoint.daemon,
          attachmentId: endpoint.attachmentId,
        },
      })
      : undefined;
    return { endpoint, session };
  });
}

export function openSshEndpoint(input: {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "ssh");
    yield* revokeActiveIdentities(vm, { failOnCleanupError: true });
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      "ssh",
      providers.openSSH(vm.provider, input.providerVmId),
    );
    yield* storeEndpointLeases(vm, endpoint).pipe(
      Effect.catchAll((err) =>
        revokeEndpointIdentity(vm.provider, endpoint).pipe(
          Effect.andThen(Effect.fail(err)),
        ),
      ),
    );
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.ssh_endpoint",
      provider: vm.provider,
      imageId: vm.imageId,
      metadata: { credentialKind: endpoint.credential.kind },
    }).pipe(bestEffort("usage_event.vm.ssh_endpoint", { vmId: vm.id, provider: vm.provider }));
    return endpoint;
  });
}

function requireUserVm(input: ExistingVmAccessInput) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* repo.findUserVm({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      providerVmId: input.providerVmId,
      provider: input.provider,
    });
    if (!vm || !vm.providerVmId) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    if (!callerStillOwnsBillingScope(input, vm)) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: input.providerVmId }));
    }
    return vm;
  });
}

function callerStillOwnsBillingScope(input: ExistingVmAccessInput, vm: CloudVmRow): boolean {
  const billingTeamId = vm.billingTeamId?.trim();
  if (!billingTeamId) return true;
  if (billingTeamId === input.userId) return true;
  if (!input.teamIds) return false;
  return new Set(input.teamIds).has(billingTeamId);
}

function revokeActiveIdentities(
  vm: CloudVmRow,
  options: { readonly failOnCleanupError?: boolean; readonly limit?: number } = {},
) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const leases = yield* repo.activeIdentityLeases(
      vm.id,
      options.failOnCleanupError ? ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT + 1 : options.limit,
    );
    if (options.failOnCleanupError && leases.length > ACTIVE_IDENTITY_REVOKE_HOT_PATH_LIMIT) {
      return yield* Effect.fail(new VmProviderOperationError({
        provider: vm.provider,
        operation: "revokeSSHIdentity",
        cause: new Error(`too many active identity leases pending cleanup: ${leases.length}`),
      }));
    }
    const revokedIds: string[] = [];
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle;
      if (!identityHandle) continue;
      const revoked = yield* revokeSSHIdentityForCleanup(providers, vm.provider, identityHandle).pipe(
        Effect.as(true),
        Effect.catchAll((err) => {
          if (isProviderIdentityNotFoundError(err.cause)) return Effect.succeed(true);
          if (!options.failOnCleanupError) return Effect.succeed(false);
          return repo.markLeasesRevoked(revokedIds).pipe(
            Effect.andThen(Effect.fail(err)),
          );
        }),
      );
      if (revoked) revokedIds.push(lease.id);
    }
    yield* repo.markLeasesRevoked(revokedIds);
  });
}

function revokeSSHIdentityForCleanup(
  providers: VmProviderGatewayShape,
  provider: ProviderId,
  identityHandle: string,
): Effect.Effect<void, VmProviderOperationError> {
  return providers.revokeSSHIdentity(provider, identityHandle).pipe(
    Effect.timeoutFail({
      duration: IDENTITY_REVOKE_PROVIDER_TIMEOUT,
      onTimeout: () =>
        new VmProviderOperationError({
          provider,
          operation: "revokeSSHIdentity",
          cause: new Error("identity revoke timed out"),
        }),
    }),
  );
}

function storeEndpointLeases(vm: CloudVmRow, endpoint: AttachEndpoint | SSHEndpoint) {
  return Effect.gen(function* () {
    if (endpoint.transport === "ssh") {
      yield* recordEndpointLease(vm, {
        kind: "ssh",
        token: sshCredentialToken(endpoint),
        expiresAt: new Date(Date.now() + 15 * 60 * 1000),
        providerIdentityHandle: endpoint.identityHandle || undefined,
        transport: "ssh",
        metadata: { credentialKind: endpoint.credential.kind },
      });
      if (endpoint.daemon) {
        yield* recordEndpointLease(vm, {
          kind: "rpc",
          token: endpoint.daemon.token,
          expiresAt: new Date(endpoint.daemon.expiresAtUnix * 1000),
          sessionId: endpoint.daemon.sessionId,
          transport: "websocket",
        });
      }
      return;
    }

    yield* recordEndpointLease(vm, {
      kind: "pty",
      token: endpoint.token,
      expiresAt: new Date(endpoint.expiresAtUnix * 1000),
      sessionId: endpoint.sessionId,
      transport: "websocket",
    });
    if (endpoint.daemon) {
      yield* recordEndpointLease(vm, {
        kind: "rpc",
        token: endpoint.daemon.token,
        expiresAt: new Date(endpoint.daemon.expiresAtUnix * 1000),
        sessionId: endpoint.daemon.sessionId,
        transport: "websocket",
      });
    }
  });
}

function recordCreditEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  eventType: string,
  reservation: VmCreateCreditReservation,
) {
  if (reservation.kind === "none") return Effect.void;
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: {
      itemId: reservation.itemId,
      amount: reservation.amount,
      customerType: reservation.customerType,
      customerIdSet: !!reservation.customerId,
    },
  });
}

/**
 * A create-credit reservation together with the durable ledger row that
 * tracks it. `reservationId` is null when nothing was (or will be) debited,
 * or when the repository does not support the reservation ledger.
 */
type CreateCreditReservationRecord = {
  readonly reservation: VmCreateCreditReservation;
  readonly reservationId: string | null;
};

function reserveCreateCredit(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly idempotencyKey?: string;
    readonly timing?: VmTimingSink;
  },
  vm: CloudVmRow,
): Effect.Effect<CreateCreditReservationRecord, VmWorkflowError> {
  const recordBillingFailure = (err: unknown) =>
    Effect.all([
      bestEffort("mark_create_failed", { vmId: vm.id, provider: input.provider })(repo.markCreateFailed({
        id: vm.id,
        code: isVmCreateCreditsInsufficientError(err)
          ? "billing_credits_insufficient"
          : "billing_reserve_failed",
        message: errorMessage(err),
      })),
      bestEffort("usage_event.vm.create.billing_failed", { vmId: vm.id, provider: input.provider })(repo.recordUsageEvent({
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        vmId: vm.id,
        eventType: "vm.create.billing_failed",
        provider: input.provider,
        imageId: input.image,
        metadata: {
          idempotencyKeySet: !!input.idempotencyKey,
          imageVersion: input.imageVersion ?? null,
          errorTag: typeof err === "object" && err !== null && "_tag" in err
            ? String((err as { _tag?: unknown })._tag)
            : null,
        },
      })),
    ], { discard: true });

  return measureVmEffect(
    input.timing,
    "billing",
    Effect.gen(function* () {
      yield* seedInitialCreateCredits(billing, repo, input, vm).pipe(
        Effect.catchAll((err) =>
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: vm.id,
            eventType: "vm.create.credit.grant_failed",
            provider: input.provider,
            imageId: input.image,
            metadata: {
              idempotencyKeySet: !!input.idempotencyKey,
              imageVersion: input.imageVersion ?? null,
              message: errorMessage(err),
            },
          }).pipe(bestEffort("usage_event.vm.create.credit.grant_failed", { vmId: vm.id, provider: input.provider }))
        ),
      );

      // Write the intent-to-debit BEFORE the debit RPC. A crash after the
      // Stack debit but before any later write leaves this row pending or
      // debited, which the reservation reconcile cron can resolve; without
      // it the credit is silently burned.
      const reservationId = yield* recordPlannedCreditReservation(billing, repo, input, vm).pipe(
        Effect.tapError(recordBillingFailure),
      );

      const creditReservation = yield* billing.reserveCreate({
        userId: input.userId,
        billingCustomerType: input.billingCustomerType,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: input.provider,
        image: input.image,
        imageVersion: input.imageVersion ?? null,
        vmId: vm.id,
        idempotencyKey: input.idempotencyKey,
      }).pipe(
        Effect.tapError((err) =>
          Effect.all([
            // Insufficient credits is the one failure where we KNOW no money
            // moved (tryDecreaseQuantity returned false), so the planned
            // reservation can be released. Any other billing error leaves it
            // pending: the debit outcome is unknown and the reconcile cron
            // reports it instead of guessing.
            isVmCreateCreditsInsufficientError(err)
              ? transitionCreditReservationBestEffort(repo, reservationId, ["pending"], "aborted", {
                vmId: vm.id,
                provider: input.provider,
              })
              : Effect.void,
            recordBillingFailure(err),
          ], { discard: true })
        ),
      );

      if (creditReservation.kind === "stack_item") {
        yield* transitionCreditReservationBestEffort(repo, reservationId, ["pending"], "debited", {
          vmId: vm.id,
          provider: input.provider,
        });
      } else {
        // The resolver planned a debit but the debit path resolved to none
        // (env changed mid-request); release the planned row.
        yield* transitionCreditReservationBestEffort(repo, reservationId, ["pending"], "aborted", {
          vmId: vm.id,
          provider: input.provider,
        });
      }
      return {
        reservation: creditReservation,
        reservationId: creditReservation.kind === "stack_item" ? reservationId : null,
      };
    }),
  );
}

function recordPlannedCreditReservation(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
  },
  vm: CloudVmRow,
): Effect.Effect<string | null, VmWorkflowError> {
  const insert = repo.insertCreditReservation;
  const resolve = billing.resolveCreateCredit;
  if (!insert || !resolve) return Effect.succeed(null);
  return Effect.gen(function* () {
    const plan = yield* Effect.try({
      try: () => resolve({
        userId: input.userId,
        billingCustomerType: input.billingCustomerType,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        provider: input.provider,
      }),
      catch: (cause) => new VmBillingError({ operation: "resolveCreateCredit", cause }),
    });
    if (plan.kind !== "stack_item") return null;
    const inserted = yield* insert({
      vmId: vm.id,
      billingCustomerType: plan.customerType,
      billingCustomerId: plan.customerId,
      itemId: plan.itemId,
      amount: plan.amount,
    });
    return inserted.id;
  });
}

function transitionCreditReservationBestEffort(
  repo: VmRepositoryShape,
  reservationId: string | null,
  from: readonly CloudVmCreditReservationStatus[],
  to: CloudVmCreditReservationStatus,
  context: BestEffortContext,
): Effect.Effect<void, never> {
  const transition = repo.transitionCreditReservation;
  if (!reservationId || !transition) return Effect.void;
  return transition({ id: reservationId, from, to }).pipe(
    Effect.asVoid,
    bestEffort(`credit_reservation_${to}`, context),
  );
}

/** Marks the reservation as spent once the VM create durably succeeded. A lost
 * write self-heals: the reconcile cron commits reservations whose VM runs. */
function commitCreditReservation(
  repo: VmRepositoryShape,
  credit: CreateCreditReservationRecord,
  context: BestEffortContext,
): Effect.Effect<void, never> {
  return transitionCreditReservationBestEffort(
    repo,
    credit.reservationId,
    ["pending", "debited"],
    "committed",
    context,
  );
}

function recordCreateRequestedEvents(
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
    readonly imageVersion?: string | null;
    readonly idempotencyKey?: string;
    readonly timing?: VmTimingSink;
  },
  requestedVm: CloudVmRow,
  creditReservation: VmCreateCreditReservation,
) {
  return measureVmEffect(
    input.timing,
    "usage_events",
    repo.recordUsageEvents([
      ...(creditReservation.kind === "none"
        ? []
        : [creditUsageEvent(requestedVm, "vm.create.credit.reserved", creditReservation)]),
      {
        userId: input.userId,
        billingTeamId: input.billingTeamId,
        billingPlanId: input.billingPlanId,
        vmId: requestedVm.id,
        eventType: "vm.create.requested",
        provider: input.provider,
        imageId: input.image,
        metadata: {
          idempotencyKeySet: !!input.idempotencyKey,
          imageVersion: input.imageVersion ?? null,
        },
      },
    ]).pipe(bestEffort("usage_event.vm.create.requested", { vmId: requestedVm.id, provider: input.provider })),
  );
}

function recordCreateSuccessEvents(
  repo: VmRepositoryShape,
  input: {
    readonly idempotencyKey?: string;
    readonly timing?: VmTimingSink;
  },
  running: CloudVmRow,
) {
  return measureVmEffect(
    input.timing,
    "usage_events",
    repo.recordUsageEvents([
      {
        userId: running.userId,
        billingTeamId: running.billingTeamId,
        billingPlanId: running.billingPlanId,
        vmId: running.id,
        eventType: "vm.created",
        provider: running.provider,
        imageId: running.imageId,
        metadata: {
          idempotencyKeySet: !!input.idempotencyKey,
          imageVersion: running.imageVersion,
        },
      },
    ]).pipe(bestEffort("usage_event.vm.created", { vmId: running.id, provider: running.provider })),
  );
}

function recordCreateFailureEvent(
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
    readonly image: string;
  },
  requestedVm: CloudVmRow,
  operation: string,
  message: string,
) {
  return repo.recordUsageEvent({
    userId: input.userId,
    billingTeamId: input.billingTeamId,
    billingPlanId: input.billingPlanId,
    vmId: requestedVm.id,
    eventType: "vm.create.failed",
    provider: input.provider,
    imageId: input.image,
    metadata: { operation, message },
  });
}

function creditUsageEvent(
  vm: CloudVmRow,
  eventType: string,
  reservation: Exclude<VmCreateCreditReservation, { readonly kind: "none" }>,
) {
  return {
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: {
      itemId: reservation.itemId,
      amount: reservation.amount,
      customerType: reservation.customerType,
      customerIdSet: !!reservation.customerId,
    },
  };
}

function seedInitialCreateCredits(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  input: {
    readonly userId: string;
    readonly billingCustomerType: BillingCustomerType;
    readonly billingTeamId: string;
    readonly billingPlanId: string;
    readonly provider: ProviderId;
  },
  vm: CloudVmRow,
) {
  return Effect.gen(function* () {
    const grant = yield* Effect.try({
      try: () => billing.resolveInitialCreateCreditGrant(input),
      catch: (cause) => new VmBillingError({ operation: "resolveInitialCreateCreditGrant", cause }),
    });
    if (grant.kind === "none") return;

    const claim = yield* repo.claimBillingGrant({
      billingCustomerType: grant.customerType,
      billingCustomerId: grant.customerId,
      billingPlanId: input.billingPlanId,
      itemId: grant.itemId,
      amount: grant.amount,
      reason: grant.reason,
    });
    if (claim.kind !== "inserted") return;

    yield* billing.applyCreateCreditGrant(grant).pipe(
      Effect.tapError(() =>
        repo.deleteBillingGrant(claim.grantId).pipe(
          bestEffort("billing_grant_rollback", { vmId: vm.id, provider: input.provider }),
        )
      ),
    );
    yield* repo.markBillingGrantApplied(claim.grantId).pipe(
      bestEffort("billing_grant_mark_applied", { vmId: vm.id, provider: input.provider }),
    );
    yield* recordGrantEvent(repo, vm, "vm.create.credit.granted", grant)
      .pipe(bestEffort("usage_event.vm.create.credit.granted", { vmId: vm.id, provider: vm.provider }));
  });
}

function recordGrantEvent(
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  eventType: string,
  grant: VmCreateCreditGrant,
) {
  if (grant.kind === "none") return Effect.void;
  return repo.recordUsageEvent({
    userId: vm.userId,
    billingTeamId: vm.billingTeamId,
    billingPlanId: vm.billingPlanId,
    vmId: vm.id,
    eventType,
    provider: vm.provider,
    imageId: vm.imageId,
    metadata: {
      itemId: grant.itemId,
      amount: grant.amount,
      reason: grant.reason,
      customerType: grant.customerType,
      customerIdSet: !!grant.customerId,
    },
  });
}

type CreateCompensationFailure = {
  readonly code: string;
  readonly message: string;
};

type CompensatedCreateInput<H> = {
  /** Provider-side create (or fork) that allocates the paid VM. */
  readonly createHandle: Effect.Effect<H, VmProviderOperationError>;
  /** Durable finalize write; failing it orphans the provider VM. */
  readonly finalize: (handle: H) => Effect.Effect<CloudVmRow, VmDatabaseError>;
  /** Destroys the provider VM that finalize failed to record. */
  readonly destroyOrphan: (handle: H) => Effect.Effect<void, VmProviderOperationError>;
  /** Refund of the reserved create credit (already best-effort). */
  readonly refund: Effect.Effect<void, never>;
  readonly markFailed: (
    failure: CreateCompensationFailure,
  ) => Effect.Effect<unknown, VmWorkflowError>;
  readonly createFailureEvent: (
    failure: CreateCompensationFailure,
  ) => Effect.Effect<unknown, VmWorkflowError>;
  /** Base records a different event type per stage; defaults to createFailureEvent. */
  readonly finalizeFailureEvent?: (
    failure: CreateCompensationFailure,
  ) => Effect.Effect<unknown, VmWorkflowError>;
  /** Durable failure message when the finalize write fails (user-facing). */
  readonly finalizeFailureMessage: string;
  readonly context: BestEffortContext;
};

/**
 * The shared create-fail-refund-markFailed-usage-event compensation used by
 * createVm, finishBaseCreate, and forkVm. Every compensation step is
 * best-effort (reported, never masking the original failure) and the
 * original error always propagates to the caller.
 */
function compensated<H>(
  input: CompensatedCreateInput<H>,
): Effect.Effect<CloudVmRow, VmProviderOperationError | VmDatabaseError> {
  const compensate = (
    markFailure: CreateCompensationFailure,
    eventFailure: CreateCompensationFailure,
    eventFor: (failure: CreateCompensationFailure) => Effect.Effect<unknown, VmWorkflowError>,
    orphanedHandle?: H,
  ): Effect.Effect<void, never> =>
    Effect.gen(function* () {
      if (orphanedHandle !== undefined) {
        yield* input.destroyOrphan(orphanedHandle).pipe(
          bestEffort("provider_destroy_rollback", input.context),
        );
      }
      yield* input.refund;
      yield* input.markFailed(markFailure).pipe(bestEffort("mark_create_failed", input.context));
      yield* eventFor(eventFailure).pipe(
        bestEffort("usage_event.vm.create.failed", input.context),
      );
    });

  return Effect.gen(function* () {
    const handle = yield* input.createHandle.pipe(
      Effect.tapError((err) => {
        const failure = { code: err.operation, message: errorMessage(err.cause) };
        return compensate(failure, failure, input.createFailureEvent);
      }),
    );
    return yield* input.finalize(handle).pipe(
      Effect.tapError((err) =>
        compensate(
          { code: "database_finalize_failed", message: input.finalizeFailureMessage },
          { code: "database_finalize_failed", message: errorMessage(err.cause) },
          input.finalizeFailureEvent ?? input.createFailureEvent,
          handle,
        )
      ),
    );
  });
}

function refundCredit(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  credit: CreateCreditReservationRecord,
): Effect.Effect<void, never> {
  const { reservation, reservationId } = credit;
  if (reservation.kind === "none") return Effect.void;
  const context = { vmId: vm.id, provider: vm.provider };

  const doRefund = billing.refundCreate(reservation).pipe(
    Effect.andThen(
      Effect.all([
        transitionCreditReservationBestEffort(repo, reservationId, ["refunding"], "refunded", context),
        recordCreditEvent(repo, vm, "vm.create.credit.refunded", reservation).pipe(
          bestEffort("usage_event.vm.create.credit.refunded", context),
        ),
      ], { discard: true }),
    ),
    Effect.catchAll((refundError) =>
      Effect.gen(function* () {
        reportBestEffortFailure("billing.refund_create", refundError, context);
        // The durable refund_failed state is what the reconcile cron retries;
        // the usage event keeps the lost refund visible in the billing ledger.
        yield* transitionCreditReservationBestEffort(repo, reservationId, ["refunding"], "refund_failed", context);
        yield* recordCreditEvent(repo, vm, "vm.create.credit.refund_failed", reservation).pipe(
          bestEffort("usage_event.vm.create.credit.refund_failed", context),
        );
      })
    ),
  );

  const transition = repo.transitionCreditReservation;
  if (!reservationId || !transition) return doRefund;
  // Claim the reservation before touching money so this request and the
  // reconcile cron can never both refund the same debit. "pending" is
  // included because the debited-mark write is best-effort and may be lost.
  return transition({ id: reservationId, from: ["pending", "debited"], to: "refunding" }).pipe(
    Effect.catchAll((err) => {
      // Unable to claim (database down): do not refund blindly. The row still
      // says debited, so the reconcile cron will refund once the DB is back.
      reportBestEffortFailure("credit_reservation_claim", err, context);
      return Effect.succeed(false);
    }),
    Effect.flatMap((claimed) => (claimed ? doRefund : Effect.void)),
  );
}

function recordEndpointLease(
  vm: CloudVmRow,
  input: {
    readonly kind: CloudVmLeaseKind;
    readonly token: string;
    readonly expiresAt: Date;
    readonly providerIdentityHandle?: string;
    readonly sessionId?: string;
    readonly transport?: string;
    readonly metadata?: Record<string, unknown>;
  },
) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    yield* repo.recordLease({
      vmId: vm.id,
      userId: vm.userId,
      kind: input.kind,
      tokenHash: hashToken(input.token),
      expiresAt: input.expiresAt,
      providerIdentityHandle: input.providerIdentityHandle,
      sessionId: input.sessionId,
      transport: input.transport,
      metadata: input.metadata,
    });
  });
}

function revokeEndpointIdentity(provider: ProviderId, endpoint: AttachEndpoint | SSHEndpoint) {
  return Effect.gen(function* () {
    if (endpoint.transport !== "ssh" || !endpoint.identityHandle) return;
    const providers = yield* VmProviderGateway;
    yield* providers.revokeSSHIdentity(provider, endpoint.identityHandle).pipe(
      bestEffort("ssh_identity_rollback", { provider }),
    );
  });
}

function vmEntryFromRow(row: CloudVmRow): VmEntry {
  if (!row.providerVmId) {
    throw new Error(`VM row has no provider VM id: ${row.id}`);
  }
  return {
    providerVmId: row.providerVmId,
    provider: row.provider,
    image: row.imageId,
    imageVersion: row.imageVersion,
    status: row.status,
    createdAt: row.createdAt.getTime(),
    displayName: row.displayName ?? null,
  };
}

function baseVmEntryFromRows(
  base: CloudVmBaseRow,
  generation: CloudVmBaseGenerationRow,
  row: CloudVmRow,
  retainedProviderVmId: string | null,
): BaseVmEntry {
  return {
    ...vmEntryFromRow(row),
    baseId: base.id,
    baseName: base.name,
    generation: generation.generation,
    retainedProviderVmId,
  };
}

function sshCredentialToken(endpoint: SSHEndpoint): string {
  return endpoint.credential.kind === "password"
    ? endpoint.credential.value
    : endpoint.credential.privateKeyPem;
}

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function errorMessage(cause: unknown): string {
  return cause instanceof Error ? cause.message : String(cause);
}
