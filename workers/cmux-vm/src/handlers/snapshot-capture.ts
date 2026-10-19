/** Capture admission and recovery share the durable operation; source contents are never captured twice. */
import { name, type Named } from "@gdp-ts/core";
import { scopedSnapshotKey } from "../auth/idempotency-key.ts";
import { Clock, Effect, Option } from "effect";
import { CreateSnapshotRequest, Snapshot, SnapshotCreationList, SnapshotCreationStatus, SnapshotSummary } from "../api/snapshots.ts";
import { SnapshotStore } from "../db/snapshots.ts";
import { actorRef, carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { Conflict, Forbidden, PaymentRequired, QuotaExceeded, NotFound, ServiceUnavailable, snapshotNotFound, unavailable, vmNotFound } from "../errors.ts";
import { newSnapshotId, parseSnapshotId, parseVmId, type SnapshotId, type VmId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import type { SnapshotCapture, SnapshotCaptureResult } from "../limits/snapshot-capture.ts";
import { authorizedSnapshotCapture, legacySnapshotCaptureStatus, snapshotFenceAllowed, snapshotCaptureEvidenceOf, type AuthorizedSnapshotCapture, type CaptureWriteScope } from "../proofs/snapshot-capture.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantMayCreate } from "../proofs/tenant-may-create.ts";
import { tenantOwnsCapturedSnapshot, tenantOwnsSnapshot, tenantOwnsVm } from "../proofs/tenant-owns-resource.ts";
import { UpstreamSnapshots, type CreatedSnapshot } from "../upstream/snapshots.ts";
import { audited, withCaller } from "./common.ts";

const digest = (value: unknown) => Effect.promise(async () => {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)));
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
});
const retained = (id: SnapshotId) => new ServiceUnavailable({ message: "The snapshot capture is unresolved; inspect or reconcile its pendingSnapshotId", pendingSnapshotId: id });
const rowOf = (record: SnapshotCapture) => ({ id: record.intent.id, sourceVmId: record.intent.sourceVmId,
  displayName: record.intent.displayName, labels: record.intent.labels, createdAt: new Date(record.intent.createdAt) });
const receiptOf = (record: SnapshotCapture) => new SnapshotSummary({ ...rowOf(record), createdAt: record.intent.createdAt });
const toSnapshot = (record: SnapshotCapture, created: CreatedSnapshot) => new Snapshot({ ...receiptOf(record),
  lastUsedAt: created.snapshot.lastUsedAt ?? null, ttlSeconds: created.snapshot.ttlSeconds ?? null, autoDeleteSeconds: created.snapshot.autoDeleteSeconds ?? null });

const slot = <C>(caller: Named<C, Principal>, resume?: SnapshotId) => Effect.gen(function* () {
  const decision = yield* tenantMayCreate(caller, "snapshot", resume === undefined ? undefined : { snapshotId: resume }).pipe(Effect.mapError(() => unavailable()));
  if (decision._tag === "not_entitled") return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include snapshots" }));
  if (decision._tag === "over_quota") return yield* Effect.fail(new QuotaExceeded({ message: `This team already has its limit of ${decision.limit} snapshots; delete one first`, budget: "snapshots", retryAfterSeconds: 60 }));
  return decision.proof;
});

const status = <C, S>(caller: Named<C, Principal>, snapshot: Named<S, SnapshotId>, proof: AuthorizedSnapshotCapture<C, S>) => Effect.gen(function* () {
  const record = snapshotCaptureEvidenceOf(proof);
  const row = yield* (yield* SnapshotStore).inspect(caller.value.tenantId, snapshot.value).pipe(Effect.mapError(() => retained(snapshot.value)));
  if (Option.isSome(row) && (!carriesRequiredLabels(caller.value, row.value.labels) || row.value.createdBy !== record.intent.createdBy)) return yield* Effect.fail(snapshotNotFound());
  return new SnapshotCreationStatus({ id: snapshot.value, receipt: receiptOf(record),
    retryCreate: record.state === "claimed" || (record.state === "pending" && (record.dispatch?.state === "ready" || record.dispatch?.state === "rejected")),
    state: record.state === "cancelled" || (Option.isSome(row) && row.value.deleted) ? "deleted" : record.state === "committed" ? "committed" : "pending",
    ...(record.state === "cancelling" ? { cancellation: "requested" as const } : record.state === "cancelled" ? { cancellation: "completed" as const } : {}),
  });
});

