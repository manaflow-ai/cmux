/**
 * VM lifecycle endpoints. Each handler names the caller and the resource,
 * proves scope and ownership (handlers/common.ts), and only then calls the
 * upstream client, which does not compile without those proofs.
 *
 * The provider has no stop, resume or fork operation, so:
 * - start: the provider's start (it boots a stopped VM and resumes a paused one);
 * - resume: the provider's start, only for a paused VM;
 * - stop: a `poweroff` inside the guest (the provider leaves a VM powered off
 *   from inside stopped and does not restart it);
 * - fork: a snapshot of the source, then a create from that snapshot, then
 *   deleting the snapshot. Not atomic; see `forkVm` below.
 */
import { HttpApiBuilder } from "@effect/platform";
import { name, type Named } from "@gdp-ts/core";
import { Clock, Effect, Option, Schema } from "effect";
import { CmuxVmApi, Vm, VmList, type CreateVmRequest, type ForkVmRequest, type VmState } from "../api.ts";
import { OwnershipStore } from "../db/stores.ts";
import { actorRef, type Principal } from "../domain/principal.ts";
import {
  badRequest,
  conflict,
  Forbidden,
  ForkIncomplete,
  PaymentRequired,
  QuotaExceeded,
  snapshotNotFound,
  unavailable,
  vmNotFound,
  type BadRequest,
  type Conflict,
  type NotFound,
  type ServiceUnavailable,
} from "../errors.ts";
import { newSnapshotId, newVmId, parseSnapshotId, parseVmId, TenantId, type SnapshotId, type VmId } from "../lib/ids.ts";
import { TenantLimits } from "../limits/service.ts";
import type { IdempotencyProgress } from "../limits/ledger.ts";
import { resolveIdleTimeout, TenantPolicy } from "../policy.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { tenantMayCreate, type TenantMayCreate } from "../proofs/tenant-may-create.ts";
import { tenantOwnsSnapshot, tenantOwnsVm, visitOwnedVms, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { UpstreamClient, type SizeRequest, type UpstreamError, type UpstreamVm } from "../upstream/client.ts";
import { audited, auditableVmId, withCaller, withOwnedVm } from "./common.ts";

const KNOWN_STATES: ReadonlyArray<VmState> = ["starting", "running", "pausing", "paused", "stopped"];

const stateOf = (state: string): VmState => KNOWN_STATES.find((known) => known === state) ?? "unknown";

/** Negative or absent provider limits read as "none". */
const limitOf = (value: number | null | undefined): number | null => (value === undefined || value === null || value < 0 ? null : value);

/** The public view: the cmux id, the ownership row's name and labels, and an allowlist of provider fields. */
export const toVm = (
  id: VmId,
  row: { readonly displayName: string | null; readonly labels: Readonly<Record<string, string>> },
  upstream: UpstreamVm,
): Vm =>
  new Vm({
    id,
    displayName: row.displayName,
    labels: row.labels,
    state: stateOf(upstream.state),
    resources: {
      vcpus: upstream.resources.cpu,
      memoryMib: upstream.resources.memory,
      diskMib: upstream.resources.storage,
    },
    idleTimeoutSeconds: upstream.idleTimeoutSeconds ?? null,
    maxRunSeconds: limitOf(upstream.maxRunSeconds),
    autoDeleteSeconds: limitOf(upstream.autoDeleteSeconds),
    createdAt: upstream.createdAt,
    updatedAt: upstream.updatedAt,
  });

/** Provider failures on an existing VM: 404 means the VM is gone; 409 is the given conflict; the rest is ours. */
const onVm =
  (conflictMessage: string) =>
  (error: UpstreamError): NotFound | Conflict | ServiceUnavailable =>
    error.status === 404 ? vmNotFound() : error.status === 409 ? conflict(conflictMessage) : unavailable();

/** Provider failures reading a VM: 404 means it is gone; anything else is ours. */
const onRead = (error: UpstreamError): NotFound | ServiceUnavailable => (error.status === 404 ? vmNotFound() : unavailable());

/** Provider failures on a create. */
const onCreate = (error: UpstreamError): BadRequest | Conflict | NotFound | QuotaExceeded | ServiceUnavailable => {
  // The source snapshot expired upstream after it was recorded.
  if (error.status === 404) return snapshotNotFound();
  if (error.status === 400) return badRequest("The VM could not be created as asked (check its snapshot and sizes)");
  if (error.status === 409) return conflict("No capacity is available for a new VM right now; retry later");
  if (error.status === 429) return new QuotaExceeded({ message: "VM capacity is exhausted for now; retry later", retryAfterSeconds: 60, budget: "capacity" });
  return unavailable();
};

const forbidAllowlisted = (principal: Principal) =>
  principal.resourceAllowlist === null
    ? Effect.void
    : Effect.fail(new Forbidden({ message: "A key limited to specific resources cannot create VMs" }));

const idleOrFail = (principal: Principal, requested: number | undefined) =>
  Effect.flatMap(TenantPolicy, (policy) => {
    const idle = resolveIdleTimeout(policy, principal.tenantId, requested);
    return idle.ok ? Effect.succeed(idle.seconds) : Effect.fail(badRequest(idle.message));
  });

/** SHA-256 hex of a canonical JSON rendering; same request, same fingerprint. */
const fingerprint = (value: unknown) =>
  Effect.promise(() => crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value)))).pipe(
    Effect.map((digest) => Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")),
  );

const sortedLabels = (labels: Readonly<Record<string, string>> | undefined) =>
  labels === undefined ? null : Object.fromEntries(Object.entries(labels).sort(([a], [b]) => (a < b ? -1 : 1)));

/** Everything a create and a fork need to make one VM. */
interface NewVm {
  readonly displayName: string | null;
  readonly labels: Readonly<Record<string, string>>;
  readonly idleTimeoutSeconds: number;
  readonly maxRunSeconds: number | undefined;
  readonly autoDeleteSeconds: number | undefined;
  readonly size: SizeRequest | undefined;
}

/**
 * Asks for a create slot: billing first (402), then the tenant's VM quota
 * (429). Runs `k` with the proof and releases the slot afterwards, by which
 * time a created VM is counted in the ownership table.
 */
const withCreateSlot = <C, A, E, R>(caller: Named<C, Principal>, k: (proof: TenantMayCreate<C, "vm">) => Effect.Effect<A, E, R>) =>
  Effect.gen(function* () {
    const decision = yield* tenantMayCreate(caller, "vm").pipe(Effect.mapError(() => unavailable()));
    if (decision._tag === "not_entitled") {
      return yield* Effect.fail(new PaymentRequired({ message: "This team's plan does not include VMs" }));
    }
    if (decision._tag === "over_quota") {
      return yield* Effect.fail(
        new QuotaExceeded({
          message: `This team already has its limit of ${decision.limit} VMs; delete one first`,
          retryAfterSeconds: 60,
          budget: "vms",
        }),
      );
    }
    const limits = yield* TenantLimits;
    return yield* k(decision.proof).pipe(Effect.ensuring(limits.release(caller.value.tenantId, decision.proof.reservationId)));
  });

/**
 * Creates the VM upstream (tagged with the tenant), grows it to the requested
 * size, and records it in the ownership table. If growing or recording fails,
 * the new VM is deleted by its exact id, so nothing unowned is left behind.
 */
const createRecorded = <C, S>(
  caller: Named<C, Principal>,
  spec: NewVm,
  proofs: {
    readonly mayCreate: TenantMayCreate<C, "vm">;
    readonly scope: KeyHasScope<C, "vm:write">;
    readonly source?: { readonly snapshot: Named<S, SnapshotId>; readonly owns: TenantOwnsResource<C, S> };
  },
) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const store = yield* OwnershipStore;
    const policy = yield* TenantPolicy;
    const cmuxId = newVmId();
    const created = yield* upstream
      .createVm(
        caller,
        {
          cmuxId,
          idleTimeoutSeconds: spec.idleTimeoutSeconds,
          ...(spec.maxRunSeconds === undefined ? {} : { maxRunSeconds: spec.maxRunSeconds }),
          ...(spec.autoDeleteSeconds === undefined ? {} : { autoDeleteSeconds: spec.autoDeleteSeconds }),
          ...(spec.size === undefined ? {} : { size: spec.size }),
          environment: policy.environment,
        },
        proofs,
      )
      .pipe(Effect.mapError(onCreate));
    const vm =
      spec.size === undefined
        ? created.vm
        : yield* created.grow(spec.size).pipe(
            Effect.tapError(() => created.discard),
            Effect.mapError((error) =>
              error.status === 429
                ? new QuotaExceeded({ message: "VM capacity is exhausted for now; retry later", retryAfterSeconds: 60, budget: "capacity" })
                : conflict("The VM could not be grown to the requested size; nothing was kept"),
            ),
          );
    const createdAt = new Date(yield* Clock.currentTimeMillis);
    yield* store
      .record({
        tenantId: caller.value.tenantId,
        kind: "vm",
        cmuxId,
        upstreamId: created.upstreamId,
        createdBy: actorRef(caller.value.actor),
        createdAt,
        displayName: spec.displayName,
        labels: spec.labels,
      })
      .pipe(
        Effect.tapError(() => created.discard),
        Effect.mapError(() => unavailable()),
      );
    return toVm(cmuxId, spec, vm);
    // Uninterruptible: a client that disconnects mid-create must not leave an
    // upstream VM that is neither recorded nor discarded.
  }).pipe(Effect.uninterruptible);

