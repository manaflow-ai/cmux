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
  CLASSIC_IMPORT_KEY_LABEL,
  CLASSIC_MIGRATION_LABEL,
  CLASSIC_VM_LABEL,
  classicImportDigest,
  sha256Hex,
  type ClassicImportRequest,
} from "../domain/classic-import.ts";
import { actorRef, carriesRequiredLabels, type Principal } from "../domain/principal.ts";
import { badRequest, Conflict, conflict, missingScope, NotFound, snapshotNotFound, unavailable } from "../errors.ts";
import { newSnapshotId, parseSnapshotId, type TenantId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import { classicImportAllowed, classicImportedSnapshot, type ClassicImportAllowed } from "../proofs/classic-import.ts";
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
    if (Object.keys(identity).some((label) => label in required)) {
      return yield* Effect.fail(conflict("This service key's labels name a classic import label; it cannot import"));
    }
    const live = (labels: Readonly<Record<string, string>>) =>
      store
        .listClassicImports(tenantId, { labels: { ...labels, ...required }, includeDeleted: false, limit: 1 })
        .pipe(Effect.map((rows) => Option.fromNullable(rows[0])), Effect.catchAll(dependencyDown("snapshots.listClassicImports")));

    // An Idempotency-Key names one import: replay it, or refuse it for a different classic VM or migration.
    const keyLabel = key === undefined ? null : (yield* Effect.promise(() => sha256Hex(["classic-import-key:v1", actorRef(principal.actor), key]))).slice(0, 40);
    if (keyLabel !== null) {
      const keyed = yield* live({ [CLASSIC_IMPORT_KEY_LABEL]: keyLabel });
      if (Option.isSome(keyed)) {
        const row = keyed.value;
        if (row.labels[CLASSIC_VM_LABEL] !== payload.classic_vm_id || row.labels[CLASSIC_MIGRATION_LABEL] !== payload.migration_id) {
          return yield* Effect.fail(conflict("This Idempotency-Key was already used with a different request"));
        }
        return toImport(tenantId, row, "ready");
      }
    }
    const existing = yield* live(identity);
    if (Option.isSome(existing)) return toImport(tenantId, existing.value, "ready");

    // One import of this identity at a time per tenant: a concurrent request waits for the first to finish.
    const lockKey = `classic-import:${yield* Effect.promise(() => classicImportDigest({ tenantId, classicVmId: payload.classic_vm_id, migrationId: payload.migration_id }))}`;
    const holder = crypto.randomUUID();
    const taken = yield* limits.lock(tenantId, lockKey, holder, IMPORT_LOCK_MS).pipe(Effect.catchAll(dependencyDown("limits.lock")));
    if (!taken) return yield* Effect.fail(conflict("An import of this classic VM is running; retry shortly"));
    return yield* Effect.gen(function* () {
      const settled = yield* live(identity);
      if (Option.isSome(settled)) return toImport(tenantId, settled.value, "ready");
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
      const labels = { ...required, ...identity, ...(keyLabel === null ? {} : { [CLASSIC_IMPORT_KEY_LABEL]: keyLabel }) };
      const createdBy = `user:${payload.created_by}`;
      yield* store
        .record({ tenantId, id, upstreamId: created.upstreamId, sourceVmId: null, displayName: null, labels, createdBy, createdAt })
        .pipe(
          Effect.tapError(() => upstream.discardCreatedSnapshot(created).pipe(Effect.ignore)),
          Effect.catchAll(dependencyDown("snapshots.record")),
        );
      return toImport(tenantId, { id, upstreamId: created.upstreamId, labels, createdBy, createdAt, deleted: false }, "created");
    }).pipe(Effect.ensuring(limits.unlock(tenantId, lockKey, holder)));
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
          const rolledBack = Option.isSome(row) && row.value.deleted && typeof row.value.labels[CLASSIC_MIGRATION_LABEL] === "string"
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