const commit = <C, S>(caller: Named<C, Principal>, snapshot: Named<S, SnapshotId>, proof: AuthorizedSnapshotCapture<C, S>, created: CreatedSnapshot) => Effect.gen(function* () {
  const record = snapshotCaptureEvidenceOf(proof);
  yield* (yield* SnapshotStore).record({ ...rowOf(record), tenantId: caller.value.tenantId, upstreamId: created.upstreamId, createdBy: record.intent.createdBy }).pipe(Effect.mapError(() => retained(snapshot.value)));
  const settled = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "commit", id: snapshot.value }).pipe(Effect.mapError(() => retained(snapshot.value)));
  if (settled.state !== "record" || !settled.granted) return yield* Effect.fail(retained(snapshot.value));
  return toSnapshot(record, created);
});

const replay = <C, S>(caller: Named<C, Principal>, snapshot: Named<S, SnapshotId>, scope: CaptureWriteScope<C, S>, capture?: AuthorizedSnapshotCapture<C, S>) => Effect.gen(function* () {
  const store = yield* SnapshotStore;
  const owns = yield* (capture === undefined ? tenantOwnsSnapshot(caller, snapshot) : tenantOwnsCapturedSnapshot(caller, snapshot, capture)).pipe(Effect.mapError(() => unavailable()));
  const row = yield* store.describe(caller.value.tenantId, snapshot.value).pipe(Effect.mapError(() => unavailable()));
  if (owns === null || Option.isNone(row)) return yield* Effect.fail(snapshotNotFound());
  const live = yield* (yield* UpstreamSnapshots).getSnapshot(snapshot, { owns, scope }).pipe(Effect.mapError((e) => e.status === 404 ? snapshotNotFound() : unavailable()));
  return new Snapshot({ ...row.value, createdAt: row.value.createdAt.toISOString(), lastUsedAt: live.lastUsedAt ?? null,
    ttlSeconds: live.ttlSeconds ?? null, autoDeleteSeconds: live.autoDeleteSeconds ?? null });
});

const runCapture = <C, V, S>(caller: Named<C, Principal>, vm: Named<V, VmId>, snapshot: Named<S, SnapshotId>, scope: CaptureWriteScope<C, S>) => Effect.gen(function* () {
  const capture = yield* authorizedSnapshotCapture(caller, snapshot), record = snapshotCaptureEvidenceOf(capture);
  if (record.state === "committed") return yield* replay(caller, snapshot, scope, capture);
  if (record.state !== "pending") return yield* Effect.fail(new Conflict({ message: "This snapshot capture cannot be sent", pendingSnapshotId: snapshot.value }));
  const upstream = yield* UpstreamSnapshots;
  const recovered = yield* upstream.recoverCapture(snapshot, { capture, scope }).pipe(Effect.mapError(() => retained(snapshot.value)));
  if (recovered !== null) return yield* commit(caller, snapshot, capture, recovered);
  const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => retained(snapshot.value)));
  if (owns === null) return yield* Effect.fail(vmNotFound());
  const mayCreate = yield* slot(caller, snapshot.value);
  const created = yield* upstream.capture(vm, snapshot, { owns, scope, mayCreate, capture }, caller.value.tenantId).pipe(Effect.mapError((error) =>
    error.status === 404 ? new NotFound({ message: "VM not found", pendingSnapshotId: snapshot.value }) : error.status === 409 ? new Conflict({ message: "The VM must be running or paused to snapshot it", pendingSnapshotId: snapshot.value }) : retained(snapshot.value)));
  return yield* commit(caller, snapshot, capture, created);
});