/** Answers a replayed create or fork with the VM the first request made. */
const replayVm = <C>(caller: Named<C, Principal>, scope: KeyHasScope<C, "vm:write">, rawVmId: string) =>
  Effect.gen(function* () {
    const upstream = yield* UpstreamClient;
    const parsed = parseVmId(rawVmId);
    if (Option.isNone(parsed)) return yield* Effect.fail(vmNotFound());
    return yield* name(parsed.value, (vm) =>
      Effect.gen(function* () {
        const owns = yield* tenantOwnsVm(caller, vm).pipe(Effect.mapError(() => unavailable()));
        if (owns === null) return yield* Effect.fail(vmNotFound());
        const current = yield* upstream.getVmForWrite(vm, { owns, scope }).pipe(Effect.mapError(onRead));
        return toVm(vm.value, owns, current);
      }),
    );
  });

/**
 * Runs a create or fork under an optional idempotency key. A retry with the
 * same key and request replays the first VM (or resumes a fork from its kept
 * snapshot); the same key with a different request is 409, as is a retry
 * while the first request still runs. Keys are per tenant.
 */
const idempotent = <E, R>(
  principal: Principal,
  key: string | undefined,
  request: unknown,
  run: (resumeFrom: IdempotencyProgress | null, keyed: string | null) => Effect.Effect<Vm, E, R>,
  replay: (vmId: string) => Effect.Effect<Vm, E | NotFound | ServiceUnavailable, R | UpstreamClient | OwnershipStore>,
) =>
  Effect.gen(function* () {
    if (key === undefined) return yield* run(null, null);
    const limits = yield* TenantLimits;
    const scoped = `${yield* fingerprint(["key", key])}`;
    const claim = yield* limits
      .begin(principal.tenantId, scoped, yield* fingerprint(request))
      .pipe(Effect.mapError(() => unavailable()));
    switch (claim.state) {
      case "mismatch":
        return yield* Effect.fail(conflict("This Idempotency-Key was already used with a different request"));
      case "in_progress":
        return yield* Effect.fail(conflict("A request with this Idempotency-Key is still running; retry shortly"));
      case "resume":
        if (claim.progress.phase === "done") return yield* replay(claim.progress.vmId);
        break;
      case "new":
        break;
    }
    const resumeFrom = claim.state === "resume" ? claim.progress : null;
    return yield* run(resumeFrom, scoped).pipe(
      Effect.tap((vm) => limits.advance(principal.tenantId, scoped, { phase: "done", vmId: vm.id }).pipe(Effect.ignore)),
      Effect.tapError(() => limits.abandon(principal.tenantId, scoped)),
    );
  });

