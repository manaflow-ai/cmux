import { HttpApiBuilder } from "@effect/platform";
import { name } from "@gdp-ts/core";
import { Effect } from "effect";
import { CmuxVmApi } from "../api.ts";
import { OwnershipStore } from "../db/stores.ts";
import { unavailable } from "../errors.ts";
import { TenantLimits } from "../limits/service.ts";
import { pendingVmCreation, pendingVmCreationEvidenceOf, readVmCreation } from "../proofs/vm-creation.ts";
import { UpstreamClient } from "../upstream/client.ts";
import { audited, withCaller } from "./common.ts";
import { cleanupForkSnapshot } from "./vms.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";

const inspect = (key: string) => withCaller("vm:read", "read", (caller) => readVmCreation(caller, key));

const reconcile = (key: string) => withCaller("vm:write", "write", (caller, scope) => Effect.gen(function* () {
  const status = yield* readVmCreation(caller, key);
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
})).pipe(Effect.uninterruptible);

export const creationHandlers = HttpApiBuilder.group(CmuxVmApi, "vmCreations", (handlers) => handlers
  .handle("getVmCreation", ({ headers }) => inspect(headers["idempotency-key"]))
  .handle("reconcileVmCreation", ({ headers }) => audited("vm.create.reconcile", null, reconcile(headers["idempotency-key"]), (result) => result.id)));
