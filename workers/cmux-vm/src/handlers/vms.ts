/**
 * VM lifecycle endpoints. Each handler names the caller and the resource,
 * proves scope and ownership (handlers/common.ts), and only then calls the
 * upstream client, which does not compile without those proofs.
 *
 * The provider has no stop, resume or fork operation, so:
 * - start: the provider's start (it boots a stopped VM and resumes a paused one);
 * - resume: the provider's start, only for a paused VM;
 * - stop: a `poweroff` inside the guest (the provider leaves a VM powered off
 *   from inside stopped and does not restart it);
 * - fork: a snapshot of the source, then a create from that snapshot, then
 *   deleting the snapshot. Not atomic; see `forkVm` below.
 */
import { HttpApiBuilder } from "@effect/platform";
import { creationResult, issueCreation } from "./generated-creation.ts";
import { scopedCreationKey, scopedForkSnapshotKey } from "../auth/idempotency-key.ts";
import { acquireForkSnapshot } from "./fork-capture.ts";
import { cleanupForkSnapshot } from "./fork-snapshot-cleanup.ts";
import { recoverWithdrawnImage } from "./image-recovery.ts";
import { replayVm } from "./replay-vm.ts";
import { retireVm } from "./retire.ts";
import { VmInstanceIdentity } from "../api/instance-identity.ts";
import { INSTANCE_IDENTITY_SCHEME } from "../../../../libs/vm-instance-identity/src/identity.ts";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Either, Option, Schema } from "effect";
import { idempotent, requestFingerprint } from "./idempotency.ts";
import type { VmCreationProbe, RetainedVmCreation } from "../domain/vm-creation.ts";
import { CREATE_SEND_GRACE_MS, type IdempotencyProgress, type ForkCaptureProgress } from "../limits/ledger.ts";
import { resizeVm } from "./resize.ts";
import { toVm } from "./vm-view.ts";
import { replaceVmHttpsProxy } from "./https-proxies.ts";
import { VmImageList } from "../api/images.ts";
import { visibleVmImages, vmImageAllowed, vmImageEvidenceOf, type VmImageAllowed } from "../proofs/vm-image.ts";
import { CmuxVmApi, CreatedVm, Vm, VmList, type CreateVmRequest, type ForkVmRequest, type VmState } from "../api.ts";
import { OwnershipStore } from "../db/stores.ts";
import { agentBudgetAllows, revokeVmClientSessions, withAgentLabels } from "./agent-sandboxes.ts";
import { actorRef, carriesRequiredLabels, CurrentPrincipal, type Principal } from "../domain/principal.ts";
import {
  badRequest,
  conflict,
  Forbidden,
  ForkIncomplete,
  PaymentRequired,
  QuotaExceeded,
  snapshotNotFound,
  unavailable,
  vmNotFound,
  type BadRequest,
  type Conflict,
  type NotFound,
  type ServiceUnavailable,
} from "../errors.ts";
import { newSnapshotId, newVmId, parseSnapshotId, parseVmId, TenantId, type SnapshotId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import { resolveIdleTimeout, TenantPolicy } from "../policy.ts";
import { keyHasScope, type KeyHasScope } from "../proofs/key-has-scope.ts";
import { vmNetworkAllowed, vmNetworkEvidenceOf, type VmNetworkAllowed } from "../proofs/vm-network.ts";
import { tenantMayCreate, type TenantMayCreate } from "../proofs/tenant-may-create.ts";
import { tenantDeletedVm, tenantOwnsSnapshot, tenantOwnsVm, visitOwnedVms, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient, UpstreamError, type SizeRequest } from "../upstream/client.ts";
import { audited, auditableVmId, withCaller, withOwnedVm } from "./common.ts";

/** Provider failures on an existing VM: 404 means the VM is gone; 409 is the given conflict; the rest is ours. */
const onVm =
  (conflictMessage: string) =>
  (error: UpstreamError): NotFound | Conflict | ServiceUnavailable =>
    error.status === 404 ? vmNotFound() : error.status === 409 ? conflict(conflictMessage) : unavailable();

/** Provider failures reading a VM: 404 means it is gone; anything else is ours. */
const onRead = (error: UpstreamError): NotFound | ServiceUnavailable => (error.status === 404 ? vmNotFound() : unavailable());

/** Provider failures on a create. */
const onCreate = (error: UpstreamError): BadRequest | Conflict | NotFound | QuotaExceeded | ServiceUnavailable => {
  // The source snapshot expired upstream after it was recorded.
  if (error.status === 404) return snapshotNotFound();
  if (error.status === 400) return badRequest("The VM could not be created as asked (check its snapshot and sizes)");
  if (error.status === 409) return conflict("No capacity is available for a new VM right now; retry later");
  if (error.status === 429) return new QuotaExceeded({ message: "VM capacity is exhausted for now; retry later", retryAfterSeconds: 60, budget: "capacity" });
  return unavailable();
};

const forbidAllowlisted = (principal: Principal) =>
  principal.resourceAllowlist === null
    ? Effect.void
    : Effect.fail(new Forbidden({ message: "A key limited to specific resources cannot create VMs" }));

/** A service key (cx-b4h.13) creates only VMs that carry its labels, e.g. role=chief. */
const requireServiceLabels = (principal: Principal, labels: Readonly<Record<string, string>>) =>
  carriesRequiredLabels(principal, labels)
    ? Effect.void
    : Effect.fail(
        new Forbidden({
          message: `This service key creates only VMs labelled ${Object.entries(principal.requiredLabels ?? {})
            .map(([key, value]) => `${key}=${value}`)
            .join(", ")}`,
        }),
      );

const idleOrFail = (principal: Principal, requested: number | undefined) =>
  Effect.flatMap(TenantPolicy, (policy) => {
    const idle = resolveIdleTimeout(policy, principal.tenantId, requested);
    return idle.ok ? Effect.succeed(idle.seconds) : Effect.fail(badRequest(idle.message));
  });

const sortedLabels = (labels: Readonly<Record<string, string>> | undefined) =>
  labels === undefined ? null : Object.fromEntries(Object.entries(labels).sort(([a], [b]) => (a < b ? -1 : 1)));

/** Everything a create and a fork need to make one VM. */
interface NewVm {
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
  readonly idleTimeoutSeconds: number;
  readonly maxRunSeconds: number | undefined;
  readonly autoDeleteSeconds: number | undefined;
  readonly size: SizeRequest | undefined;
}

/**
 * Asks for a create slot: billing first (402), then the tenant's VM quota
 * (429). Runs `k` with the proof and releases the slot afterwards, by which
 * time a created VM is counted in the ownership table.
 */
const withCreateSlot = <C, A, E, R>(caller: Named<C, Principal>, k: (proof: TenantMayCreate<C, "vm">) => Effect.Effect<A, E, R>, resume?: { readonly key: string; readonly vmId: string }) =>
  Effect.gen(function* () {
    const decision = yield* tenantMayCreate(caller, "vm", resume).pipe(Effect.mapError(() => unavailable()));
    if (decision._tag === "not_entitled") {
      return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include VMs" }));
    }
    if (decision._tag === "over_quota") {
      return yield* Effect.fail(
        new QuotaExceeded({
          message: `This team already has its limit of ${decision.limit} VMs; delete one first`,
          retryAfterSeconds: 60,
          budget: "vms",
        }),
      );
    }
    const limits = yield* TenantLimits;
    return yield* k(decision.proof).pipe(Effect.ensuring(limits.release(caller.value.tenantId, decision.proof.reservationId)));
  });

/**
 * Once a VM has its tombstone, the creation intent that made it gives up its quota slot: a cancelled intent
 * settles its cancellation, any other unfinished one settles as finished (the tombstone is its outcome), and a
 * fork's intermediate snapshot is cleaned up. Both settlements are idempotent, so a retried delete never frees
 * a slot twice; a deleted committed VM whose intent already finished changes nothing.
 */
const settleDeletedCreation = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, vmId: string) =>
  Effect.gen(function* () {
    const tenantId = caller.value.tenantId;
    const key = yield* (yield* OwnershipStore).creationKey(tenantId, vmId).pipe(Effect.mapError(() => unavailable()));
    if (key === null) return;
    const limits = yield* TenantLimits;
    const progress = (yield* limits.inspect(tenantId, key).pipe(Effect.mapError(() => unavailable())))?.progress;
    if ((progress?.phase !== "creating" && progress?.phase !== "cancelled") || progress.vmId !== vmId) return;
    const settle = progress.phase === "cancelled" || progress.cancelRequested === true ? limits.settleCancellation : limits.settleCreation;
    yield* settle(tenantId, key, vmId).pipe(Effect.mapError(() => unavailable()));
    if (progress.snapshotId !== undefined) yield* cleanupForkSnapshot(caller, scope, progress.snapshotId);
  });

