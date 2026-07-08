import { createHash, randomUUID } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
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
  VmCreateFailedError,
  VmCreateInProgressError,
  VmNotFoundError,
  VmProviderOperationError,
  VmSnapshotNotFoundError,
  isVmCreateCreditsInsufficientError,
  isVmLimitExceededError,
  vmWorkflowErrorCause,
  type VmDatabaseError,
  type VmWorkflowError,
} from "./errors";
import { maxActiveVmsForPlan } from "./entitlements";
import { isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, VmProviderGatewayLive, type VmProviderGatewayShape } from "./providerGateway";
import {
  VmRepository,
  VmRepositoryLive,
  type BeginCreateResult,
  type BeginBaseCreateResult,
  type CloudVmBaseGenerationRow,
  type CloudVmBaseRow,
  type CloudVmSessionRow,
  type CloudVmStatus,
  type CloudVmLeaseKind,
  type CloudVmRow,
  type VmRepositoryShape,
} from "./repository";
import { measureVmEffect, type VmTimingSink } from "./timings";

export type VmEntry = {
  readonly providerVmId: string;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly status: CloudVmStatus;
  readonly createdAt: number;
};

export type BaseVmEntry = VmEntry & {
  readonly baseId: string;
  readonly baseName: string;
  readonly generation: number;
  readonly retainedProviderVmId: string | null;
};

export type CloudVmSessionEntry = CloudVmSessionRow;

export const VmWorkflowLive = Layer.mergeAll(VmRepositoryLive, VmProviderGatewayLive, VmBillingGatewayLive);

const EXPIRED_IDENTITY_REVOKE_BATCH = 50;
const VM_STATUS_RECONCILE_BATCH_LIMIT = 200;

type ExistingVmAccessInput = {
  readonly userId: string;
  readonly billingTeamId?: string | null;
  readonly teamIds?: readonly string[];
  readonly providerVmId: string;
};

export type VmProviderStatusReconcileResult = {
  readonly checked: number;
  readonly updated: number;
  readonly destroyed: number;
  readonly skipped: number;
  readonly skippedNoGetStatus: boolean;
};

