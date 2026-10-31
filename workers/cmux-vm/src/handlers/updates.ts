/**
 * Updating a VM (cx-b4h.2) and a snapshot (cx-b4h.9). Name and labels live in
 * the ownership row; limits and retention go to the provider through an
 * allowlisted PATCH (src/upstream/live-update.ts). Labels may never be used to
 * move a resource across an ownership boundary: labels starting with `cmux.`
 * (an agent key's `cmux.agent`, which its reaper follows) are frozen, and a
 * service or agent key must keep the labels it is confined to.
 */
import { Effect, Option } from "effect";
import type { UpdateVmRequest } from "../api.ts";
import { Snapshot, type UpdateSnapshotRequest } from "../api/snapshots.ts";
import { SnapshotStore } from "../db/snapshots.ts";
import { TenantLimits } from "../limits/service.ts";
import { OwnershipStore } from "../db/stores.ts";
import { carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { badRequest, conflict, Forbidden, unavailable, vmNotFound } from "../errors.ts";
import { resolveIdleTimeout, TenantPolicy } from "../policy.ts";
import { UpstreamClient, type VmLimitsPatch } from "../upstream/client.ts";
import { audited, auditableVmId, withOwnedVm } from "./common.ts";
import { snapshotNotFound, withOwnedSnapshot } from "./owned.ts";
import { toVm } from "./vm-view.ts";

const RESERVED_PREFIX = "cmux.";
const CHANGED = "It changed or was deleted while this update ran; read it again and retry";

const describeLabels = (labels: Readonly<Record<string, string>>) =>
  Object.entries(labels).map(([key, value]) => `${key}=${value}`).join(", ");

/** The label set that replaces `current`, or 403 when it would cross an ownership boundary. */
export const replacementLabels = (principal: Principal, current: Readonly<Record<string, string>>, requested: Readonly<Record<string, string>>) =>
  Effect.gen(function* () {
    const reserved = new Set([...Object.keys(current), ...Object.keys(requested)].filter((key) => key.startsWith(RESERVED_PREFIX)));
    if ([...reserved].some((key) => current[key] !== requested[key])) {
      return yield* Effect.fail(new Forbidden({ message: `Labels starting with ${RESERVED_PREFIX} are managed by cmux and cannot be added, removed or changed` }));
    }
    if (!carriesRequiredLabels(principal, requested)) {
      return yield* Effect.fail(new Forbidden({ message: `This key must keep the labels it is limited to: ${describeLabels(principal.requiredLabels ?? {})}` }));
    }
    return requested;
  });

/** A removed provider limit can read back as -1. */
const limitOf = (value: number | null | undefined): number | null => (value === undefined || value === null || value < 0 ? null : value);

const sameLabels = (a: Readonly<Record<string, string>>, b: Readonly<Record<string, string>>) =>
  Object.keys(a).length === Object.keys(b).length && Object.entries(a).every(([key, value]) => b[key] === value);

type Metadata = { readonly displayName: string | null; readonly labels: Readonly<Record<string, string>> };

/**
 * Compare-and-sets a resource's name and labels from `before` to `after`
 * before any provider write, so a 409 means nothing changed. Returns the
 * effect that puts `before` back (still compare-and-set, so a later writer's
 * change is never overwritten) for when the provider write then fails.
 */
const claimMetadata = (tenantId: Principal["tenantId"], kind: "vm" | "snapshot", cmuxId: string, before: Metadata, after: Metadata) =>
  Effect.gen(function* () {
    if (after.displayName === before.displayName && sameLabels(after.labels, before.labels)) return Effect.void;
    const store = yield* OwnershipStore;
    const updated = yield* store.updateMetadata(tenantId, kind, cmuxId, before, after).pipe(Effect.mapError(() => unavailable()));
    if (!updated) return yield* Effect.fail(conflict(CHANGED));
    return store.updateMetadata(tenantId, kind, cmuxId, after, before).pipe(Effect.ignore);
  });

export const updateVm = (rawId: string, payload: UpdateVmRequest) =>
  audited(
    "vm.update",
    auditableVmId(rawId),
    withOwnedVm(rawId, "vm:write", "write", (caller, vm, proofs) =>
      Effect.gen(function* () {
        if (Object.values(payload).every((value) => value === undefined)) return yield* Effect.fail(badRequest("Name at least one field to change"));
        if (!proofs.owns.committed) return yield* Effect.fail(conflict("This VM's create has not finished; retry or cancel that create first"));
        const labels = payload.labels === undefined ? proofs.owns.labels : yield* replacementLabels(caller.value, proofs.owns.labels, payload.labels);
        const displayName = payload.displayName === undefined ? proofs.owns.displayName : payload.displayName;
        const patch: { -readonly [K in keyof VmLimitsPatch]: VmLimitsPatch[K] } = {};
        if (payload.idleTimeoutSeconds !== undefined) {
          const idle = resolveIdleTimeout(yield* TenantPolicy, caller.value.tenantId, payload.idleTimeoutSeconds);
          if (!idle.ok) return yield* Effect.fail(badRequest(idle.message));
          patch.idleTimeoutSeconds = idle.seconds;
        }
        if (payload.maxRunSeconds !== undefined) patch.maxRunSeconds = payload.maxRunSeconds;
        if (payload.autoDeleteSeconds !== undefined) patch.autoDeleteSeconds = payload.autoDeleteSeconds;
        // Name and labels are compare-and-set first, so a 409 here has changed nothing; the
        // provider limits follow, and a failed limit change puts the name and labels back.
        const before = { displayName: proofs.owns.displayName, labels: proofs.owns.labels };
        const after = { displayName, labels };
        const restore = yield* claimMetadata(caller.value.tenantId, "vm", vm.value, before, after);
        const upstream = yield* UpstreamClient;
        const current = yield* upstream.updateVm(vm, proofs, patch).pipe(
          Effect.mapError((error) =>
            error.status === 404 ? vmNotFound()
            : error.status === 400 ? badRequest("The VM's limits could not be changed as asked")
            : error.status === 409 ? conflict("The VM cannot be changed right now; retry")
            : unavailable(),
          ),
          Effect.tapError(() => restore),
        );
        return toVm(vm.value, after, current);
      }),
    ),
  );

export const updateSnapshot = (rawId: string, payload: UpdateSnapshotRequest) =>
  withOwnedSnapshot(rawId, "snapshot:write", "write", (caller, snapshot, proofs) =>
    audited(
      "snapshot.update",
      snapshot.value,
      Effect.gen(function* () {
        if (Object.values(payload).every((value) => value === undefined)) return yield* Effect.fail(badRequest("Name at least one field to change"));
        const store = yield* SnapshotStore;
        const row = yield* store.describe(caller.value.tenantId, snapshot.value).pipe(Effect.mapError(() => unavailable()));
        if (Option.isNone(row)) return yield* Effect.fail(snapshotNotFound());
        // A capture that has not settled re-records its row with the original name and labels; renaming it first would wedge it.
        const capture = yield* (yield* TenantLimits).snapshotCapture(caller.value.tenantId, { op: "get", id: snapshot.value }).pipe(Effect.mapError(() => unavailable()));
        if (capture.state === "record" && capture.record.state !== "committed") {
          return yield* Effect.fail(conflict("This snapshot's capture has not finished; reconcile it first"));
        }
        const labels = payload.labels === undefined ? row.value.labels : yield* replacementLabels(caller.value, row.value.labels, payload.labels);
        const displayName = payload.displayName === undefined ? row.value.displayName : payload.displayName;
        const restore = yield* claimMetadata(caller.value.tenantId, "snapshot", snapshot.value, { displayName: row.value.displayName, labels: row.value.labels }, { displayName, labels });
        const upstream = yield* UpstreamClient;
        const live = yield* upstream
          .updateSnapshot(snapshot, proofs, {
            ...(payload.ttlSeconds === undefined ? {} : { ttlSeconds: payload.ttlSeconds }),
            ...(payload.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: payload.autoDeleteSeconds }),
          })
          .pipe(
            Effect.mapError((error) =>
              error.status === 404 ? snapshotNotFound()
              : error.status === 400 ? badRequest("The snapshot's retention could not be changed as asked")
              : error.status === 409 ? conflict("The snapshot cannot be changed right now; retry")
              : unavailable(),
            ),
            Effect.tapError(() => restore),
          );
        return new Snapshot({
          id: row.value.id,
          sourceVmId: row.value.sourceVmId,
          displayName,
          labels,
          createdAt: row.value.createdAt.toISOString(),
          lastUsedAt: live.lastUsedAt ?? null,
          ttlSeconds: limitOf(live.ttlSeconds),
          autoDeleteSeconds: limitOf(live.autoDeleteSeconds),
        });
      }),
    ),
  );
