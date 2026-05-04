import { createHash } from "node:crypto";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import type {
  AttachEndpoint,
  AttachOptions,
  ExecResult,
  ProviderId,
  SSHEndpoint,
} from "./drivers";
import {
  VmBillingGateway,
  VmBillingGatewayLive,
  type BillingCustomerType,
  type VmCreateCreditReservation,
  type VmBillingGatewayShape,
} from "./billingGateway";
import {
  VmCreateFailedError,
  VmCreateInProgressError,
  VmNotFoundError,
  vmWorkflowErrorCause,
  type VmWorkflowError,
} from "./errors";
import { isProviderNotFoundError } from "./providerErrors";
import { VmProviderGateway, VmProviderGatewayLive } from "./providerGateway";
import {
  VmRepository,
  VmRepositoryLive,
  type CloudVmLeaseKind,
  type CloudVmRow,
  type VmRepositoryShape,
} from "./repository";

export type VmEntry = {
  readonly providerVmId: string;
  readonly provider: ProviderId;
  readonly image: string;
  readonly imageVersion: string | null;
  readonly createdAt: number;
};

export const VmWorkflowLive = Layer.mergeAll(VmRepositoryLive, VmProviderGatewayLive, VmBillingGatewayLive);

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
}) {
  return Effect.gen(function* () {
    const repo = yield* VmRepository;
    const providers = yield* VmProviderGateway;
    const billing = yield* VmBillingGateway;
    const create = yield* repo.beginCreate(input);

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

    const creditReservation = yield* billing.reserveCreate({
      userId: input.userId,
      billingCustomerType: input.billingCustomerType,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      provider: input.provider,
      image: input.image,
      imageVersion: input.imageVersion ?? null,
      vmId: create.vm.id,
      idempotencyKey: input.idempotencyKey,
    }).pipe(
      Effect.tapError((err) =>
        Effect.all([
          repo.markCreateFailed({
            id: create.vm.id,
            code: "billing_reserve_failed",
            message: errorMessage(err),
          }),
          repo.recordUsageEvent({
            userId: input.userId,
            billingTeamId: input.billingTeamId,
            billingPlanId: input.billingPlanId,
            vmId: create.vm.id,
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

    yield* recordCreditEvent(repo, create.vm, "vm.create.credit.reserved", creditReservation)
      .pipe(Effect.catchAll(() => Effect.void));

    yield* repo.recordUsageEvent({
      userId: input.userId,
      billingTeamId: input.billingTeamId,
      billingPlanId: input.billingPlanId,
      vmId: create.vm.id,
      eventType: "vm.create.requested",
      provider: input.provider,
      imageId: input.image,
      metadata: {
        idempotencyKeySet: !!input.idempotencyKey,
        imageVersion: input.imageVersion ?? null,
      },
    }).pipe(Effect.catchAll(() => Effect.void));

    const handle = yield* providers.create(input.provider, { image: input.image }).pipe(
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

    const running = yield* repo
      .markCreateRunning({
        id: create.vm.id,
        providerVmId: handle.providerVmId,
        image: handle.image,
        imageVersion: input.imageVersion ?? null,
      })
      .pipe(
        Effect.catchAll((err) =>
          Effect.gen(function* () {
            yield* providers.destroy(input.provider, handle.providerVmId).pipe(Effect.catchAll(() => Effect.void));
            yield* refundCredit(billing, repo, create.vm, creditReservation);
            yield* repo.markCreateFailed({
              id: create.vm.id,
              code: "database_finalize_failed",
              message: err.message,
            }).pipe(Effect.catchAll(() => Effect.void));
            return yield* Effect.fail(err);
          }),
        ),
      );

    yield* repo.recordUsageEvent({
      userId: input.userId,
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
    }).pipe(Effect.catchAll(() => Effect.void));

    return vmEntryFromRow(running);
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
    yield* revokeActiveIdentities(vm);
    const endpoint = yield* providers.openAttach(vm.provider, input.providerVmId, input.options);
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
    yield* revokeActiveIdentities(vm);
    const endpoint = yield* providers.openSSH(vm.provider, input.providerVmId);
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
