/**
 * Classic -> NEXT migration: copy a classic VM into a NEXT tenant as a snapshot (src/api/classic-imports.ts).
 *
 * Order, as everywhere: scope (import:classic, held only by service keys), rate limit, then the work. An import
 * looks for an existing one by its labels first, then takes a tenant lock on the import's identity so two
 * concurrent requests never snapshot twice, then asks the provider for a snapshot under the import's own slug
 * (a retry after a lost reply finds that snapshot instead of taking another) and records it. The rollback deletes
 * only snapshots that carry classic.migration_id.
 */
import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option } from "effect";
import { CmuxVmApi } from "../api.ts";
import { ClassicVmImport, ClassicVmImportList } from "../api/classic-imports.ts";
import type { ClassicVmImportRequest } from "../api/classic-imports.ts";
import { SnapshotStore, type ClassicImportRow } from "../db/snapshots.ts";
import {
  CLASSIC_IMPORT_KEY_PREFIX,
  CLASSIC_IMPORTER_LABEL,
  CLASSIC_MIGRATION_LABEL,
  hasReservedLabel,
  CLASSIC_VM_LABEL,
  classicImportDigest,
  sha256Hex,
  type ClassicImportRequest,
} from "../domain/classic-import.ts";
import { actorRef, carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { badRequest, Conflict, conflict, missingScope, NotFound, snapshotNotFound, unavailable } from "../errors.ts";
import { newSnapshotId, parseSnapshotId, type TenantId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import { classicImportAllowed, classicImportedSnapshot, isClassicImport, type ClassicImportAllowed } from "../proofs/classic-import.ts";
import { tenantOwnsSnapshot } from "../proofs/tenant-owns-resource.ts";
import type { UpstreamError } from "../upstream/client.ts";
import { UpstreamSnapshots } from "../upstream/snapshots.ts";
import { audited, dependencyDown, withCaller } from "./common.ts";

/** Longer than a provider snapshot send (120 s) plus recording it. */
const IMPORT_LOCK_MS = 300_000;
const DEFAULT_LIST = 100;

const upstreamVmNotFound = () =>
  new NotFound({
    code: "import.upstream_vm_not_found",
    message:
      "The classic VM's provider VM was not found in the provider account this service uses. A classic VM that lives in a different provider account cannot be imported by snapshot from here.",
  });

const toImport = (tenantId: TenantId, row: ClassicImportRow, state: "created" | "ready" | "deleted") =>
  new ClassicVmImport({
    id: row.id,
    upstream_snapshot_id: row.upstreamId,
    state: row.deleted ? "deleted" : state,
    tenant_id: tenantId,
    classic_vm_id: row.labels[CLASSIC_VM_LABEL] ?? "",
    migration_id: row.labels[CLASSIC_MIGRATION_LABEL] ?? "",
    created_by: row.createdBy,
    created_at: row.createdAt.toISOString(),
  });

/** The caller is a service key holding import:classic, acting for the tenant it names; `k` runs with that proof. */
const asImporter = <A, E, R>(
  rateClass: "read" | "write",
  k: <C>(caller: Named<C, Principal>, allowed: ClassicImportAllowed<C>) => Effect.Effect<A, E, R>,
) =>
  withCaller("import:classic", rateClass, (caller, scope) =>
    Effect.gen(function* () {
      const allowed = classicImportAllowed(caller, scope);
      if (allowed === null) return yield* Effect.fail(missingScope("import:classic"));
      return yield* k(caller, allowed);
    }),
  );

const sameTenant = (principal: Principal, tenantId: string) =>
  principal.tenantId === tenantId ? Effect.void : Effect.fail(badRequest("tenant_id must equal the X-Cmux-Team-Id header"));

const importOf = <C>(caller: Named<C, Principal>, allowed: ClassicImportAllowed<C>, payload: ClassicVmImportRequest, key: string | undefined) =>
  Effect.gen(function* () {
    const principal = caller.value;
    yield* sameTenant(principal, payload.tenant_id);
    const store = yield* SnapshotStore;
    const upstream = yield* UpstreamSnapshots;
    const limits = yield* TenantLimits;
    const tenantId = principal.tenantId;
    const required = principal.requiredLabels ?? {};
    const identity = { [CLASSIC_VM_LABEL]: payload.classic_vm_id, [CLASSIC_MIGRATION_LABEL]: payload.migration_id };
    if (hasReservedLabel(required)) {
      return yield* Effect.fail(conflict("This service key's labels use the reserved classic. prefix; it cannot import"));
    }
    const live = (labels: Readonly<Record<string, string>>) =>
      store
        .listClassicImports(tenantId, { labels: { ...labels, ...required }, includeDeleted: false, limit: 1 })
        .pipe(Effect.map((rows) => Option.fromNullable(rows[0])), Effect.catchAll(dependencyDown("snapshots.listClassicImports")));

    const keyDigest = key === undefined ? null : (yield* Effect.promise(() => sha256Hex(["classic-import-key:v1", actorRef(principal.actor), key]))).slice(0, 40);
    const keyLabel = keyDigest === null ? null : `${CLASSIC_IMPORT_KEY_PREFIX}${keyDigest}`;
    const identityDigest = yield* Effect.promise(() => classicImportDigest({ tenantId, classicVmId: payload.classic_vm_id, migrationId: payload.migration_id }));
    const holder = crypto.randomUUID();
    /** Runs `effect` holding the tenant lock `name`; a request that finds it held is 409 "retry shortly". */
    const locked = <A, E, R>(name: string, busy: string, effect: Effect.Effect<A, E, R>) =>
      Effect.gen(function* () {
        const taken = yield* limits.lock(tenantId, name, holder, IMPORT_LOCK_MS).pipe(Effect.catchAll(dependencyDown("limits.lock")));
        if (!taken) return yield* Effect.fail(conflict(busy));
        return yield* effect.pipe(Effect.ensuring(limits.unlock(tenantId, name, holder)));
      });

    const run = Effect.gen(function* () {
      // An Idempotency-Key names one import: replay it, or refuse it for a different classic VM or migration.
      // The key's lock (taken before this runs) makes the check and the import that binds the key one step.
      if (keyLabel !== null) {
        const keyed = yield* live({ [keyLabel]: "1" });
        if (Option.isSome(keyed)) {
          const row = keyed.value;
          if (row.labels[CLASSIC_VM_LABEL] !== payload.classic_vm_id || row.labels[CLASSIC_MIGRATION_LABEL] !== payload.migration_id) {
            return yield* Effect.fail(conflict("This Idempotency-Key was already used with a different request"));
          }
          return toImport(tenantId, row, "ready");
        }
      }
      const existing = yield* live(identity);
      if (Option.isSome(existing)) {
        // Replaying an import under a new Idempotency-Key binds the key to it, so the key never names another import.
        if (keyLabel !== null) {
          const bound = yield* store.bindClassicImportKey(tenantId, existing.value.id, keyLabel).pipe(Effect.catchAll(dependencyDown("snapshots.bindClassicImportKey")));
          if (!bound) return yield* Effect.fail(conflict("This import cannot take another Idempotency-Key; retry without one"));
          return toImport(tenantId, { ...existing.value, labels: { ...existing.value.labels, [keyLabel]: "1" } }, "ready");
        }
        return toImport(tenantId, existing.value, "ready");
      }
      const request: ClassicImportRequest = {
        tenantId,
        classicVmId: payload.classic_vm_id,
        migrationId: payload.migration_id,
        upstreamVmId: payload.upstream_vm_id,
      };
      const providerError = (error: UpstreamError) =>
        error.status === 404
          ? upstreamVmNotFound()
          : error.status === 409
            ? new Conflict({ message: "The classic VM cannot be snapshotted now (not running or paused), or an earlier import of it came from a different provider VM" })
            : unavailable(error);
      const found = yield* upstream.findClassicImport(request, { allowed }).pipe(Effect.mapError(providerError));
      const created = found ?? (yield* upstream.captureClassicImport(request, { allowed }).pipe(Effect.mapError(providerError)));
      const id = newSnapshotId();
      const createdAt = new Date(yield* Clock.currentTimeMillis);
      const labels = { ...required, ...identity, [CLASSIC_IMPORTER_LABEL]: actorRef(principal.actor), ...(keyLabel === null ? {} : { [keyLabel]: "1" }) };
      const createdBy = `user:${payload.created_by}`;
      const recorded = yield* store
        .record({ tenantId, id, upstreamId: created.upstreamId, sourceVmId: null, displayName: null, labels, createdBy, createdAt })
        .pipe(Effect.either);
      if (recorded._tag === "Left") {
        // A failed write may still have committed (a lost reply). Never delete the provider snapshot here: read the row
        // back and answer it if it is there; otherwise 503 and keep the snapshot, which a retry adopts by its slug.
        const settled = yield* live(identity);
        if (Option.isSome(settled) && settled.value.upstreamId === created.upstreamId) return toImport(tenantId, settled.value, settled.value.id === id ? "created" : "ready");
        return yield* dependencyDown("snapshots.record")(recorded.left);
      }
      return toImport(tenantId, { id, upstreamId: created.upstreamId, labels, createdBy, createdAt, deleted: false }, "created");
    });

    // One import of this identity, and one use of this Idempotency-Key, at a time per tenant.
    const byIdentity = locked(`classic-import:${identityDigest}`, "An import of this classic VM is running; retry shortly", run);
    return yield* keyLabel === null
      ? byIdentity
      : locked(`classic-import-key:${keyDigest}`, "A request with this Idempotency-Key is still running; retry shortly", byIdentity);
  });

const rollbackOf = <C>(caller: Named<C, Principal>, allowed: ClassicImportAllowed<C>, rawId: string) =>
  Effect.gen(function* () {
    const parsed = parseSnapshotId(rawId);
    if (Option.isNone(parsed)) return yield* Effect.fail(snapshotNotFound());
    const store = yield* SnapshotStore;
    const upstream = yield* UpstreamSnapshots;
    return yield* name(parsed.value, (snapshot) =>
      Effect.gen(function* () {
        const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.catchAll(dependencyDown("ownership.find")));
        if (owns === null) {
          // A second rollback of the same import succeeds; anything else the caller cannot see is 404.
          const row = yield* store.inspect(caller.value.tenantId, snapshot.value).pipe(Effect.catchAll(dependencyDown("snapshots.inspect")));
          const rolledBack = Option.isSome(row) && row.value.deleted && isClassicImport(row.value.labels)
            && carriesRequiredLabels(caller.value, row.value.labels) && caller.value.resourceAllowlist === null;
          return rolledBack ? undefined : yield* Effect.fail(snapshotNotFound());
        }
        const imported = classicImportedSnapshot(caller, snapshot, owns, allowed);
        if (imported === null) {
          return yield* Effect.fail(conflict("This snapshot was not made by a classic import; the import rollback never deletes it"));
        }
        yield* upstream.deleteClassicImport(snapshot, { owns, imported }).pipe(
          // Already gone upstream: finish the rollback here.
          Effect.catchIf((error) => error.status === 404, () => Effect.void),
          Effect.mapError((error) => (error.status === 409 ? conflict("This snapshot cannot be deleted right now") : unavailable(error))),
        );
        const now = new Date(yield* Clock.currentTimeMillis);
        yield* store.markDeleted(caller.value.tenantId, snapshot.value, now).pipe(Effect.mapError(unavailable));
        return undefined;
      }),
    );
  });

export const classicImportsHandlers = HttpApiBuilder.group(CmuxVmApi, "classicImports", (handlers) =>
  handlers
    .handle("importClassicVmSnapshot", ({ payload, headers }) =>
      asImporter("write", (caller, allowed) =>
        audited("snapshot.import_classic", null, importOf(caller, allowed, payload, headers["idempotency-key"]), (result) => result.id),
      ),
    )
    .handle("listClassicVmSnapshotImports", ({ urlParams }) =>
      asImporter("read", (caller) =>
        Effect.gen(function* () {
          const principal = caller.value;
          yield* sameTenant(principal, urlParams.tenant_id);
          const store = yield* SnapshotStore;
          const labels: Record<string, string> = {
            ...(urlParams.classic_vm_id === undefined ? {} : { [CLASSIC_VM_LABEL]: urlParams.classic_vm_id }),
            ...(urlParams.migration_id === undefined ? {} : { [CLASSIC_MIGRATION_LABEL]: urlParams.migration_id }),
          };
          const required = principal.requiredLabels ?? {};
          if (Object.entries(labels).some(([label, value]) => label in required && required[label] !== value)) return new ClassicVmImportList({ items: [] });
          const rows = yield* store
            .listClassicImports(principal.tenantId, { labels: { ...labels, ...required }, includeDeleted: true, limit: urlParams.limit ?? DEFAULT_LIST })
            .pipe(Effect.catchAll(dependencyDown("snapshots.listClassicImports")));
          const visible = principal.resourceAllowlist === null ? rows : rows.filter((row) => principal.resourceAllowlist?.has(row.id) === true);
          return new ClassicVmImportList({ items: visible.map((row) => toImport(principal.tenantId, row, "ready")) });
        }),
      ),
    )
    .handle("rollbackClassicVmSnapshotImport", ({ path }) =>
      asImporter("write", (caller, allowed) =>
        audited("snapshot.rollback_classic_import", Option.isSome(parseSnapshotId(path.snapshotId)) ? path.snapshotId : null, rollbackOf(caller, allowed, path.snapshotId)),
      ),
    ),
);
