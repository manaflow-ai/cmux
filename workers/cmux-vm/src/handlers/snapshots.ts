/**
 * Snapshot endpoints. Creating needs the VM (ownership), `snapshot:write` and
 * the tenant's entitlement; reading and deleting need ownership of the
 * snapshot. Listing reads the ownership table only and never asks the
 * provider, so it cannot show another tenant's snapshot even if the provider
 * account holds thousands.
 */
import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option, Schema } from "effect";
import { CmuxVmApi } from "../api.ts";
import { InvalidRequest } from "../api/common.ts";
import { LABEL_KEY, LabelValue, MAX_LABELS, Snapshot, SnapshotList, SnapshotSummary } from "../api/snapshots.ts";
import { SnapshotStore, type SnapshotRow } from "../db/snapshots.ts";
import type { OwnershipStore } from "../db/stores.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import { Conflict, PaymentRequired, QuotaExceeded, unavailable, vmNotFound, type NotFound, type ServiceUnavailable } from "../errors.ts";
import { newSnapshotId, SnapshotId, VmId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantMayCreate, type TenantMayCreate } from "../proofs/tenant-may-create.ts";
import { tenantOwnsSnapshot } from "../proofs/tenant-owns-resource.ts";
import { UpstreamSnapshots, type UpstreamSnapshot } from "../upstream/snapshots.ts";
import { audited, withCaller, withOwnedVm } from "./common.ts";
import { snapshotNotFound, withOwnedSnapshot } from "./owned.ts";

const DEFAULT_PAGE = 50;

/** Labels in key order, so the same labels always give the same request fingerprint. */
const sortedLabels = (labels: Readonly<Record<string, string>> | undefined) =>
  Object.fromEntries(Object.entries(labels ?? {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));

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

const parseSnapshotId = Schema.decodeUnknownOption(SnapshotId);

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

/** A structured Worker log line naming only the public snapshot id. */
const logEvent = (event: string, snapshotId: string) =>
  Effect.sync(() => console.error(JSON.stringify({ event, snapshotId })));

const invalidCursor = () => new InvalidRequest({ message: "The cursor is not valid; start again without it" });

/**
 * Asks for a snapshot slot: billing first (402), then the tenant's quota
 * (429). Runs `k` with the proof and releases the reservation afterwards, by
 * which time a created snapshot is counted in the ownership table.
 */
const withSnapshotSlot = <C, A, E, R>(
  caller: Named<C, Principal>,
  k: (proof: TenantMayCreate<C, "snapshot">) => Effect.Effect<A, E, R>,
) =>
  Effect.gen(function* () {
    const decision = yield* tenantMayCreate(caller, "snapshot").pipe(Effect.mapError(() => unavailable()));
    if (decision._tag === "not_entitled") {
      return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include snapshots" }));
    }
    if (decision._tag === "over_quota") {
      return yield* Effect.fail(
        new QuotaExceeded({
          message: `This team already has its limit of ${decision.limit} snapshots; delete one first`,
          retryAfterSeconds: 60,
          budget: "snapshots",
        }),
      );
    }
    const limits = yield* TenantLimits;
    return yield* k(decision.proof).pipe(Effect.ensuring(limits.release(caller.value.tenantId, decision.proof.reservationId)));
  });

/** SHA-256 hex of a JSON rendering; computed exactly as the VM create does, so both share one key space. */
const fingerprint = (value: unknown) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

/**
 * Runs a snapshot create under an optional Idempotency-Key, on the tenant's
 * idempotency ledger (the same Durable Object the VM create uses). A retry
 * with the same key and request replays the first snapshot; the same key with
 * a different request, or while the first still runs, is 409. Keys are per
 * tenant; a claim whose request died frees itself after the ledger's lease.
 */
const idempotentSnapshot = <E, R, E2, R2>(
  principal: Principal,
  key: string | undefined,
  request: unknown,
  run: Effect.Effect<Snapshot, E, R>,
  replay: (snapshotId: string) => Effect.Effect<Snapshot, E2, R2>,
) =>
  Effect.gen(function* () {
    if (key === undefined) return yield* run;
    const limits = yield* TenantLimits;
    const scoped = yield* fingerprint(["key", key]);
    const claim = yield* limits
      .begin(principal.tenantId, scoped, yield* fingerprint(request))
      .pipe(Effect.mapError(() => unavailable()));
    switch (claim.state) {
      case "mismatch":
        return yield* Effect.fail(new Conflict({ message: "This Idempotency-Key was already used with a different request" }));
      case "in_progress":
        return yield* Effect.fail(new Conflict({ message: "A request with this Idempotency-Key is still running; retry shortly" }));
      case "resume":
        if (claim.progress.phase === "snapshotDone") return yield* replay(claim.progress.snapshotId);
        break;
      case "new":
        break;
    }
    return yield* run.pipe(
      Effect.tap((snapshot) =>
        limits.advance(principal.tenantId, scoped, { phase: "snapshotDone", snapshotId: snapshot.id }).pipe(Effect.ignore),
      ),
      Effect.tapError(() => limits.abandon(principal.tenantId, scoped)),
    );
  });

/** The snapshot a replayed create made, read with the create's own proofs. */
const replaySnapshot = <C>(
  caller: Named<C, Principal>,
  scope: KeyHasScope<C, "snapshot:write">,
  rawId: string,
): Effect.Effect<Snapshot, NotFound | ServiceUnavailable, SnapshotStore | UpstreamSnapshots | OwnershipStore> =>
  Effect.gen(function* () {
    const parsed = parseSnapshotId(rawId);
    if (Option.isNone(parsed)) return yield* Effect.fail(snapshotNotFound());
    const store = yield* SnapshotStore;
    const upstream = yield* UpstreamSnapshots;
    return yield* name(parsed.value, (snapshot) =>
      Effect.gen(function* () {
        const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.mapError(() => unavailable()));
        if (owns === null) return yield* Effect.fail(snapshotNotFound());
        const row = yield* store.describe(caller.value.tenantId, snapshot.value).pipe(Effect.mapError(() => unavailable()));
        if (Option.isNone(row)) return yield* Effect.fail(snapshotNotFound());
        const live = yield* upstream
          .getSnapshot(snapshot, { owns, scope })
          .pipe(Effect.mapError((error) => (error.status === 404 ? snapshotNotFound() : unavailable())));
        return toSnapshot(row.value, live);
      }),
    );
  });