const createVm = (payload: CreateVmRequest, idempotencyKey: string | undefined) =>
  withCaller("vm:write", "write", (caller, scope) =>
    Effect.gen(function* () {
      const principal = caller.value;
      yield* forbidAllowlisted(principal);
      const idleTimeoutSeconds = yield* idleOrFail(principal, payload.idleTimeoutSeconds);
      const spec: NewVm = {
        displayName: payload.displayName ?? null,
        labels: payload.labels ?? {},
        idleTimeoutSeconds,
        maxRunSeconds: payload.maxRunSeconds,
        autoDeleteSeconds: payload.autoDeleteSeconds,
        size: payload.resources,
      };
      const request = [
        "createVm",
        payload.displayName ?? null,
        payload.snapshotId ?? null,
        payload.resources === undefined ? null : [payload.resources.vcpus ?? null, payload.resources.memoryMib ?? null, payload.resources.diskMib ?? null],
        payload.idleTimeoutSeconds ?? null,
        payload.maxRunSeconds ?? null,
        payload.autoDeleteSeconds ?? null,
        sortedLabels(payload.labels),
      ];
      return yield* idempotent(
        principal,
        idempotencyKey,
        request,
        () =>
          Effect.gen(function* () {
            if (payload.snapshotId === undefined) {
              return yield* withCreateSlot(caller, (mayCreate) => createRecorded(caller, spec, { mayCreate, scope }));
            }
            return yield* name(payload.snapshotId, (snapshot) =>
              Effect.gen(function* () {
                const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.mapError(() => unavailable()));
                if (owns === null) return yield* Effect.fail(snapshotNotFound());
                return yield* withCreateSlot(caller, (mayCreate) =>
                  createRecorded(caller, spec, { mayCreate, scope, source: { snapshot, owns } }),
                );
              }),
            );
          }),
        (vmId) => replayVm(caller, scope, vmId),
      );
    }),
  );