/**
 * Creates the VM upstream (tagged with the tenant), grows it to the requested
 * size, and records it in the ownership table. Keyed creates retain an intent
 * and quota slot before I/O; retries recover the same allocation. Requests
 * without a client key receive a server-issued recovery handle. A failed grow
 * records the VM uncommitted.
 */
const createRecorded = <C, S>(
  caller: Named<C, Principal>,
  spec: NewVm,
  proofs: {
    readonly mayCreate: TenantMayCreate<C, "vm">;
    readonly scope: KeyHasScope<C, "vm:write">;
    readonly network?: VmNetworkAllowed<C>;
    readonly image?: VmImageAllowed<C>;
    readonly source?: { readonly snapshot: Named<S, SnapshotId>; readonly owns: TenantOwnsResource<C, S> };
  },
  attempt: { readonly key: string; readonly prior: IdempotencyProgress | null; readonly snapshotId?: string },
) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const store = yield* OwnershipStore;
    const policy = yield* TenantPolicy;
    const parsed = (attempt.prior?.phase === "creating" || attempt.prior?.phase === "capturing") ? parseVmId(attempt.prior.vmId) : Option.some(newVmId());
    if (Option.isNone(parsed)) return yield* Effect.fail(unavailable());
    const cmuxId = parsed.value;
    const createdBy = (attempt.prior?.phase === "creating" || attempt.prior?.phase === "capturing") ? attempt.prior.createdBy : actorRef(caller.value.actor);
    const limits = yield* TenantLimits;
    const createdAt = attempt.prior?.phase === "capturing" ? new Date(attempt.prior.createdAt) : new Date(yield* Clock.currentTimeMillis);
    let intent: RetainedVmCreation | undefined = attempt.prior?.phase === "creating" ? attempt.prior.intent : undefined;
    const dispatch = attempt.prior?.phase === "creating" ? attempt.prior.dispatch : { state: "ready" as const, token: crypto.randomUUID() };
    const journal = {
      active: limits.creationActive(caller.value.tenantId, attempt.key, cmuxId).pipe(
        Effect.mapError(() => new UpstreamError({ operation: "createFence", status: null })),
        Effect.flatMap((active) => active ? Effect.void : Effect.fail(new UpstreamError({ operation: "createCancelled", status: null }))),
      ),
      beginSend: () => Effect.gen(function* () {
        // A recorded allocation is never sent again. Nothing at its exact slug may only be propagation until the
        // send's grace window has passed; after it, the recorded upstream id is checked before the VM counts as gone.
        if (attempt.prior?.phase === "creating") {
          const recorded = yield* store.allocationStatus(caller.value.tenantId, cmuxId).pipe(Effect.mapError(() => new UpstreamError({ operation: "createFence", status: null })));
          if (recorded !== "absent") {
            const sent = attempt.prior.dispatch, now = yield* Clock.currentTimeMillis;
            const settled = recorded === "pending" && sent !== undefined && (sent.state !== "sent" || (sent.at !== undefined && now - sent.at >= CREATE_SEND_GRACE_MS));
            return yield* Effect.fail(new UpstreamError({ operation: settled ? "createGone" : "createSendUncertain", status: null }));
          }
        }
        const token = crypto.randomUUID();
        const allowed = yield* limits.beginCreateSend(caller.value.tenantId, attempt.key, cmuxId, token).pipe(Effect.mapError(() => new UpstreamError({ operation: "createFence", status: null })));
        if (!allowed) return yield* Effect.fail(new UpstreamError({ operation: "createSendUncertain", status: null }));
        return token;
      }),
      rejected: (token: string) => limits.rejectCreateSend(caller.value.tenantId, attempt.key, cmuxId, token).pipe(Effect.mapError(() => new UpstreamError({ operation: "createSendReceipt", status: null }))),
      context: attempt.prior?.phase === "creating" ? attempt.prior.context : null,
      beforeSend: (context: string, probe: VmCreationProbe) => {
        intent ??= { receipt: attempt.prior?.phase === "capturing" ? attempt.prior.receipt : { id: cmuxId, displayName: spec.displayName, labels: spec.labels, idleTimeoutSeconds: spec.idleTimeoutSeconds,
          ...(proofs.image === undefined ? {} : { bootImage: vmImageEvidenceOf(proofs.image).receipt }),
          ...(proofs.network === undefined ? {} : { initialNetwork: vmNetworkEvidenceOf(proofs.network).receipt }),
        }, probe, floors: spec.size ?? {}, createdAt: createdAt.toISOString() };
        return limits.advance(caller.value.tenantId, attempt.key, { phase: "creating", vmId: cmuxId, reservationId: proofs.mayCreate.reservationId, context, createdBy, intent, ...(dispatch === undefined ? {} : { dispatch }), ...(attempt.snapshotId === undefined ? {} : { snapshotId: attempt.snapshotId }) }).pipe(
          Effect.mapError(() => new UpstreamError({ operation: "persistCreateIntent", status: null })),
        );
      },
    };
    const attempted = yield* upstream
      .createVm(
        caller,
        {
          cmuxId,
          createdBy,
          idleTimeoutSeconds: spec.idleTimeoutSeconds,
          ...(spec.maxRunSeconds === undefined ? {} : { maxRunSeconds: spec.maxRunSeconds }),
          ...(spec.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: spec.autoDeleteSeconds }),
          ...(spec.size === undefined ? {} : { size: spec.size }),
          environment: policy.environment,
          journal,
        },
        proofs,
      )
      .pipe(Effect.either);
    if (Either.isLeft(attempted)) {
      const error = attempted.left;
      if (error.operation === "createGone") {
        // The uncommitted VM was deleted provider-side (e.g. by autoDeleteSeconds) only if its recorded id is gone
        // too; any other answer keeps it pending. Then tombstone it and settle its intent once, so the retry
        // answers like any deleted allocation and nothing new is created.
        const vanished = yield* name(cmuxId, (vm) => Effect.gen(function* () {
          const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
          if (owns === null) return false;
          return yield* upstream.getVmForWrite(vm, { owns, scope: proofs.scope }).pipe(
            Effect.as(false),
            Effect.catchAll((failure) => failure.status === 404 ? Effect.succeed(true) : Effect.fail(unavailable())),
          );
        }));
        if (!vanished) return yield* Effect.fail(unavailable());
        yield* store.markDeleted(caller.value.tenantId, "vm", cmuxId, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => unavailable()));
        yield* settleDeletedCreation(caller, proofs.scope, cmuxId);
        return yield* Effect.fail(vmNotFound());
      }
      return yield* Effect.fail(proofs.image !== undefined && (error.status === 400 || error.status === 404) ? unavailable() : onCreate(error));
    }
    const created = attempted.right;
    const grown = spec.size === undefined ? Either.right(created.vm) : yield* Effect.either(created.grow(spec.size));
    const record = (committed: boolean) => journal.active.pipe(Effect.zipRight(store.record({
      tenantId: caller.value.tenantId,
      kind: "vm",
      cmuxId,
      upstreamId: created.upstreamId,
      createdBy,
      createdAt: intent === undefined ? createdAt : new Date(intent.createdAt),
      ...(intent === undefined ? {} : { creation: { key: attempt.key, receipt: intent.receipt } }),
      displayName: spec.displayName,
      labels: spec.labels,
      ...(committed ? {} : { committed: false }),
    })));
    if (Either.isLeft(grown)) {
      // Recorded but uncommitted: the owner can list and delete it while the intent keeps its quota slot;
      // only a same-key retry or reconcile that reaches the floors commits it. A failed write leaves the intent.
      yield* record(false).pipe(Effect.ignore);
      return yield* Effect.fail(grown.left.status === 429
        ? new QuotaExceeded({ message: "VM capacity is exhausted for now; retry later", retryAfterSeconds: 60, budget: "capacity" })
        : unavailable());
    }
    yield* record(true).pipe(Effect.mapError(() => unavailable()));
    return toVm(cmuxId, spec, grown.right);
    // Uninterruptible: a client that disconnects mid-create must not leave an
    // upstream VM that is neither recorded nor discarded.
  }).pipe(Effect.uninterruptible);