/** Shared admission and single-send path for ordinary captures and fork intermediates. */
export const resumeSnapshotCapture = <C, V, S>(caller: Named<C, Principal>, vm: Named<V, VmId>, snapshot: Named<S, SnapshotId>, scope: CaptureWriteScope<C, S>, result: Extract<SnapshotCaptureResult, { state: "record" }>) => Effect.gen(function* () {
  const limits = yield* TenantLimits;
  yield* authorizedSnapshotCapture(caller, snapshot);
  if (result.record.state === "claimed") {
    if (!result.granted) return yield* Effect.fail(new Conflict({ message: "This snapshot capture is being prepared; retry shortly", pendingSnapshotId: snapshot.value }));
    yield* Effect.gen(function* () {
      const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
      if (owns === null) return yield* Effect.fail(vmNotFound());
      const mayCreate = yield* slot(caller);
      yield* Effect.gen(function* () {
        const probe = yield* (yield* UpstreamSnapshots).prepareCapture(vm, { owns, scope }, result.record.intent).pipe(Effect.mapError(() => unavailable()));
        const prepared = yield* limits.snapshotCapture(caller.value.tenantId, { op: "prepare", id: snapshot.value,
          nonce: result.record.nonce, probe, reservationId: mayCreate.reservationId }).pipe(Effect.mapError(() => retained(snapshot.value)));
        if (prepared.state !== "record" || !prepared.granted) return yield* Effect.fail(retained(snapshot.value));
      }).pipe(Effect.ensuring(limits.release(caller.value.tenantId, mayCreate.reservationId)));
    }).pipe(Effect.tapError(() => limits.snapshotCapture(caller.value.tenantId, { op: "yield", id: snapshot.value }).pipe(Effect.ignore)));
  }
  return yield* runCapture(caller, vm, snapshot, scope);
});

export const createSnapshotCapture = (rawVm: string, payload: CreateSnapshotRequest, rawKey: string | undefined) => withCaller("snapshot:write", "write", (caller, scope) => Effect.gen(function* () {
  const parsed = parseVmId(rawVm);
  if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
  return yield* name(parsed.value, (vm) => Effect.gen(function* () {
    const limits = yield* TenantLimits, id = newSnapshotId();
    const key = yield* scopedSnapshotKey(rawKey ?? id);
    const fingerprint = yield* digest({ operation: "createSnapshot", vmId: vm.value, displayName: payload.displayName ?? null,
      labels: Object.fromEntries(Object.entries(payload.labels ?? {}).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)),
      ttlSeconds: payload.ttlSeconds ?? null, autoDeleteSeconds: payload.autoDeleteSeconds ?? null });
    const prior = yield* limits.snapshotCapture(caller.value.tenantId, { op: "inspect", key }).pipe(Effect.mapError(() => unavailable()));
    if (prior.state === "record") yield* name(prior.record.intent.id, (snapshot) => authorizedSnapshotCapture(caller, snapshot).pipe(Effect.asVoid));
    if (prior.state === "absent") {
      const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
      if (owns === null) return yield* Effect.fail(vmNotFound());
      if (!carriesRequiredLabels(caller.value, payload.labels ?? {})) return yield* Effect.fail(new Forbidden({ message: "Snapshot labels must include this credential's required labels" }));
    }
    const result = yield* limits.snapshotCapture(caller.value.tenantId, { op: "begin", key, fingerprint, nonce: crypto.randomUUID(), intent: {
      id, sourceVmId: vm.value, displayName: payload.displayName ?? null, labels: payload.labels ?? {},
      createdBy: actorRef(caller.value.actor), createdAt: new Date(yield* Clock.currentTimeMillis).toISOString(),
      ttlSeconds: payload.ttlSeconds ?? null, autoDeleteSeconds: payload.autoDeleteSeconds ?? null,
    } }).pipe(Effect.mapError(() => unavailable()));
    if (result.state === "fenced") {
      if (!snapshotFenceAllowed(caller.value, result.fence)) return yield* Effect.fail(snapshotNotFound());
      return yield* Effect.fail(new Conflict({ message: "This Idempotency-Key has been cancelled" }));
    }
    if (result.state === "mismatch") return yield* Effect.fail(new Conflict({ message: "This Idempotency-Key was already used with a different request" }));
    if (result.state === "legacyDone") {
      const oldId = parseSnapshotId(result.id);
      if (Option.isNone(oldId)) return yield* Effect.fail(unavailable());
      return yield* name(oldId.value, (snapshot) => replay(caller, snapshot, scope));
    }
    if (result.state !== "record") return yield* Effect.fail(unavailable());
    return yield* name(result.record.intent.id, (snapshot) => audited("snapshot.create", vm.value, resumeSnapshotCapture(caller, vm, snapshot, scope, result), (value) => value.id));
  }));
})).pipe(Effect.uninterruptible);