export const snapshotsHandlers = HttpApiBuilder.group(CmuxVmApi, "snapshots", (handlers) =>
  handlers
    .handle("createSnapshot", ({ path, payload, headers }) =>
      Effect.gen(function* () {
        const upstream = yield* UpstreamSnapshots;
        const store = yield* SnapshotStore;
        return yield* withOwnedVm(path.vmId, "snapshot:write", "write", (caller, vm, proofs) =>
          audited(
            "snapshot.create",
            vm.value,
            idempotentSnapshot(
              caller.value,
              headers["idempotency-key"],
              {
                operation: "createSnapshot",
                vmId: vm.value,
                displayName: payload.displayName ?? null,
                labels: sortedLabels(payload.labels),
                ttlSeconds: payload.ttlSeconds ?? null,
                autoDeleteSeconds: payload.autoDeleteSeconds ?? null,
              },
              withSnapshotSlot(caller, (mayCreate) =>
                // Uninterruptible: a client disconnect between the provider create and
                // the ownership row would otherwise orphan a snapshot nobody can reach.
                Effect.uninterruptible(
                  Effect.gen(function* () {
                    const principal = caller.value;
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
                      .record({ ...row, tenantId: principal.tenantId, upstreamId: created.upstreamId, createdBy: actorRef(principal.actor) })
                      .pipe(
                        // Without its ownership row nobody could reach or delete the snapshot: undo the create.
                        Effect.tapError(() =>
                          upstream
                            .discardCreatedSnapshot(created)
                            .pipe(Effect.catchAll(() => logEvent("snapshot_discard_failed", snapshotId))),
                        ),
                        Effect.mapError(() => unavailable()),
                      );
                    return toSnapshot(row, created.snapshot);
                  }),
                ),
              ),
              (snapshotId) => replaySnapshot(caller, proofs.scope, snapshotId),
            ),
            (snapshot) => snapshot.id,
          ),
        );
      }),
    )
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
            const allowlist = caller.value.resourceAllowlist;
            const rows = yield* store
              .list(caller.value.tenantId, {
                limit: limit + 1,
                after,
                sourceVmId,
                labels,
                only: allowlist === null ? null : [...allowlist],
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