/**
 * A committed ownership row repairs completion without allocating again, including after deletion.
 * An uncommitted row is resumed like an unrecorded allocation: the retry grows the same VM.
 */
const replayRecordedAttempt = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, prior: IdempotencyProgress | null, key: string | null) => Effect.gen(function* () {
  if (prior?.phase !== "creating" || key === null) return null;
  const status = yield* (yield* OwnershipStore).allocationStatus(caller.value.tenantId, prior.vmId).pipe(Effect.mapError(() => unavailable()));
  if (status === "absent" || status === "pending") return null;
  yield* (yield* TenantLimits).advance(caller.value.tenantId, key, { phase: "done", vmId: prior.vmId }).pipe(Effect.mapError(() => unavailable()));
  if (status === "deleted") return yield* Effect.fail(vmNotFound());
  return yield* replayVm(caller, scope, prior.vmId);
});

const resumeSlot = (key: string | null, prior: IdempotencyProgress | null) => key !== null && (prior?.phase === "creating" || prior?.phase === "capturing") ? { key, vmId: prior.vmId } : undefined;

const createVm = (requested: CreateVmRequest, idempotencyKey: string | undefined) =>
  withCaller("vm:write", "write", (caller, scope) =>
    Effect.gen(function* () {
      const principal = caller.value;
      yield* forbidAllowlisted(principal);
      // An agent key's VMs get its labels without asking; a label naming another agent is refused.
      const payload = yield* withAgentLabels(principal, requested);
      yield* requireServiceLabels(principal, payload.labels ?? {});
      if (payload.image !== undefined && payload.snapshotId !== undefined) return yield* Effect.fail(badRequest("Choose either an approved image or a tenant snapshot"));
      const network = payload.initialNetwork === undefined ? undefined : yield* vmNetworkAllowed(caller, payload.initialNetwork);
      const networkIntent = network === undefined ? undefined : vmNetworkEvidenceOf(network);
      const request = [
        "createVm",
        payload.displayName ?? null,
        payload.snapshotId ?? null,
        payload.resources === undefined ? null : [payload.resources.vcpus ?? null, payload.resources.memoryMib ?? null, payload.resources.diskMib ?? null],
        payload.idleTimeoutSeconds ?? null,
        payload.maxRunSeconds ?? null,
        payload.autoDeleteSeconds ?? null,
        sortedLabels(payload.labels),
      ];
      // Omitted network must keep the exact fingerprint of pre-feature creates.
      if (networkIntent !== undefined) request.push(networkIntent.fingerprint);
      const clientFingerprint = payload.image === undefined ? undefined : yield* requestFingerprint(["createVm:client:v1", request, payload.image.id, payload.image.revision]);
      const imageDecision = payload.image === undefined ? undefined : yield* Effect.either(vmImageAllowed(caller, payload.image));
      if (imageDecision?._tag === "Left" && payload.image !== undefined) {
        return yield* recoverWithdrawnImage(caller, scope, idempotencyKey, clientFingerprint, payload.image, imageDecision.left);
      }
      const image = imageDecision?._tag === "Right" ? imageDecision.right : undefined;
      const imageIntent = image === undefined ? undefined : vmImageEvidenceOf(image);
      const idleTimeoutSeconds = yield* idleOrFail(principal, payload.idleTimeoutSeconds);
      const spec: NewVm = {
        displayName: payload.displayName ?? null,
        labels: payload.labels ?? {},
        idleTimeoutSeconds,
        maxRunSeconds: payload.maxRunSeconds,
        autoDeleteSeconds: payload.autoDeleteSeconds,
        size: payload.resources,
      };
      if (imageIntent !== undefined) request.push(`image:${imageIntent.fingerprint}`);
      const generated = idempotencyKey === undefined ? yield* issueCreation(principal, "create", payload) : undefined;
      const effectiveKey = generated?.key ?? idempotencyKey;
      if (effectiveKey === undefined) return yield* Effect.fail(unavailable());
      return yield* creationResult(principal, effectiveKey, idempotent(
        principal,
        effectiveKey,
        request,
        (prior, key) =>
          Effect.gen(function* () {
            const existing = yield* replayRecordedAttempt(caller, scope, prior, key);
            if (existing !== null) return existing;
            if (key === null) return yield* Effect.fail(unavailable());
            // A fresh allocation by an agent key must fit its live-VM and $/h budget; a resumed one already counted.
            if (resumeSlot(key, prior) === undefined) yield* agentBudgetAllows(caller, scope, payload.resources);
            const attempt = { key, prior };
            if (payload.snapshotId === undefined) {
              return yield* withCreateSlot(caller, (mayCreate) => createRecorded(caller, spec, { mayCreate, scope, ...(network === undefined ? {} : { network }), ...(image === undefined ? {} : { image }) }, attempt), resumeSlot(key, prior));
            }
            return yield* name(payload.snapshotId, (snapshot) =>
              Effect.gen(function* () {
                const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.mapError(() => unavailable()));
                if (owns === null) return yield* Effect.fail(snapshotNotFound());
                return yield* withCreateSlot(caller, (mayCreate) =>
                  createRecorded(caller, spec, { mayCreate, scope, source: { snapshot, owns }, ...(network === undefined ? {} : { network }) }, attempt),
                  resumeSlot(key, prior),
                );
              }),
            );
          }),
        (vmId) => replayVm(caller, scope, vmId),
        clientFingerprint,
        generated,
      ).pipe(Effect.map((vm) => new CreatedVm({ ...vm, ...(networkIntent === undefined ? {} : { initialNetwork: networkIntent.receipt }), ...(imageIntent === undefined ? {} : { bootImage: imageIntent.receipt }) }))), generated);
    }),
  );

