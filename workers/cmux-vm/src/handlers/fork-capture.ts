/** A fork's intermediate uses the same durable capture protocol as a saved snapshot. */
import { name, type Named } from "@gdp-ts/core";
import { Effect } from "effect";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import type { Principal } from "../domain/principal.ts";
import { unavailable } from "../errors.ts";
import type { VmId } from "../lib/ids.ts";
import type { ForkCaptureProgress } from "../limits/ledger.ts";
import { TenantLimits } from "../limits/service.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { forkSnapshotAccess } from "../proofs/snapshot-capture.ts";
import { readVmCreation } from "../proofs/vm-creation.ts";
import { DEFINITE, reconcileCapturedSnapshot, resumeSnapshotCapture } from "./snapshot-capture.ts";

export const acquireForkSnapshot = <C, V>(caller: Named<C, Principal>, source: Named<V, VmId>, scope: KeyHasScope<C, "vm:write">, key: string, parent: ForkCaptureProgress, unkeyed = false) =>
  name(parent.snapshotId, (snapshot) => Effect.gen(function* () {
    const access = yield* forkSnapshotAccess(caller, snapshot, key, scope);
    const result = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "begin", key: parent.captureKey,
      fingerprint: parent.captureKey, nonce: crypto.randomUUID(), intent: {
        id: parent.snapshotId, sourceVmId: parent.sourceVmId, displayName: null, labels: parent.receipt.labels,
        createdBy: parent.createdBy, createdAt: parent.createdAt, ttlSeconds: null, autoDeleteSeconds: 86400,
      } }).pipe(Effect.mapError(() => unavailable()));
    if (result.state !== "record" || result.record.intent.id !== parent.snapshotId) return yield* Effect.fail(unavailable());
    yield* resumeSnapshotCapture(caller, source, snapshot, access, result);
    return snapshot.value;
  })).pipe(
    // An unkeyed fork can never be retried by its caller: a definite refusal ends its intermediate capture
    // as cancelled, then settles the destination, so neither the snapshot slot nor the VM slot stays held.
    Effect.tapError((error) => unkeyed && DEFINITE.has(error._tag) ? Effect.gen(function* () {
      const limits = yield* TenantLimits, tenant = caller.value.tenantId;
      const child = yield* limits.snapshotCapture(tenant, { op: "cancel", id: parent.snapshotId });
      if (child.state !== "record" || child.record.state !== "cancelled") return;
      if ((yield* limits.cancelCreation(tenant, key, parent.vmId)) === "accepted") yield* limits.settleCancellation(tenant, key, parent.vmId);
    }).pipe(Effect.ignore) : Effect.void),
    Effect.uninterruptible,
  );

/** Reconciliation adopts or deletes existing effects only; it never sends a capture or VM create. */
export const reconcileForkCapture = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, rawKey: string, expectedId?: string) => Effect.gen(function* () {
  const limits = yield* TenantLimits, tenant = caller.value.tenantId, key = yield* scopedCreationKey(caller.value, rawKey);
  const record = yield* limits.inspect(tenant, key).pipe(Effect.mapError(() => unavailable()));
  const p = record?.progress;
  if (p?.phase !== "capturing") return null;
  const before = yield* readVmCreation(caller, rawKey);
  if (expectedId !== undefined && p.vmId !== expectedId) return yield* Effect.fail(unavailable());
  if (p.cancelled) return before;
  yield* name(p.snapshotId, (snapshot) => Effect.gen(function* () {
    const access = yield* forkSnapshotAccess(caller, snapshot, key, scope);
    const child = yield* limits.snapshotCapture(tenant, { op: "inspect", key: p.captureKey }).pipe(Effect.mapError(() => unavailable()));
    if (p.cancelRequested) {
      const fenced = yield* limits.snapshotCapture(tenant, { op: "fence", key: p.captureKey,
        expectedId: child.state === "absent" || child.state === "fenced" ? null : p.snapshotId,
        createdBy: p.createdBy, labels: p.receipt.labels }).pipe(Effect.mapError(() => unavailable()));
      if (fenced.state === "fenced" && fenced.granted) {
        yield* limits.settleCancellation(tenant, key, p.vmId).pipe(Effect.mapError(() => unavailable()));
        return;
      }
      if (fenced.state !== "record" || !fenced.granted || fenced.record.intent.id !== snapshot.value) return yield* Effect.fail(unavailable());
    } else if (child.state === "absent") return;
    const status = yield* reconcileCapturedSnapshot(caller, snapshot, access);
    if (p.cancelRequested && status.cancellation === "completed")
      yield* limits.settleCancellation(tenant, key, p.vmId).pipe(Effect.mapError(() => unavailable()));
  }));
  return yield* readVmCreation(caller, rawKey);
}).pipe(Effect.uninterruptible);
