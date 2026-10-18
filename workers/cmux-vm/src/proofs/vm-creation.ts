/** Trusted: retained creation evidence is usable only within the current caller's tenant and restrictions. */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import type { VmCreationState } from "../api/creations.ts";
import { scopedCreationKey } from "../auth/idempotency-key.ts";
import { OwnershipStore } from "../db/stores.ts";
import { actorRef, carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import type { RetainedVmCreation } from "../domain/vm-creation.ts";
import { unavailable, vmNotFound } from "../errors.ts";
import { parseVmId, type VmId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";

export interface CancellingVmCreation<C, V> extends Proof<"CancellingVmCreation", [C, V]> {}
const Cancelling = defineProof("CancellingVmCreation");

export interface PendingVmCreation<C, V> extends Proof<"PendingVmCreation", [C, V]> {}
export interface VmCreationEvidence { readonly key: string; readonly intent: RetainedVmCreation; readonly createdBy: string; readonly snapshotId?: string }
const Pending = defineProof("PendingVmCreation");
const evidence = new WeakMap<object, VmCreationEvidence>();
export const pendingVmCreationEvidenceOf = <C, V>(proof: PendingVmCreation<C, V>): VmCreationEvidence => {
  const value = evidence.get(proof);
  if (value === undefined) throw new Error("PendingVmCreation proof was not minted by src/proofs");
  return value;
};

const stateOf = (status: VmCreationState): VmCreationState => status;

const allowed = (principal: Principal, id: string, labels: Readonly<Record<string, string>>, createdBy: string) =>
  (principal.resourceAllowlist === null || principal.resourceAllowlist.has(id)) && carriesRequiredLabels(principal, labels)
  && (principal.actor.kind !== "service" || actorRef(principal.actor) === createdBy);

const lookup = <C>(caller: Named<C, Principal>, rawKey: string) => Effect.gen(function* () {
  const key = yield* scopedCreationKey(caller.value, rawKey);
  const record = yield* (yield* TenantLimits).inspect(caller.value.tenantId, key).pipe(Effect.mapError(() => unavailable()));
  const progress = record?.progress;
  const receipt = yield* (yield* OwnershipStore).findCreation(caller.value.tenantId, key).pipe(Effect.mapError(() => unavailable()));
  // A reused key may already have a new intent while an older SQL receipt still exists.
  const journalId = progress?.phase === "creating" || progress?.phase === "done" ? progress.vmId : null;
  if ((progress?.phase === "cancelled" || (progress?.phase === "creating" && progress.cancelRequested === true)) && progress.intent !== undefined) {
    if (!allowed(caller.value, progress.vmId, progress.intent.receipt.labels, progress.createdBy)
      || (receipt?.receipt.id === progress.vmId && !allowed(caller.value, progress.vmId, receipt.labels, receipt.createdBy))) return yield* Effect.fail(vmNotFound());
    const parsed = parseVmId(progress.vmId);
    if (Option.isNone(parsed) || parsed.value !== progress.intent.receipt.id) return yield* Effect.fail(unavailable());
    return { status: stateOf({ state: progress.phase === "cancelled" ? "cancelled" : "cancelling", id: parsed.value, receipt: progress.intent.receipt }),
      pending: { key, intent: progress.intent, createdBy: progress.createdBy, ...(progress.snapshotId === undefined ? {} : { snapshotId: progress.snapshotId }) } };
  }
  if (receipt !== null && (record === null || (journalId !== null && journalId === receipt.receipt.id))) {
    if (!allowed(caller.value, receipt.receipt.id, receipt.labels, receipt.createdBy)
      || !carriesRequiredLabels(caller.value, receipt.receipt.labels)) return yield* Effect.fail(vmNotFound());
    return { status: stateOf({ state: receipt.deleted ? "deleted" : "committed", id: receipt.receipt.id, receipt: receipt.receipt }), pending: null };
  }
  if (record === null) return yield* Effect.fail(vmNotFound());
  if (progress?.phase === "creating" && progress.intent !== undefined) {
    if (!allowed(caller.value, progress.vmId, progress.intent.receipt.labels, progress.createdBy)) return yield* Effect.fail(vmNotFound());
    const parsed = parseVmId(progress.vmId);
    if (Option.isNone(parsed) || parsed.value !== progress.intent.receipt.id) return yield* Effect.fail(unavailable());
    return { status: stateOf({ state: "pending", id: parsed.value, receipt: progress.intent.receipt }),
      pending: { key, intent: progress.intent, createdBy: progress.createdBy, ...(progress.snapshotId === undefined ? {} : { snapshotId: progress.snapshotId }) } };
  }
  // Legacy journals do not prove labels, image or network intent. Never reinterpret them as a new request.
  if (caller.value.actor.kind === "service" || caller.value.resourceAllowlist !== null || caller.value.requiredLabels !== undefined) return yield* Effect.fail(vmNotFound());
  return { status: stateOf({ state: "unresolved", id: null }), pending: null };
});

export const readVmCreation = <C>(caller: Named<C, Principal>, rawKey: string) => lookup(caller, rawKey).pipe(Effect.map((result) => result.status));

/** Re-read the intent before minting authority bound to this exact caller and public VM. */
export const pendingVmCreation = <C, V>(caller: Named<C, Principal>, vm: Named<V, VmId>, rawKey: string) => Effect.gen(function* () {
  const result = yield* lookup(caller, rawKey);
  if (result.status.state !== "pending" || result.pending === null || result.status.id !== vm.value) return null;
  const proof: PendingVmCreation<C, V> = Object.freeze({ ...Pending.prove(caller, vm) });
  evidence.set(proof, Object.freeze(result.pending));
  return proof;
});


export const cancellingVmCreationEvidenceOf = <C, V>(proof: CancellingVmCreation<C, V>): VmCreationEvidence => {
  const value = evidence.get(proof);
  if (value === undefined) throw new Error("CancellingVmCreation proof was not minted by src/proofs");
  return value;
};
export const cancellingVmCreation = <C, V>(caller: Named<C, Principal>, vm: Named<V, VmId>, rawKey: string) => Effect.gen(function* () {
  const result = yield* lookup(caller, rawKey);
  if (result.status.state !== "cancelling" || result.pending === null || result.status.id !== vm.value) return null;
  const proof: CancellingVmCreation<C, V> = Object.freeze({ ...Cancelling.prove(caller, vm) });
  evidence.set(proof, Object.freeze(result.pending));
  return proof;
});