export async function runVmWorkflow<A>(
  program: Effect.Effect<A, VmWorkflowError, VmRepository | VmProviderGateway | VmBillingGateway>,
): Promise<A> {
  try {
    return await Effect.runPromise(program.pipe(Effect.provide(VmWorkflowLive)));
  } catch (err) {
    throw vmWorkflowErrorCause(err) ?? err;
  }
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
    if (providerStatus !== "creating" && providerStatus !== vm.status) {
      const dbStatus = dbStatusFromProviderStatus(providerStatus);
      const didUpdate = yield* repo.markProviderObservedStatus({
        id: vm.id,
        providerVmId,
        status: dbStatus,
      });
      if (didUpdate) return vmEntryFromRow({ ...vm, status: dbStatus, updatedAt: new Date() });
    }
    return vmEntryFromRow(vm);
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

    const creditReservation = yield* reserveCreateCredit(billing, repo, input, create.vm);
    yield* recordCreateRequestedEvents(repo, input, create.vm, creditReservation);

    const handle = yield* measureVmEffect(
      input.timing,
      "provider_create",
      providers.create(input.provider, {
        image: input.image,
        providerMetadata: create.vm.providerMetadata,
        bakedFreestyleSignedAdmin: input.bakedFreestyleSignedAdmin,
      }),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          repo.markCreateFailed({
            id: create.vm.id,
            code: err.operation,
            message: errorMessage(err.cause),
          }),
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: err.operation, message: errorMessage(err.cause) },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
      ),
    );

    const running = yield* measureVmEffect(
      input.timing,
      "mark_running",
      repo.markCreateRunning({
        id: create.vm.id,
        providerVmId: handle.providerVmId,
        image: handle.image,
        imageVersion: input.imageVersion ?? null,
        providerMetadata: handle.providerMetadata ?? create.vm.providerMetadata,
      }),
    ).pipe(
      Effect.catchAll((err) =>
        Effect.gen(function* () {
          yield* providers.destroy(input.provider, handle.providerVmId).pipe(Effect.catchAll(() => Effect.void));
          yield* refundCredit(billing, repo, create.vm, creditReservation);
          yield* repo.markCreateFailed({
            id: create.vm.id,
            code: "database_finalize_failed",
            message: "Cloud VM state update failed.",
          }).pipe(Effect.catchAll(() => Effect.void));
          yield* recordCreateFailureEvent(
            repo,
            input,
            create.vm,
            "database_finalize_failed",
            errorMessage(err.cause),
          ).pipe(Effect.catchAll(() => Effect.void));
          return yield* Effect.fail(err);
        }),
      ),
    );

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
      return baseVmEntryFromRows(create.base, create.generation, existing, null);
    }

    const idempotencyKey = create.vm.idempotencyKey ?? undefined;
    const creditReservation = yield* reserveCreateCredit(billing, repo, {
      ...input,
      idempotencyKey,
    }, create.vm);
    yield* recordCreateRequestedEvents(repo, {
      ...input,
      idempotencyKey,
    }, create.vm, creditReservation);

    const handle = yield* measureVmEffect(
      input.timing,
      "provider_create",
      providers.create(input.provider, {
        image: input.image,
        providerMetadata: create.vm.providerMetadata,
        bakedFreestyleSignedAdmin: input.bakedFreestyleSignedAdmin,
      }),
    ).pipe(
      Effect.tapError((err) =>
        Effect.all([
          refundCredit(billing, repo, create.vm, creditReservation),
          repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: err.operation,
            message: errorMessage(err.cause),
          }),
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
            eventType: "vm.base.create.failed",
            provider: input.provider,
            imageId: input.image,
            metadata: { operation: err.operation, message: errorMessage(err.cause), baseName: input.baseName ?? "base" },
          }),
        ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
      ),
    );

    const running = yield* measureVmEffect(
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
    ).pipe(
      Effect.catchAll((err) =>
        Effect.gen(function* () {
          yield* providers.destroy(input.provider, handle.providerVmId).pipe(Effect.catchAll(() => Effect.void));
          yield* refundCredit(billing, repo, create.vm, creditReservation);
          yield* repo.markBaseCreateFailed({
            baseId: create.base.id,
            generation: create.generation.generation,
            vmId: create.vm.id,
            userId: input.userId,
            code: "database_finalize_failed",
            message: "Cloud VM Base state update failed.",
          }).pipe(Effect.catchAll(() => Effect.void));
          yield* recordCreateFailureEvent(
            repo,
            {
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              provider: input.provider,
              image: input.image,
            },
            create.vm,
            "database_finalize_failed",
            errorMessage(err.cause),
          ).pipe(Effect.catchAll(() => Effect.void));
          return yield* Effect.fail(err);
        }),
      ),
    );

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
    }).pipe(Effect.catchAll(() => Effect.void));

    return baseVmEntryFromRows(
      create.base,
      create.generation,
      running,
      create.previousVm?.providerVmId ?? null,
    );
  });
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

      const creditReservation = yield* reserveCreateCredit(billing, repo, {
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
      }, create.vm, creditReservation);

      const handle = yield* measureVmEffect(
        input.timing,
        "provider_create",
        providers.fork(source.provider, source.providerVmId ?? input.providerVmId),
      ).pipe(
        Effect.tapError((err) =>
          Effect.all([
            refundCredit(billing, repo, create.vm, creditReservation),
            repo.markCreateFailed({
              id: create.vm.id,
              code: err.operation,
              message: errorMessage(err.cause),
            }),
            repo.recordUsageEvent({
              userId: input.userId,
              billingTeamId: input.billingTeamId,
              billingPlanId: input.billingPlanId,
              vmId: create.vm.id,
              eventType: "vm.create.failed",
              provider: source.provider,
              imageId: source.imageId,
              metadata: { operation: err.operation, message: errorMessage(err.cause), sourceProviderVmId: source.providerVmId },
            }),
          ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
        ),
      );

      const running = yield* measureVmEffect(
        input.timing,
        "mark_running",
        repo.markCreateRunning({
          id: create.vm.id,
          providerVmId: handle.providerVmId,
          image: source.imageId,
          imageVersion: source.imageVersion,
          providerMetadata: handle.providerMetadata ?? source.providerMetadata,
        }),
      ).pipe(
        Effect.catchAll((err) =>
          Effect.gen(function* () {
            yield* providers.destroy(source.provider, handle.providerVmId).pipe(Effect.catchAll(() => Effect.void));
            yield* refundCredit(billing, repo, create.vm, creditReservation);
            yield* repo.markCreateFailed({
              id: create.vm.id,
              code: "database_finalize_failed",
              message: "Cloud VM fork state update failed.",
            }).pipe(Effect.catchAll(() => Effect.void));
            yield* recordCreateFailureEvent(
              repo,
              {
                userId: input.userId,
                billingTeamId: input.billingTeamId,
                billingPlanId: input.billingPlanId,
                provider: source.provider,
                image: source.imageId,
              },
              create.vm,
              "database_finalize_failed",
              errorMessage(err.cause),
            ).pipe(Effect.catchAll(() => Effect.void));
            return yield* Effect.fail(err);
          }),
        ),
      );

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
      }).pipe(Effect.catchAll(() => Effect.void));
      return { snapshot: null, fork };
    }

    const snapshot = yield* snapshotVm({
      userId: input.userId,
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
    }).pipe(Effect.catchAll(() => Effect.void));
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
        ).pipe(Effect.catchAll(() => Effect.void));
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
    const dbStatus = dbStatusFromProviderStatus(providerStatus);
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
      }).pipe(Effect.catchAll(() => Effect.void));
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
type VmResumeSource = "exec" | "attach" | "ssh" | "fork";

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
  return pause(vm.provider, providerVmId).pipe(Effect.catchAll(() => Effect.void));
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
  }).pipe(Effect.catchAll(() => Effect.void));
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
  }).pipe(Effect.catchAll(() => Effect.void));
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
): Effect.Effect<void, VmWorkflowError> {
  return Effect.gen(function* () {
    const getStatus = providers.getStatus;
    const resume = providers.resume;
    if (!getStatus || !resume) return;

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
      return;
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
      return;
    }
    if (status !== "paused") return;

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
    return pause(vm.provider, providerVmId).pipe(Effect.catchAll(() => Effect.void));
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
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input);

    yield* revokeActiveIdentities(vm);
    yield* providers.destroy(vm.provider, vm.providerVmId ?? input.providerVmId).pipe(
      Effect.catchAll((err) => {
        if (isProviderNotFoundError(err.cause)) return Effect.void;
        return Effect.fail(err);
      }),
    );
    yield* repo.markDestroyed(vm.id);
    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: vm.billingTeamId,
      billingPlanId: vm.billingPlanId,
      vmId: vm.id,
      eventType: "vm.destroyed",
      provider: vm.provider,
      imageId: vm.imageId,
    }).pipe(Effect.catchAll(() => Effect.void));
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
    const leases = yield* expiredIdentityLeases({
      now: input.now ?? new Date(),
      limit: input.limit ?? EXPIRED_IDENTITY_REVOKE_BATCH,
    });
    const revokedIds: string[] = [];
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle;
      if (!identityHandle) continue;
      const revoked = yield* providers.revokeSSHIdentity(lease.provider, identityHandle).pipe(
        Effect.as(true),
        Effect.catchAll((err) => Effect.succeed(isProviderNotFoundError(err.cause))),
      );
      if (revoked) revokedIds.push(lease.id);
    }
    yield* repo.markLeasesRevoked(revokedIds);
    return revokedIds.length;
  });
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
    }).pipe(Effect.catchAll(() => Effect.void));
    return result satisfies ExecResult;
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
    // Endpoint minting can succeed against a paused VM (Freestyle openSSH only
    // grants an identity), which would hand out an endpoint while Postgres
    // still says paused. Preflight-resume first — and before revoking the
    // user's existing identities, so a preflight failure never strands them
    // with old credentials revoked and no replacement minted.
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "attach");
    yield* revokeActiveIdentities(vm);
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
    }).pipe(Effect.catchAll(() => Effect.void));
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
    // Endpoint minting can succeed against a paused VM (Freestyle openSSH only
    // grants an identity), which would hand out an endpoint while Postgres
    // still says paused. Preflight-resume first — and before revoking the
    // user's existing identities, so a preflight failure never strands them
    // with old credentials revoked and no replacement minted.
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId, "ssh");
    yield* revokeActiveIdentities(vm);
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
    }).pipe(Effect.catchAll(() => Effect.void));
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
  if (!input.teamIds) return true;
  return new Set(input.teamIds ?? []).has(billingTeamId);
}