const withCapture = <A, E, R>(rawId: string, f: <C, S>(caller: Named<C, Principal>, snapshot: Named<S, SnapshotId>, scope: KeyHasScope<C, "snapshot:write">) => Effect.Effect<A, E, R>) =>
  withCaller("snapshot:write", "write", (caller, scope) => Effect.gen(function* () {
    const id = parseSnapshotId(rawId); if (Option.isNone(id)) return yield* Effect.fail(snapshotNotFound());
    return yield* name(id.value, (snapshot) => f(caller, snapshot, scope));
  }));

export const inspectSnapshotCaptureByKey = (key: string) => withCaller("snapshot:read", "read", (caller) => Effect.gen(function* () {
  const found = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "inspect", key: yield* scopedSnapshotKey(key) }).pipe(Effect.mapError(() => unavailable()));
  if (found.state === "legacyDone") return yield* legacySnapshotCaptureStatus(caller, found.id);
  if (found.state === "fenced") {
    if (!snapshotFenceAllowed(caller.value, found.fence)) return yield* Effect.fail(snapshotNotFound());
    return yield* Effect.fail(new Conflict({ message: "This Idempotency-Key has been cancelled" }));
  }
  if (found.state === "legacy") return yield* Effect.fail(new Conflict({ message: "This legacy capture has no recoverable operation record" }));
  if (found.state !== "record") return yield* Effect.fail(snapshotNotFound());
  return yield* name(found.record.intent.id, (snapshot) => authorizedSnapshotCapture(caller, snapshot).pipe(Effect.flatMap((proof) => status(caller, snapshot, proof))));
}));

export const inspectSnapshotCapture = (rawId: string) => withCaller("snapshot:read", "read", (caller) => Effect.gen(function* () {
  const id = parseSnapshotId(rawId); if (Option.isNone(id)) return yield* Effect.fail(snapshotNotFound());
  return yield* name(id.value, (snapshot) => authorizedSnapshotCapture(caller, snapshot).pipe(Effect.flatMap((proof) => status(caller, snapshot, proof))));
}));

export const listSnapshotCaptures = (cursor: string | undefined, limit: number) => withCaller("snapshot:read", "read", (caller) => Effect.gen(function* () {
  if (caller.value.resourceAllowlist !== null) return yield* Effect.fail(new Forbidden({ message: "A key limited to specific resources cannot list capture history" }));
  const page = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "list", limit, ...(cursor === undefined ? {} : { cursor }) }).pipe(Effect.mapError(() => unavailable()));
  if (page.state !== "page") return yield* Effect.fail(unavailable());
  const items = yield* Effect.forEach(page.items, (record) => name(record.intent.id, (snapshot) => authorizedSnapshotCapture(caller, snapshot).pipe(
    Effect.flatMap((proof) => status(caller, snapshot, proof)), Effect.catchTag("NotFound", () => Effect.succeed(null)))), { concurrency: 4 });
  return new SnapshotCreationList({ items: items.filter((item) => item !== null), nextCursor: page.nextCursor });
}));

