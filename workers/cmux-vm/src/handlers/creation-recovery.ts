/** Reconcile only an already admitted allocation; never create, grow or start a VM. */
import { name, type Named } from "@gdp-ts/core";
import { Effect } from "effect";
import { OwnershipStore } from "../db/stores.ts";
import type { Principal } from "../domain/principal.ts";
import { unavailable } from "../errors.ts";
import { TenantLimits } from "../limits/service.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { pendingVmCreation, pendingVmCreationEvidenceOf, readVmCreation } from "../proofs/vm-creation.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import { cleanupForkSnapshot } from "./fork-snapshot-cleanup.ts";

export const reconcileCreation = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, key: string, expectedId?: string) => Effect.gen(function* () {
  const status = yield* readVmCreation(caller, key);
  if (expectedId !== undefined && status.id !== expectedId) return yield* Effect.fail(unavailable());
  if (status.state === "cancelling" || status.state === "cancelled") return status;
  const limits = yield* TenantLimits;
  const scoped = yield* scopedCreationKey(caller.value, key);
  if (status.state !== "pending" || status.id === null) {
    if (status.id !== null && (status.state === "committed" || status.state === "deleted")) {
      const record = yield* limits.inspect(caller.value.tenantId, scoped).pipe(Effect.mapError(() => unavailable()));
      if (record?.progress.phase === "creating" && record.progress.vmId === status.id) {
        yield* limits.settleCreation(caller.value.tenantId, scoped, status.id).pipe(Effect.mapError(() => unavailable()));
      }
    }
    return status;
  }
  return yield* name(status.id, (vm) => Effect.gen(function* () {
    const pending = yield* pendingVmCreation(caller, vm, key);
    if (pending === null) return yield* readVmCreation(caller, key);
    const recovered = yield* (yield* UpstreamClient).recoverCreation(caller, vm, { pending, scope }).pipe(Effect.mapError(() => unavailable()));
    if (recovered === null) return status;
    // A simultaneous completion or key reuse must not adopt stale evidence.
    if ((yield* pendingVmCreation(caller, vm, key)) === null) return yield* readVmCreation(caller, key);
    const retained = pendingVmCreationEvidenceOf(pending);
    const receipt = retained.intent.receipt;
    yield* (yield* OwnershipStore).record({
      tenantId: caller.value.tenantId, kind: "vm", cmuxId: vm.value, upstreamId: recovered.upstreamId,
      createdBy: retained.createdBy, createdAt: new Date(retained.intent.createdAt),
      displayName: receipt.displayName, labels: receipt.labels, creation: { key: retained.key, receipt },
    }).pipe(Effect.mapError(() => unavailable()));
    yield* limits.settleCreation(caller.value.tenantId, retained.key, vm.value).pipe(Effect.mapError(() => unavailable()));
    if (retained.snapshotId !== undefined) yield* cleanupForkSnapshot(caller, scope, retained.snapshotId);
    return yield* readVmCreation(caller, key);
  }));
}).pipe(Effect.uninterruptible);
