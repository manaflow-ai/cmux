/**
 * Snapshot endpoints. Creating needs the VM (ownership), `snapshot:write` and
 * the tenant's entitlement; reading and deleting need ownership of the
 * snapshot. Listing reads the ownership table only and never asks the
 * provider, so it cannot show another tenant's snapshot even if the provider
 * account holds thousands.
 */
import { HttpApiBuilder } from "@effect/platform";
import { Clock, Effect, Option, Schema } from "effect";
import { CmuxVmApi } from "../api.ts";
import { InvalidRequest } from "../api/common.ts";
import { LabelKey, LabelValue, MAX_LABELS, Snapshot, SnapshotList, SnapshotSummary } from "../api/snapshots.ts";
import { audit } from "../db/audit.ts";
import { idempotent } from "../db/idempotency.ts";
import { SnapshotStore, type SnapshotRow } from "../db/snapshots.ts";
import { actorRef } from "../domain/principal.ts";
import { Conflict, PaymentRequired, unavailable, vmNotFound } from "../errors.ts";
import { newSnapshotId, SnapshotId, VmId } from "../lib/ids.ts";
import { tenantMayCreate } from "../proofs/tenant-may-create.ts";
import { UpstreamSnapshots, type UpstreamSnapshot } from "../upstream/snapshots.ts";
import { OwnedSnapshot, OwnedVm, snapshotNotFound, withOwned, withScope } from "./owned.ts";

const DEFAULT_PAGE = 50;

const toSnapshot = (row: SnapshotRow, live: UpstreamSnapshot): Snapshot =>
  new Snapshot({
    id: row.id,
    sourceVmId: row.sourceVmId,
    displayName: row.displayName,
    labels: row.labels,
    createdAt: row.createdAt.toISOString(),
    lastUsedAt: live.lastUsedAt ?? null,
    ttlSeconds: live.ttlSeconds ?? null,
    autoDeleteSeconds: live.autoDeleteSeconds ?? null,
  });

const toSummary = (row: SnapshotRow): SnapshotSummary =>
  new SnapshotSummary({
    id: row.id,
    sourceVmId: row.sourceVmId,
    displayName: row.displayName,
    labels: row.labels,
    createdAt: row.createdAt.toISOString(),
  });

/** Opaque page cursor: base64url of `[createdAt, id]` of the last row returned. */
const Cursor = Schema.parseJson(Schema.Tuple(Schema.Date, SnapshotId));

const encodeCursor = (row: SnapshotRow): string =>
  btoa(JSON.stringify([row.createdAt.toISOString(), row.id])).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");

const decodeCursor = (cursor: string): Option.Option<{ readonly createdAt: Date; readonly id: string }> => {
  let json: string;
  try {
    json = atob(cursor.replaceAll("-", "+").replaceAll("_", "/"));
  } catch {
    return Option.none();
  }
  return Schema.decodeUnknownOption(Cursor)(json).pipe(Option.map(([createdAt, id]) => ({ createdAt, id })));
};

const isLabelKey = Schema.is(LabelKey);
const isLabelValue = Schema.is(LabelValue);

/** Parses a `key=value,key=value` label filter; none when any pair is malformed. */
const parseLabelFilter = (raw: string): Option.Option<Record<string, string>> => {
  const labels: Record<string, string> = {};
  const pairs = raw.split(",");
  if (pairs.length > MAX_LABELS) return Option.none();
  for (const pair of pairs) {
    const separator = pair.indexOf("=");
    if (separator < 0) return Option.none();
    const key = pair.slice(0, separator);
    const value = pair.slice(separator + 1);
    if (!isLabelKey(key) || !isLabelValue(value)) return Option.none();
    labels[key] = value;
  }
  return Option.some(labels);
};

/** A structured Worker log line naming only the public snapshot id. */
const logEvent = (event: string, snapshotId: string) =>
  Effect.sync(() => console.error(JSON.stringify({ event, snapshotId })));

const invalidCursor = () => new InvalidRequest({ message: "The cursor is not valid; start again without it" });

