import { createHash } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import {
  type AttachEndpoint,
  type AttachOptions,
  type ExecResult,
  type ProviderId,
  type SSHEndpoint,
  type VMStatus,
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
  isVmLimitExceededError,
  vmWorkflowErrorCause,
  type VmDatabaseError,
  type VmWorkflowError,
} from "./errors";
import { isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, VmProviderGatewayLive, type VmProviderGatewayShape } from "./providerGateway";
import {
  VmRepository,
  VmRepositoryLive,
  type BeginCreateResult,
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

export const VmWorkflowLive = Layer.mergeAll(VmRepositoryLive, VmProviderGatewayLive, VmBillingGatewayLive);

const VM_STATUS_RECONCILE_BATCH_LIMIT = 200;

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
      providers.create(input.provider, { image: input.image }),
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

// Active-limit note: resuming a user's own existing VM is intentionally not
// limit-gated here. Freestyle's SSH gateway resumes suspended VMs on any
// client connect with no control-plane involvement, so this seam cannot
// enforce the limit; enforcement happens where allocation is decided —
// beginCreate's reconcile re-counts provider-running VMs on the next create.
function preflightResumeIfSuspended(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
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

    yield* resumeUntilRunning(providers, vm, providerVmId);
    yield* recordRunningTransition(
      repo,
      providers,
      vm,
      providerVmId,
      new VmNotFoundError({ vmId: providerVmId }),
    );
  });
}

function withResumeOnSuspendedAfterFailure<A, E extends VmWorkflowError>(
  repo: VmRepositoryShape,
  providers: VmProviderGatewayShape,
  vm: CloudVmRow,
  providerVmId: string,
  op: Effect.Effect<A, E>,
): Effect.Effect<A, E | VmDatabaseError> {
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

        yield* resumeUntilRunning(providers, vm, providerVmId).pipe(
          Effect.catchAll(() => Effect.fail(originalError)),
        );
        yield* recordRunningTransition(repo, providers, vm, providerVmId, originalError);
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

export function destroyVm(input: { readonly userId: string; readonly providerVmId: string }) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input.userId, input.providerVmId);

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

export function execVm(input: {
  readonly userId: string;
  readonly providerVmId: string;
  readonly command: string;
  readonly timeoutMs: number;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input.userId, input.providerVmId);
    yield* preflightResumeIfSuspended(
      repo,
      providers,
      vm,
      input.providerVmId,
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

export function openAttachEndpoint(input: {
  readonly userId: string;
  readonly providerVmId: string;
  readonly options?: AttachOptions;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input.userId, input.providerVmId);
    // Endpoint minting can succeed against a paused VM (Freestyle openSSH only
    // grants an identity), which would hand out an endpoint while Postgres
    // still says paused. Preflight-resume first — and before revoking the
    // user's existing identities, so a preflight failure never strands them
    // with old credentials revoked and no replacement minted.
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId);
    yield* revokeActiveIdentities(vm);
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
      providers.openAttach(vm.provider, input.providerVmId, input.options),
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
        daemonAvailable: endpoint.transport === "websocket" && !!endpoint.daemon,
      },
    }).pipe(Effect.catchAll(() => Effect.void));
    return endpoint;
  });
}

export function openSshEndpoint(input: {
  readonly userId: string;
  readonly providerVmId: string;
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const vm = yield* requireUserVm(input.userId, input.providerVmId);
    // Endpoint minting can succeed against a paused VM (Freestyle openSSH only
    // grants an identity), which would hand out an endpoint while Postgres
    // still says paused. Preflight-resume first — and before revoking the
    // user's existing identities, so a preflight failure never strands them
    // with old credentials revoked and no replacement minted.
    yield* preflightResumeIfSuspended(repo, providers, vm, input.providerVmId);
    yield* revokeActiveIdentities(vm);
    const endpoint = yield* withResumeOnSuspendedAfterFailure(
      repo,
      providers,
      vm,
      input.providerVmId,
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

function requireUserVm(userId: string, providerVmId: string) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const vm = yield* repo.findUserVm({ userId, providerVmId });
    if (!vm || !vm.providerVmId) {
      return yield* Effect.fail(new VmNotFoundError({ vmId: providerVmId }));
    }
    return vm;
  });
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
              code: "billing_reserve_failed",
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