const FORK_INCOMPLETE_MESSAGE =
  "The snapshot was taken but the VM allocation could not be confirmed. The snapshot is kept in your team; inspect or retry with the original Idempotency-Key or returned creationKey.";

/**
 * Fork = snapshot + create + delete the snapshot. Not atomic:
 * - snapshot acquisition is journaled before I/O. Unknown outcomes hold both
 *   quotas; retries recover the same intermediate, even after source deletion.
 * - snapshot succeeds, create fails: 503 ForkIncomplete naming the snapshot,
 *   which stays in the ownership table for the caller's tenant (and expires
 *   upstream after a day unused). With an Idempotency-Key the key remembers
 *   the snapshot, so a retry creates from it without taking a second one.
 * - both succeed: the snapshot is deleted by its exact id; a failed cleanup
 *   leaves it to expire.
 */
const forkVm = (rawVmId: string, payload: ForkVmRequest, idempotencyKey: string | undefined) =>
  withCaller("vm:write", "write", (caller, scope) =>
    Effect.gen(function* () {
      const parsedSource = parseVmId(rawVmId);
      if (Option.isNone(parsedSource)) return yield* Effect.fail(vmNotFound());
      return yield* name(parsedSource.value, (source) => Effect.gen(function* () {
        const principal = caller.value;
        if (principal.agent !== undefined) {
          return yield* Effect.fail(new Forbidden({ message: "An agent key cannot fork; create a VM instead" }));
        }
        const request = [
          "forkVm",
          source.value,
          payload.displayName ?? null,
          payload.idleTimeoutSeconds ?? null,
          payload.maxRunSeconds ?? null,
          payload.autoDeleteSeconds ?? null,
          sortedLabels(payload.labels),
        ];
        const limits = yield* TenantLimits;
        const generated = idempotencyKey === undefined ? yield* issueCreation(principal, "fork", payload, source.value) : undefined;
        const effectiveKey = generated?.key ?? idempotencyKey;
        if (effectiveKey === undefined) return yield* Effect.fail(unavailable());
        // An older fork may have sent its snapshot while still merely "claimed".
        // Never turn that missing capture receipt into permission to take another one.
        if (principal.resourceAllowlist === null) {
          const priorKey = yield* scopedCreationKey(principal, effectiveKey);
          const prior = yield* limits.inspect(principal.tenantId, priorKey).pipe(Effect.mapError(() => unavailable()));
          if ((prior?.progress.phase === "claimed" || prior?.progress.phase === "pending")
            && (yield* limits.quarantineForkClaim(principal.tenantId, priorKey).pipe(Effect.mapError(() => unavailable()))))
            return yield* Effect.fail(conflict("This fork has no durable capture receipt; its earlier outcome needs reconciliation"));
        }
        return yield* creationResult(principal, effectiveKey, idempotent(
          principal,
          effectiveKey,
          request,
          (resumeFrom, keyed) => Effect.gen(function* () {
            if (keyed === null) return yield* Effect.fail(unavailable());
            // Once a snapshot is retained, the source is no longer an input to this attempt.
            // Completed retries authorize the destination above; fresh forks still prove the source.
            const retainedSnapshot = resumeFrom?.phase === "snapshotted" || resumeFrom?.phase === "creating" || resumeFrom?.phase === "capturing";
            const sourceOwns = retainedSnapshot ? null : yield* tenantOwnsVm(caller, source).pipe(Effect.mapError(() => unavailable()));
            if (!retainedSnapshot && sourceOwns === null) return yield* Effect.fail(vmNotFound());
            yield* forbidAllowlisted(principal);
            yield* requireServiceLabels(principal, payload.labels ?? {});
            const existing = yield* replayRecordedAttempt(caller, scope, resumeFrom, keyed);
            if (existing !== null) {
              if (resumeFrom?.phase === "creating" && resumeFrom.snapshotId !== undefined) yield* cleanupForkSnapshot(caller, scope, resumeFrom.snapshotId);
              return existing;
            }
            const idleTimeoutSeconds = yield* idleOrFail(principal, payload.idleTimeoutSeconds);
            const spec: NewVm = {
              displayName: payload.displayName ?? null,
              labels: payload.labels ?? {},
              idleTimeoutSeconds,
              maxRunSeconds: payload.maxRunSeconds,
              autoDeleteSeconds: payload.autoDeleteSeconds,
              size: undefined,
            };
            return yield* withCreateSlot(caller, (mayCreate) =>
              Effect.gen(function* () {
                let snapshotId: string;
                if (resumeFrom?.phase === "creating") {
                  if (resumeFrom.snapshotId === undefined) return yield* Effect.fail(unavailable());
                  snapshotId = resumeFrom.snapshotId;
                } else if (resumeFrom?.phase === "snapshotted") {
                  snapshotId = resumeFrom.snapshotId;
                } else {
                  let parent: ForkCaptureProgress;
                  if (resumeFrom?.phase === "capturing") parent = resumeFrom;
                  else {
                    if (sourceOwns === null) return yield* Effect.fail(vmNotFound());
                    const vmId = newVmId();
                    parent = { phase: "capturing", vmId, sourceVmId: source.value, snapshotId: newSnapshotId(),
                      captureKey: yield* scopedForkSnapshotKey(keyed), reservationId: mayCreate.reservationId,
                      createdBy: actorRef(principal.actor), createdAt: new Date(yield* Clock.currentTimeMillis).toISOString(),
                      receipt: { id: vmId, displayName: spec.displayName, labels: spec.labels, idleTimeoutSeconds: spec.idleTimeoutSeconds } };
                    yield* limits.advance(principal.tenantId, keyed, parent).pipe(Effect.mapError(() => unavailable()));
                  }
                  snapshotId = yield* acquireForkSnapshot(caller, source, scope, keyed, parent, generated !== undefined);
                  resumeFrom = parent;
                }
                const parsed = parseSnapshotId(snapshotId);
                if (Option.isNone(parsed)) return yield* Effect.fail(unavailable());
                return yield* name(parsed.value, (snapshot) =>
                  Effect.gen(function* () {
                    const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.mapError(() => unavailable()));
                    if (owns === null) {
                      return yield* Effect.fail(conflict("The snapshot from the first attempt is gone; retry with a new Idempotency-Key"));
                    }
                    const vm = yield* createRecorded(caller, spec, { mayCreate, scope, source: { snapshot, owns } }, { key: keyed, prior: resumeFrom, snapshotId }).pipe(
                      Effect.mapError(() => new ForkIncomplete({ message: FORK_INCOMPLETE_MESSAGE, snapshotId: snapshot.value })),
                    );
                    yield* cleanupForkSnapshot(caller, scope, snapshot.value);
                    return vm;
                  }),
                );
              }),
              resumeSlot(keyed, resumeFrom),
            );
          }),
          (vmId) => forbidAllowlisted(principal).pipe(
            Effect.zipRight(requireServiceLabels(principal, payload.labels ?? {})),
            Effect.zipRight(replayVm(caller, scope, vmId)),
          ),
          undefined,
          generated,
        ), generated);
      }));
    }),
  );

