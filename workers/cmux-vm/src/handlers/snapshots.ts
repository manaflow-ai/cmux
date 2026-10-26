/**
 * Snapshot endpoints. Creating needs the VM (ownership), `snapshot:write` and
 * the tenant's entitlement; reading and deleting need ownership of the
 * snapshot. Listing reads the ownership table only and never asks the
 * provider, so it cannot show another tenant's snapshot even if the provider
 * account holds thousands.
 */
import { createSnapshotCapture, inspectSnapshotCaptureByKey, inspectSnapshotCapture, listSnapshotCaptures, reconcileSnapshotCapture, cancelSnapshotCapture } from "./snapshot-capture.ts";
import { cancelSnapshotCaptureKey } from "./snapshot-key-cancellation.ts";
import { HttpApiBuilder } from "@effect/platform";
import { Clock, Effect, Option, Schema } from "effect";
import { CmuxVmApi } from "../api.ts";
import { InvalidRequest } from "../api/common.ts";
import { LABEL_KEY, LabelValue, MAX_LABELS, Snapshot, SnapshotList, SnapshotSummary } from "../api/snapshots.ts";
import { SnapshotStore, type SnapshotRow } from "../db/snapshots.ts";
import { actorRef } from "../domain/principal.ts";
import { Conflict, unavailable } from "../errors.ts";
import { SnapshotId, VmId } from "../lib/ids.ts";
import { UpstreamSnapshots, type UpstreamSnapshot } from "../upstream/snapshots.ts";
import { audited, withCaller } from "./common.ts";
import { snapshotNotFound, withOwnedSnapshot } from "./owned.ts";
import { updateSnapshot } from "./updates.ts";

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

const isLabelKey = (key: string) => LABEL_KEY.test(key);
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

const invalidCursor = () => new InvalidRequest({ message: "The cursor is not valid; start again without it" });

export const snapshotsHandlers = HttpApiBuilder.group(CmuxVmApi, "snapshots", (handlers) =>
  handlers
    .handle("createSnapshot", ({ path, payload, headers }) => createSnapshotCapture(path.vmId, payload, headers["idempotency-key"]))
    .handle("cancelSnapshotCreationByKey", ({ headers, payload }) => cancelSnapshotCaptureKey(headers["idempotency-key"], payload.expectedSnapshotId))
    .handle("getSnapshotCreationByKey", ({ headers }) => inspectSnapshotCaptureByKey(headers["idempotency-key"]))
    .handle("getSnapshotCreation", ({ path }) => inspectSnapshotCapture(path.snapshotId))
    .handle("listSnapshotCreations", ({ urlParams }) => listSnapshotCaptures(urlParams.cursor, urlParams.limit ?? 50))
    .handle("reconcileSnapshotCreation", ({ path }) => reconcileSnapshotCapture(path.snapshotId))
    .handle("cancelSnapshotCreation", ({ path }) => cancelSnapshotCapture(path.snapshotId))
    .handle("listSnapshots", ({ urlParams }) =>
      Effect.gen(function* () {
        const store = yield* SnapshotStore;
        return yield* withCaller("snapshot:read", "read", (caller) =>
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
            const required = caller.value.requiredLabels;
            if (required !== undefined) {
              if (labels !== null && Object.entries(labels).some(([key, value]) => key in required && required[key] !== value)) {
                return new SnapshotList({ items: [], nextCursor: null });
              }
              labels = { ...labels, ...required };
            }
            const allowlist = caller.value.resourceAllowlist;
            const rows = yield* store
              .list(caller.value.tenantId, {
                limit: limit + 1,
                after,
                sourceVmId,
                labels,
                only: allowlist === null ? null : [...allowlist],
                ...(urlParams.createdBy === "caller" ? { createdBy: actorRef(caller.value.actor) } : {}),
              })
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
        return yield* withOwnedSnapshot(path.snapshotId, "snapshot:read", "read", (caller, snapshot, proofs) =>
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
    .handle("updateSnapshot", ({ path, payload }) => updateSnapshot(path.snapshotId, payload))
    .handle("deleteSnapshot", ({ path }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamSnapshots;
        const store = yield* SnapshotStore;
        return yield* withOwnedSnapshot(path.snapshotId, "snapshot:write", "write", (caller, snapshot, proofs) =>
          audited(
            "snapshot.delete",
            snapshot.value,
            Effect.gen(function* () {
              yield* upstream.deleteSnapshot(snapshot, proofs).pipe(
                // Already gone upstream (for example, its retention expired): finish the delete here.
                Effect.catchIf((error) => error.status === 404, () => Effect.void),
                Effect.mapError((error) =>
                  error.status === 409 ? new Conflict({ message: "This snapshot cannot be deleted right now" }) : unavailable(),
                ),
              );
              const now = new Date(yield* Clock.currentTimeMillis);
              yield* store.markDeleted(caller.value.tenantId, snapshot.value, now).pipe(Effect.mapError(() => unavailable()));
            }),
          ),
        );
      }),
    ),
);
