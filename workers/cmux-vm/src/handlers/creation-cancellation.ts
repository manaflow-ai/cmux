import { reconcileForkCapture } from "./fork-capture.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect } from "effect";
import type { Principal } from "../domain/principal.ts";
import { OwnershipStore } from "../db/stores.ts";
import { conflict, unavailable } from "../errors.ts";
import { TenantLimits } from "../limits/service.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { cancellingVmCreation, cancellingVmCreationEvidenceOf, pendingVmCreation, pendingVmCreationEvidenceOf, readVmCreation } from "../proofs/vm-creation.ts";
import { tenantOwnsVm } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { withCaller } from "./common.ts";
import { cleanupForkSnapshot } from "./fork-snapshot-cleanup.ts";

/** A prior cancellation is advanced only by verified identity, deletion and a durable tombstone. */
export const continueCancellation = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, key: string) => Effect.gen(function* () {
  const fork = yield* reconcileForkCapture(caller, scope, key);
  if (fork !== null) return fork;
  const status = yield* readVmCreation(caller, key);
  if (status.state === "cancelled" && status.id !== null) {
    const record = yield* (yield* TenantLimits).inspect(caller.value.tenantId, yield* scopedCreationKey(caller.value, key)).pipe(Effect.mapError(() => unavailable()));
    if (record?.progress.phase === "cancelled" && record.progress.vmId === status.id && record.progress.snapshotId !== undefined) yield* cleanupForkSnapshot(caller, scope, record.progress.snapshotId);
    return status;
  }
  if (status.state !== "cancelling" || status.id === null) return status;
  return yield* name(status.id, (vm) => Effect.gen(function* () {
    const cancelling = yield* cancellingVmCreation(caller, vm, key);
    if (cancelling === null) return yield* readVmCreation(caller, key);
    const retained = cancellingVmCreationEvidenceOf(cancelling), store = yield* OwnershipStore, limits = yield* TenantLimits;
    const allocation = yield* store.allocationStatus(caller.value.tenantId, vm.value).pipe(Effect.mapError(() => unavailable()));
    if (allocation !== "deleted") {
      const upstream = yield* UpstreamClient;
      const found = yield* upstream.inspectCancellingCreation(caller, vm, { cancelling, scope }).pipe(Effect.mapError(() => unavailable()));
      // Nothing at the exact slug: settle only once no earlier send can still be allocating.
      if (found === null && allocation === "absent") {
        if (!(yield* limits.settleAbsentCancellation(caller.value.tenantId, retained.key, vm.value).pipe(Effect.mapError(() => unavailable())))) return status;
        if (retained.snapshotId !== undefined) yield* cleanupForkSnapshot(caller, scope, retained.snapshotId);
        return yield* readVmCreation(caller, key);
      }
      if (found !== null) {
        const receipt = retained.intent.receipt;
        yield* store.record({ tenantId: caller.value.tenantId, kind: "vm", cmuxId: vm.value, upstreamId: found.upstreamId,
          createdBy: retained.createdBy, createdAt: new Date(retained.intent.createdAt), displayName: receipt.displayName, labels: receipt.labels,
          creation: { key: retained.key, receipt }, committed: false,
        }).pipe(Effect.mapError(() => unavailable()));
      }
      const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
      if (owns === null) return yield* Effect.fail(unavailable());
      yield* upstream.deleteCancellingCreation(caller, vm, { cancelling, owns, scope }).pipe(Effect.mapError(() => unavailable()));
      yield* store.markDeleted(caller.value.tenantId, "vm", vm.value, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => unavailable()));
    }
    yield* limits.settleCancellation(caller.value.tenantId, retained.key, vm.value).pipe(Effect.mapError(() => unavailable()));
    if (retained.snapshotId !== undefined) yield* cleanupForkSnapshot(caller, scope, retained.snapshotId);
    return yield* readVmCreation(caller, key);
  }));
});

export const cancelVmCreation = (key: string) => withCaller("vm:write", "write", (caller, scope) => Effect.gen(function* () {
  const status = yield* readVmCreation(caller, key);
  if (status.state === "deleted") return status;
  if (status.state === "cancelling" || status.state === "cancelled") return yield* continueCancellation(caller, scope, key);
  if (status.state !== "pending" || status.id === null) return yield* Effect.fail(conflict("Only a pending creation can be cancelled; delete a completed VM by its id"));
  const limits = yield* TenantLimits, scoped = yield* scopedCreationKey(caller.value, key);
  const prior = yield* limits.inspect(caller.value.tenantId, scoped).pipe(Effect.mapError(() => unavailable()));
  if (prior?.progress.phase === "capturing" && prior.progress.vmId === status.id) {
    const decision = yield* limits.cancelCreation(caller.value.tenantId, scoped, status.id).pipe(Effect.mapError(() => unavailable()));
    if (decision !== "accepted") return yield* Effect.fail(conflict("The creation changed; inspect its status"));
    return yield* continueCancellation(caller, scope, key);
  }
  yield* name(status.id, (vm) => Effect.gen(function* () {
    const pending = yield* pendingVmCreation(caller, vm, key);
    if (pending === null) return yield* Effect.fail(conflict("The creation changed; inspect its status"));
    const retained = pendingVmCreationEvidenceOf(pending);
    const decision = yield* (yield* TenantLimits).cancelCreation(caller.value.tenantId, retained.key, vm.value).pipe(Effect.mapError(() => unavailable()));
    if (decision === "legacy") return yield* Effect.fail(conflict("This legacy creation has no send receipt; reconcile it and delete the VM by its id"));
    if (decision === "finished") return yield* Effect.fail(conflict("The creation finished; inspect its status"));

  }));
  return yield* continueCancellation(caller, scope, key);
})).pipe(Effect.uninterruptible);