const LIST_DEFAULT_LIMIT = 50;

const ListCursor = Schema.Struct({ v: Schema.Literal(1), t: Schema.String, c: Schema.String, i: Schema.String });
const decodeCursorJson = Schema.decodeUnknownOption(Schema.parseJson(ListCursor));

const encodeCursor = (tenantId: string, position: { readonly createdAt: Date; readonly cmuxId: string }) =>
  btoa(JSON.stringify({ v: 1, t: tenantId, c: position.createdAt.toISOString(), i: position.cmuxId }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");

/** A cursor names a position in the caller's own list; another tenant's or a garbled one is 400. */
const decodeCursor = (tenantId: string, cursor: string) => {
  let text: string;
  try {
    text = atob(cursor.replaceAll("-", "+").replaceAll("_", "/"));
  } catch {
    return Option.none();
  }
  return decodeCursorJson(text).pipe(
    Option.filter((parsed) => parsed.t === tenantId && Option.isSome(parseVmId(parsed.i)) && !Number.isNaN(Date.parse(parsed.c))),
    Option.map((parsed) => ({ createdAt: new Date(parsed.c), cmuxId: parsed.i })),
  );
};

const parseLabelSelectors = (selectors: ReadonlyArray<string> | undefined): Readonly<Record<string, string>> | null => {
  if (selectors === undefined || selectors.length === 0) return null;
  return Object.fromEntries(
    selectors.map((selector) => {
      const at = selector.indexOf("=");
      return [selector.slice(0, at), selector.slice(at + 1)];
    }),
  );
};

const listVms = (params: {
  readonly createdBy?: "caller" | undefined;
  readonly limit?: number | undefined;
  readonly cursor?: string | undefined;
  readonly state?: VmState | undefined;
  readonly label?: ReadonlyArray<string> | undefined;
}) =>
  withCaller("vm:read", "read", (caller, scope) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      const tenantId = caller.value.tenantId;
      let after: { readonly createdAt: Date; readonly cmuxId: string } | null = null;
      if (params.cursor !== undefined) {
        const decoded = decodeCursor(tenantId, params.cursor);
        if (Option.isNone(decoded)) return yield* Effect.fail(badRequest("cursor is not valid for this list"));
        after = decoded.value;
      }
      const limit = params.limit ?? LIST_DEFAULT_LIMIT;
      const page = yield* visitOwnedVms(caller, { limit, after, labels: parseLabelSelectors(params.label), createdByCaller: params.createdBy === "caller" }, (vm, owns, row) =>
        upstream.getVm(vm, { owns, scope }).pipe(
          Effect.map((current) => Option.some(toVm(vm.value, row, current))),
          // A VM gone upstream is left out; its row is cleaned up by delete or a sweep.
          Effect.catchIf(
            (error) => error.status === 404,
            () => Effect.succeed(Option.none<Vm>()),
          ),
          Effect.mapError(() => unavailable()),
        ),
      ).pipe(Effect.catchTag("StoreError", () => Effect.fail(unavailable())));
      const items = page.results.flatMap((item) =>
        Option.isSome(item) && (params.state === undefined || item.value.state === params.state) ? [item.value] : [],
      );
      return new VmList({
        items,
        nextCursor: page.fetched === limit && page.last !== null ? encodeCursor(tenantId, page.last) : null,
      });
    }),
  );