export const reconcileCapturedSnapshot = <C, S>(caller: Named<C, Principal>, snapshot: Named<S, SnapshotId>, scope: CaptureWriteScope<C, S>) => Effect.gen(function* () {
  const capture = yield* authorizedSnapshotCapture(caller, snapshot), record = snapshotCaptureEvidenceOf(capture);
  if (record.state === "pending" || record.state === "cancelling") {
    const store = yield* SnapshotStore, upstream = yield* UpstreamSnapshots, limits = yield* TenantLimits;
    const existing = yield* store.inspect(caller.value.tenantId, snapshot.value).pipe(Effect.mapError(() => retained(snapshot.value)));
    if (Option.isSome(existing) && existing.value.deleted) {
      yield* limits.snapshotCapture(caller.value.tenantId, { op: record.state === "cancelling" ? "cancelled" : "commit", id: snapshot.value }).pipe(Effect.mapError(() => retained(snapshot.value)));
    } else {
      const recovered = yield* upstream.recoverCapture(snapshot, { capture, scope }).pipe(Effect.mapError(() => retained(snapshot.value)));
      if (recovered !== null) {
        if (record.state === "cancelling") {
          yield* store.record({ ...rowOf(record), tenantId: caller.value.tenantId, upstreamId: recovered.upstreamId, createdBy: record.intent.createdBy }).pipe(Effect.mapError(() => retained(snapshot.value)));
          yield* upstream.discardCreatedSnapshot(recovered).pipe(Effect.catchAll((e) => e.status === 404 ? Effect.void : Effect.fail(retained(snapshot.value))));
          yield* store.markDeleted(caller.value.tenantId, snapshot.value, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => retained(snapshot.value)));
          const settled = yield* limits.snapshotCapture(caller.value.tenantId, { op: "cancelled", id: snapshot.value }).pipe(Effect.mapError(() => retained(snapshot.value)));
          if (settled.state !== "record" || !settled.granted) return yield* Effect.fail(retained(snapshot.value));
        } else { yield* commit(caller, snapshot, capture, recovered); }
      } else if (record.state === "cancelling" && Option.isSome(existing)) {
        const owns = yield* tenantOwnsCapturedSnapshot(caller, snapshot, capture).pipe(Effect.mapError(() => retained(snapshot.value)));
        if (owns === null) return yield* Effect.fail(snapshotNotFound());
        yield* upstream.deleteSnapshot(snapshot, { owns, scope }).pipe(Effect.catchAll((error) => error.status === 404 ? Effect.void : Effect.fail(retained(snapshot.value))));
        yield* store.markDeleted(caller.value.tenantId, snapshot.value, new Date(yield* Clock.currentTimeMillis)).pipe(Effect.mapError(() => retained(snapshot.value)));
        const settled = yield* limits.snapshotCapture(caller.value.tenantId, { op: "cancelled", id: snapshot.value }).pipe(Effect.mapError(() => retained(snapshot.value)));
        if (settled.state !== "record" || !settled.granted) return yield* Effect.fail(retained(snapshot.value));
      }
    }
  }
  return yield* authorizedSnapshotCapture(caller, snapshot).pipe(Effect.flatMap((proof) => status(caller, snapshot, proof)));
});

export const reconcileSnapshotCapture = (id: string) => audited("snapshot.create.reconcile", id,
  withCapture(id, (caller, snapshot, scope) => reconcileCapturedSnapshot(caller, snapshot, scope)).pipe(Effect.uninterruptible), (value) => value.id);
export const cancelSnapshotCapture = (id: string) => audited("snapshot.create.cancel", id, withCapture(id, (caller, snapshot, scope) => Effect.gen(function* () {
  yield* authorizedSnapshotCapture(caller, snapshot);
  const cancelled = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "cancel", id: snapshot.value }).pipe(Effect.mapError(() => retained(snapshot.value)));
  if (cancelled.state !== "record" || !cancelled.granted) return yield* Effect.fail(new Conflict({ message: "This snapshot is already committed; delete it instead" }));
  return yield* reconcileCapturedSnapshot(caller, snapshot, scope);
})).pipe(Effect.uninterruptible), (value) => value.id);