export const snapshotsHandlers = HttpApiBuilder.group(CmuxVmApi, "snapshots", (handlers) =>
  handlers
    .handle("createSnapshot", ({ path, payload, headers }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamSnapshots;
        const store = yield* SnapshotStore;
        return yield* withOwned(OwnedVm, path.vmId, "snapshot:write", (caller, vm, proofs) =>
          idempotent({
            tenantId: caller.value.tenantId,
            key: headers["idempotency-key"],
            operation: "createSnapshot",
            request: {
              vmId: vm.value,
              displayName: payload.displayName ?? null,
              labels: payload.labels ?? {},
              ttlSeconds: payload.ttlSeconds ?? null,
              autoDeleteSeconds: payload.autoDeleteSeconds ?? null,
            },
            schema: Snapshot,
            // Uninterruptible: a client disconnect between the provider create and
            // the ownership row would otherwise orphan a snapshot nobody can reach.
            create: Effect.uninterruptible(Effect.gen(function* () {
              const principal = caller.value;
              const mayCreate = yield* tenantMayCreate(caller, "snapshot").pipe(Effect.mapError(() => unavailable()));
              if (mayCreate === null) {
                return yield* Effect.fail(new PaymentRequired({ message: "Your plan does not allow another snapshot" }));
              }
              const snapshotId = newSnapshotId();
              const created = yield* upstream
                .createSnapshot(
                  vm,
                  { owns: proofs.owns, scope: proofs.scope, mayCreate },
                  {
                    tenantId: principal.tenantId,
                    snapshotId,
                    ttlSeconds: payload.ttlSeconds,
                    autoDeleteSeconds: payload.autoDeleteSeconds,
                  },
                )
                .pipe(
                  Effect.tapError((error) =>
                    // No response: the provider may still finish. Its display name carries this id for reconciliation.
                    error.status === null ? logEvent("snapshot_create_unknown_outcome", snapshotId) : Effect.void,
                  ),
                  Effect.tapError(() => audit(principal, "snapshot.create", vm.value, "failed")),
                  Effect.mapError((error) =>
                    error.status === 404
                      ? vmNotFound()
                      : error.status === 409
                        ? new Conflict({ message: "The VM must be running or paused to snapshot it" })
                        : unavailable(),
                  ),
                );
              const row: SnapshotRow = {
                id: snapshotId,
                sourceVmId: vm.value,
                displayName: payload.displayName ?? null,
                labels: payload.labels ?? {},
                createdAt: new Date(yield* Clock.currentTimeMillis),
              };
              yield* store
                .record({
                  ...row,
                  tenantId: principal.tenantId,
                  upstreamId: created.upstreamId,
                  createdBy: actorRef(principal.actor),
                })
                .pipe(
                  // Without its ownership row nobody could reach or delete the snapshot: undo the create.
                  Effect.tapError(() =>
                    upstream
                      .discardCreatedSnapshot(created)
                      .pipe(Effect.catchAll(() => logEvent("snapshot_discard_failed", snapshotId))),
                  ),
                  Effect.tapError(() => audit(principal, "snapshot.create", vm.value, "failed")),
                  Effect.mapError(() => unavailable()),
                );
              yield* audit(principal, "snapshot.create", snapshotId, "succeeded");
              return toSnapshot(row, created.snapshot);
            })),
          }),
        );
      }),
    )
    .handle("listSnapshots", ({ urlParams }) =>
      Effect.gen(function* () {
        const store = yield* SnapshotStore;
        return yield* withScope("snapshot:read", (caller) =>
          Effect.gen(function* () {
            const limit = urlParams.limit ?? DEFAULT_PAGE;
            let after: { readonly createdAt: Date; readonly id: string } | null = null;
            if (urlParams.cursor !== undefined) {
              const decoded = decodeCursor(urlParams.cursor);
              if (Option.isNone(decoded)) return yield* Effect.fail(invalidCursor());
              after = decoded.value;
            }
            let sourceVmId: string | null = null;
            if (urlParams.sourceVmId !== undefined) {
              // A malformed id matches nothing, like another tenant's id.
              if (!Schema.is(VmId)(urlParams.sourceVmId)) return new SnapshotList({ items: [], nextCursor: null });
              sourceVmId = urlParams.sourceVmId;
            }
            let labels: Record<string, string> | null = null;
            if (urlParams.labels !== undefined) {
              const parsed = parseLabelFilter(urlParams.labels);
              if (Option.isNone(parsed)) {
                return yield* Effect.fail(new InvalidRequest({ message: "labels must be key=value pairs separated by commas" }));
              }
              labels = parsed.value;
            }
            const rows = yield* store
              .list(caller.value.tenantId, { limit: limit + 1, after, sourceVmId, labels })
              .pipe(Effect.mapError(() => unavailable()));
            const page = rows.slice(0, limit);
            const last = page.at(-1);
            return new SnapshotList({
              items: page.map(toSummary),
              nextCursor: rows.length > limit && last !== undefined ? encodeCursor(last) : null,
            });
          }),
        );
      }),
    )
    .handle("getSnapshot", ({ path }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamSnapshots;
        const store = yield* SnapshotStore;
        return yield* withOwned(OwnedSnapshot, path.snapshotId, "snapshot:read", (caller, snapshot, proofs) =>
          Effect.gen(function* () {
            const row = yield* store.describe(caller.value.tenantId, snapshot.value).pipe(Effect.mapError(() => unavailable()));
            if (Option.isNone(row)) return yield* Effect.fail(snapshotNotFound());
            const live = yield* upstream
              .getSnapshot(snapshot, proofs)
              .pipe(Effect.mapError((error) => (error.status === 404 ? snapshotNotFound() : unavailable())));
            return toSnapshot(row.value, live);
          }),
        );
      }),
    )
    .handle("deleteSnapshot", ({ path }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamSnapshots;
        const store = yield* SnapshotStore;
        return yield* withOwned(OwnedSnapshot, path.snapshotId, "snapshot:write", (caller, snapshot, proofs) =>
          Effect.gen(function* () {
            const principal = caller.value;
            yield* upstream.deleteSnapshot(snapshot, proofs).pipe(
              // Already gone upstream (for example, its retention expired): finish the delete here.
              Effect.catchIf((error) => error.status === 404, () => Effect.void),
              Effect.tapError(() => audit(principal, "snapshot.delete", snapshot.value, "failed")),
              Effect.mapError((error) =>
                error.status === 409 ? new Conflict({ message: "This snapshot cannot be deleted right now" }) : unavailable(),
              ),
            );
            const now = new Date(yield* Clock.currentTimeMillis);
            yield* store.markDeleted(principal.tenantId, snapshot.value, now).pipe(
              Effect.tapError(() => audit(principal, "snapshot.delete", snapshot.value, "failed")),
              Effect.mapError(() => unavailable()),
            );
            yield* audit(principal, "snapshot.delete", snapshot.value, "succeeded");
          }),
        );
      }),
    ),
);