/**
 * Whether the caller's tenant already deleted this VM (same allowlist and service-label rules as a live one).
 * A delete that failed after its tombstone left the slot settlement to this retry.
 */
const deletedEarlier = (rawId: string) =>
  Effect.gen(function* () {
    const principal = yield* CurrentPrincipal;
    const parsed = parseVmId(rawId);
    if (Option.isNone(parsed)) return false;
    return yield* name(principal, parsed.value, (caller, vm) => Effect.gen(function* () {
      const gone = yield* tenantDeletedVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
      const scope = keyHasScope(caller, "vm:write");
      if (gone && scope !== null) yield* settleDeletedCreation(caller, scope, vm.value);
      return gone;
    }));
  });

/**
 * Deletes one VM the current principal owns: fences an uncommitted creation,
 * deletes it upstream, records the tombstone, settles its creation intent and
 * revokes its client sessions. Idempotent for the caller's own deleted VM.
 * The HTTP handler and the agent reaper share it.
 */
export const deleteVmById = (rawVmId: string) =>
  audited(
    "vm.delete",
    auditableVmId(rawVmId),
    withOwnedVm(rawVmId, "vm:write", "write", (caller, vm, proofs) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamClient;
        const store = yield* OwnershipStore;
        const limits = yield* TenantLimits;
        const tenantId = TenantId.make(caller.value.tenantId);
        // Deleting an uncommitted VM cancels its creation: fence the intent first so a retry cannot commit it.
        const pending = proofs.owns.committed ? null : yield* store.creationKey(tenantId, vm.value).pipe(Effect.mapError(() => unavailable()));
        if (pending !== null) yield* limits.cancelCreation(tenantId, pending, vm.value).pipe(Effect.mapError(() => unavailable()));
        // "gone" (already deleted upstream) still forgets the VM here.
        yield* upstream.deleteVm(vm, proofs).pipe(Effect.mapError(() => unavailable()));
        const now = new Date(yield* Clock.currentTimeMillis);
        yield* store
          .markDeleted(tenantId, "vm", vm.value, now)
          .pipe(Effect.mapError(() => unavailable()));
        yield* settleDeletedCreation(caller, proofs.scope, vm.value);
        // Its client-session tokens die with it; a failed revoke is retried by the reaper.
        yield* revokeVmClientSessions(tenantId, vm.value).pipe(Effect.ignore);
      }),
    ).pipe(
      // Idempotent: the caller's own already-deleted VM answers 204 again, so a lost 204 never wedges the retry.
      Effect.catchTag("NotFound", (missing) =>
        deletedEarlier(rawVmId).pipe(Effect.flatMap((gone) => (gone ? Effect.void : Effect.fail(missing)))),
      ),
    ),
  );