const FORK_INCOMPLETE_MESSAGE =
  "The snapshot was taken but the new VM could not be created. The snapshot is kept in your team; retry with the same Idempotency-Key to create the VM from it.";

/**
 * Fork = snapshot + create + delete the snapshot. Not atomic:
 * - snapshot fails: nothing is made; the error is the snapshot's (409 when the
 *   source is neither running nor paused).
 * - snapshot succeeds, create fails: 503 ForkIncomplete naming the snapshot,
 *   which stays in the ownership table for the caller's tenant (and expires
 *   upstream after a day unused). With an Idempotency-Key the key remembers
 *   the snapshot, so a retry creates from it without taking a second one.
 * - both succeed: the snapshot is deleted by its exact id; a failed cleanup
 *   leaves it to expire.
 */
const forkVm = (rawVmId: string, payload: ForkVmRequest, idempotencyKey: string | undefined) =>
  withOwnedVm(rawVmId, "vm:write", "write", (caller, source, proofs) =>
    Effect.gen(function* () {
      const principal = caller.value;
      yield* forbidAllowlisted(principal);
      const idleTimeoutSeconds = yield* idleOrFail(principal, payload.idleTimeoutSeconds);
      const spec: NewVm = {
        displayName: payload.displayName ?? null,
        labels: payload.labels ?? {},
        idleTimeoutSeconds,
        maxRunSeconds: payload.maxRunSeconds,
        autoDeleteSeconds: payload.autoDeleteSeconds,
        size: undefined,
      };
      const request = [
        "forkVm",
        source.value,
        payload.displayName ?? null,
        payload.idleTimeoutSeconds ?? null,
        payload.maxRunSeconds ?? null,
        payload.autoDeleteSeconds ?? null,
        sortedLabels(payload.labels),
      ];
      const upstream = yield* UpstreamClient;
      const store = yield* OwnershipStore;
      const limits = yield* TenantLimits;
      return yield* idempotent(
        principal,
        idempotencyKey,
        request,
        (resumeFrom, keyed) =>
          withCreateSlot(caller, (mayCreate) =>
            Effect.gen(function* () {
              let snapshotId: string;
              if (resumeFrom !== null && resumeFrom.phase === "snapshotted") {
                snapshotId = resumeFrom.snapshotId;
              } else {
                const cmuxId = newSnapshotId();
                const taken = yield* upstream
                  .snapshotForFork(caller, source, { cmuxId }, { ...proofs, mayCreate })
                  .pipe(Effect.mapError(onVm("Only a running or paused VM can be forked")));
                yield* store
                  .record({
                    tenantId: principal.tenantId,
                    kind: "snapshot",
                    cmuxId,
                    upstreamId: taken.upstreamId,
                    createdBy: actorRef(principal.actor),
                    createdAt: new Date(yield* Clock.currentTimeMillis),
                    displayName: null,
                    labels: {},
                  })
                  .pipe(
                    Effect.tapError(() => taken.discard),
                    Effect.mapError(() => unavailable()),
                  );
                if (keyed !== null) {
                  // Without this record a retry would take a second snapshot, so a failed write fails the fork;
                  // the snapshot stays in the tenant's ownership rows.
                  yield* limits
                    .advance(principal.tenantId, keyed, { phase: "snapshotted", snapshotId: cmuxId })
                    .pipe(Effect.mapError(() => unavailable()));
                }
                snapshotId = cmuxId;
              }
              const parsed = parseSnapshotId(snapshotId);
              if (Option.isNone(parsed)) return yield* Effect.fail(unavailable());
              return yield* name(parsed.value, (snapshot) =>
                Effect.gen(function* () {
                  const owns = yield* tenantOwnsSnapshot(caller, snapshot).pipe(Effect.mapError(() => unavailable()));
                  if (owns === null) {
                    return yield* Effect.fail(conflict("The snapshot from the first attempt is gone; retry with a new Idempotency-Key"));
                  }
                  const vm = yield* createRecorded(caller, spec, { mayCreate, scope: proofs.scope, source: { snapshot, owns } }).pipe(
                    Effect.mapError(() => new ForkIncomplete({ message: FORK_INCOMPLETE_MESSAGE, snapshotId: snapshot.value })),
                  );
                  yield* upstream.deleteSnapshot(snapshot, { owns, scope: proofs.scope }).pipe(
                    Effect.zipRight(
                      Effect.flatMap(Clock.currentTimeMillis, (now) =>
                        store.markDeleted(principal.tenantId, "snapshot", snapshot.value, new Date(now)),
                      ),
                    ),
                    Effect.catchAll(() => Effect.void),
                  );
                  return vm;
                }),
              );
            }),
          ),
        (vmId) => replayVm(caller, proofs.scope, vmId),
      );
    }),
  );