function revokeActiveIdentities(vm: CloudVmRow) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const leases = yield* repo.activeIdentityLeases(vm.id);
    for (const lease of leases) {
      const identityHandle = lease.providerIdentityHandle;
      if (!identityHandle) continue;
      yield* providers.revokeSSHIdentity(vm.provider, identityHandle);
    }
    yield* repo.markLeasesRevoked(leases.map((lease) => lease.id));
  });
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
) {
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
          }).pipe(Effect.catchAll(() => Effect.void))
        ),
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
            repo.markCreateFailed({
              id: vm.id,
              code: isVmCreateCreditsInsufficientError(err)
                ? "billing_credits_insufficient"
                : "billing_reserve_failed",
              message: errorMessage(err),
            }),
            repo.recordUsageEvent({
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
            }),
          ], { discard: true }).pipe(Effect.catchAll(() => Effect.void))
        ),
      );
      return creditReservation;
    }),
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
    ]).pipe(Effect.catchAll(() => Effect.void)),
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
    ]).pipe(Effect.catchAll(() => Effect.void)),
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
        repo.deleteBillingGrant(claim.grantId).pipe(Effect.catchAll(() => Effect.void))
      ),
    );
    yield* repo.markBillingGrantApplied(claim.grantId).pipe(Effect.catchAll(() => Effect.void));
    yield* recordGrantEvent(repo, vm, "vm.create.credit.granted", grant)
      .pipe(Effect.catchAll(() => Effect.void));
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

function refundCredit(
  billing: VmBillingGatewayShape,
  repo: VmRepositoryShape,
  vm: CloudVmRow,
  reservation: VmCreateCreditReservation,
) {
  return billing.refundCreate(reservation).pipe(
    Effect.andThen(recordCreditEvent(repo, vm, "vm.create.credit.refunded", reservation)),
    Effect.catchAll(() => Effect.void),
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
    yield* providers.revokeSSHIdentity(provider, endpoint.identityHandle).pipe(Effect.catchAll(() => Effect.void));
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