export const vmsHandlers = HttpApiBuilder.group(CmuxVmApi, "vms", (handlers) =>
  handlers
    .handle("getVmInstanceIdentity", ({ path, urlParams }) => withOwnedVm(path.vmId, "vm:read", "read", (_caller, vm, proofs) => Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      const fingerprint = yield* upstream.instanceFingerprint(vm, proofs);
      const presence = urlParams.checkPresence === "true" ? yield* upstream.getVm(vm, proofs).pipe(
        Effect.map(() => "present" as const),
        Effect.catchAll((error) => error.status === 404 ? Effect.succeed("missing" as const) : Effect.fail(unavailable())),
      ) : undefined;
      return new VmInstanceIdentity({ id: vm.value, scheme: INSTANCE_IDENTITY_SCHEME, fingerprint, ...(presence === undefined ? {} : { presence }) });
    })))
    .handle("retireVm", ({ path }) => audited("vm.retire", auditableVmId(path.vmId), retireVm(path.vmId)))
    .handle("getVm", ({ path }) =>
      withOwnedVm(path.vmId, "vm:read", "read", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const current = yield* upstream.getVm(vm, proofs).pipe(Effect.mapError(onRead));
          return toVm(vm.value, proofs.owns, current);
        }),
      ),
    )
    .handle("createVm", ({ payload, headers }) =>
      audited("vm.create", null, createVm(payload, headers["idempotency-key"]), (vm) => vm.id),
    )
    .handle("listVms", ({ urlParams }) => listVms(urlParams))
    .handle("resizeVm", ({ path, payload, headers }) =>
      audited("vm.resize", auditableVmId(path.vmId), resizeVm(path.vmId, payload, headers["idempotency-key"])),
    )
    .handle("listVmImages", () => withCaller("vm:read", "read", (caller) => visibleVmImages(caller).pipe(Effect.map((items) => new VmImageList({ items })))))
    .handle("replaceVmHttpsProxy", ({ path, payload, headers }) =>
      audited("vm.https_proxy.replace", auditableVmId(path.vmId), replaceVmHttpsProxy(path.vmId, path.hostname, payload, headers["idempotency-key"]), (receipt) => receipt.id),
    )
    .handle("startVm", ({ path }) =>
      audited(
        "vm.start",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const started = yield* upstream
              .startVm(vm, proofs)
              .pipe(Effect.mapError(onVm("The VM cannot start now: it no longer exists or no capacity is available")));
            return toVm(vm.value, proofs.owns, started);
          }),
        ),
      ),
    )
    .handle("resumeVm", ({ path }) =>
      audited(
        "vm.resume",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const current = yield* upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onRead));
            if (current.state !== "paused") {
              return yield* Effect.fail(conflict("Only a paused VM can be resumed; use start to boot a stopped VM"));
            }
            const resumed = yield* upstream
              .startVm(vm, proofs)
              .pipe(Effect.mapError(onVm("The VM cannot resume now: no capacity is available")));
            return toVm(vm.value, proofs.owns, resumed);
          }),
        ),
      ),
    )
    .handle("pauseVm", ({ path }) =>
      audited(
        "vm.pause",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const paused = yield* upstream.pauseVm(vm, proofs).pipe(Effect.mapError(onVm("Only a running VM can be paused")));
            return toVm(vm.value, proofs.owns, paused);
          }),
        ),
      ),
    )
    .handle("stopVm", ({ path }) =>
      audited(
        "vm.stop",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const current = yield* upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onRead));
            if (current.state === "stopped") return toVm(vm.value, proofs.owns, current);
            if (current.state !== "running") {
              return yield* Effect.fail(conflict("Only a running VM can be stopped; resume a paused VM first"));
            }
            yield* upstream.shutdownVm(vm, proofs).pipe(Effect.mapError(onVm("The VM did not accept the shutdown")));
            const after = yield* upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onRead));
            return toVm(vm.value, proofs.owns, after);
          }),
        ),
      ),
    )
    .handle("forkVm", ({ path, payload, headers }) =>
      audited(
        "vm.fork",
        auditableVmId(path.vmId),
        forkVm(path.vmId, payload, headers["idempotency-key"]),
        (vm) => vm.id,
        (error) => (error instanceof ForkIncomplete ? error.snapshotId : null),
      ),
    )
    .handle("deleteVm", ({ path }) => deleteVmById(path.vmId))
);