const LIST_DEFAULT_LIMIT = 50;

const ListCursor = Schema.Struct({ v: Schema.Literal(1), t: Schema.String, c: Schema.String, i: Schema.String });
const decodeCursorJson = Schema.decodeUnknownOption(Schema.parseJson(ListCursor));

const encodeCursor = (tenantId: string, position: { readonly createdAt: Date; readonly cmuxId: string }) =>
  btoa(JSON.stringify({ v: 1, t: tenantId, c: position.createdAt.toISOString(), i: position.cmuxId }))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");

/** A cursor names a position in the caller's own list; another tenant's or a garbled one is 400. */
const decodeCursor = (tenantId: string, cursor: string) => {
  let text: string;
  try {
    text = atob(cursor.replaceAll("-", "+").replaceAll("_", "/"));
  } catch {
    return Option.none();
  }
  return decodeCursorJson(text).pipe(
    Option.filter((parsed) => parsed.t === tenantId && Option.isSome(parseVmId(parsed.i)) && !Number.isNaN(Date.parse(parsed.c))),
    Option.map((parsed) => ({ createdAt: new Date(parsed.c), cmuxId: parsed.i })),
  );
};

const parseLabelSelectors = (selectors: ReadonlyArray<string> | undefined): Readonly<Record<string, string>> | null => {
  if (selectors === undefined || selectors.length === 0) return null;
  return Object.fromEntries(
    selectors.map((selector) => {
      const at = selector.indexOf("=");
      return [selector.slice(0, at), selector.slice(at + 1)];
    }),
  );
};

const listVms = (params: {
  readonly limit?: number | undefined;
  readonly cursor?: string | undefined;
  readonly state?: VmState | undefined;
  readonly label?: ReadonlyArray<string> | undefined;
}) =>
  withCaller("vm:read", "read", (caller, scope) =>
    Effect.gen(function* () {
      const upstream = yield* UpstreamClient;
      const tenantId = caller.value.tenantId;
      let after: { readonly createdAt: Date; readonly cmuxId: string } | null = null;
      if (params.cursor !== undefined) {
        const decoded = decodeCursor(tenantId, params.cursor);
        if (Option.isNone(decoded)) return yield* Effect.fail(badRequest("cursor is not valid for this list"));
        after = decoded.value;
      }
      const limit = params.limit ?? LIST_DEFAULT_LIMIT;
      const page = yield* visitOwnedVms(caller, { limit, after, labels: parseLabelSelectors(params.label) }, (vm, owns, row) =>
        upstream.getVm(vm, { owns, scope }).pipe(
          Effect.map((current) => Option.some(toVm(vm.value, row, current))),
          // A VM gone upstream is left out; its row is cleaned up by delete or a sweep.
          Effect.catchIf(
            (error) => error.status === 404,
            () => Effect.succeed(Option.none<Vm>()),
          ),
          Effect.mapError(() => unavailable()),
        ),
      ).pipe(Effect.catchTag("StoreError", () => Effect.fail(unavailable())));
      const items = page.results.flatMap((item) =>
        Option.isSome(item) && (params.state === undefined || item.value.state === params.state) ? [item.value] : [],
      );
      return new VmList({
        items,
        nextCursor: page.fetched === limit && page.last !== null ? encodeCursor(tenantId, page.last) : null,
      });
    }),
  );

export const vmsHandlers = HttpApiBuilder.group(CmuxVmApi, "vms", (handlers) =>
  handlers
    .handle("getVm", ({ path }) =>
      withOwnedVm(path.vmId, "vm:read", "read", (_caller, vm, proofs) =>
        Effect.gen(function* () {
          const upstream = yield* UpstreamClient;
          const current = yield* upstream.getVm(vm, proofs).pipe(Effect.mapError(onRead));
          return toVm(vm.value, proofs.owns, current);
        }),
      ),
    )
    .handle("createVm", ({ payload, headers }) =>
      audited("vm.create", null, createVm(payload, headers["idempotency-key"]), (vm) => vm.id),
    )
    .handle("listVms", ({ urlParams }) => listVms(urlParams))
    .handle("startVm", ({ path }) =>
      audited(
        "vm.start",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const started = yield* upstream
              .startVm(vm, proofs)
              .pipe(Effect.mapError(onVm("The VM cannot start now: it no longer exists or no capacity is available")));
            return toVm(vm.value, proofs.owns, started);
          }),
        ),
      ),
    )
    .handle("resumeVm", ({ path }) =>
      audited(
        "vm.resume",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const current = yield* upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onRead));
            if (current.state !== "paused") {
              return yield* Effect.fail(conflict("Only a paused VM can be resumed; use start to boot a stopped VM"));
            }
            const resumed = yield* upstream
              .startVm(vm, proofs)
              .pipe(Effect.mapError(onVm("The VM cannot resume now: no capacity is available")));
            return toVm(vm.value, proofs.owns, resumed);
          }),
        ),
      ),
    )
    .handle("pauseVm", ({ path }) =>
      audited(
        "vm.pause",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const paused = yield* upstream.pauseVm(vm, proofs).pipe(Effect.mapError(onVm("Only a running VM can be paused")));
            return toVm(vm.value, proofs.owns, paused);
          }),
        ),
      ),
    )
    .handle("stopVm", ({ path }) =>
      audited(
        "vm.stop",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (_caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const current = yield* upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onRead));
            if (current.state === "stopped") return toVm(vm.value, proofs.owns, current);
            if (current.state !== "running") {
              return yield* Effect.fail(conflict("Only a running VM can be stopped; resume a paused VM first"));
            }
            yield* upstream.shutdownVm(vm, proofs).pipe(Effect.mapError(onVm("The VM did not accept the shutdown")));
            const after = yield* upstream.getVmForWrite(vm, proofs).pipe(Effect.mapError(onRead));
            return toVm(vm.value, proofs.owns, after);
          }),
        ),
      ),
    )
    .handle("forkVm", ({ path, payload, headers }) =>
      audited(
        "vm.fork",
        auditableVmId(path.vmId),
        forkVm(path.vmId, payload, headers["idempotency-key"]),
        (vm) => vm.id,
        (error) => (error instanceof ForkIncomplete ? error.snapshotId : null),
      ),
    )
    .handle("deleteVm", ({ path }) =>
      audited(
        "vm.delete",
        auditableVmId(path.vmId),
        withOwnedVm(path.vmId, "vm:write", "write", (caller, vm, proofs) =>
          Effect.gen(function* () {
            const upstream = yield* UpstreamClient;
            const store = yield* OwnershipStore;
            // "gone" (already deleted upstream) still forgets the VM here.
            yield* upstream.deleteVm(vm, proofs).pipe(Effect.mapError(() => unavailable()));
            const now = new Date(yield* Clock.currentTimeMillis);
            yield* store
              .markDeleted(TenantId.make(caller.value.tenantId), "vm", vm.value, now)
              .pipe(Effect.mapError(() => unavailable()));
          }),
        ),
      ),
    ),
);
