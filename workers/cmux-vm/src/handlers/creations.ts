import { reconcileCreation } from "./creation-recovery.ts";
import { cancelVmCreation, continueCancellation } from "./creation-cancellation.ts";
import { HttpApiBuilder } from "@effect/platform";
import { Effect } from "effect";
import { VmCreationStatus, VmCreationCancellation, VmCreationList, VmCreationListItem, type VmCreationState } from "../api/creations.ts";
import { CmuxVmApi } from "../api.ts";
import { creationDiscoveryScope } from "../domain/generated-creation.ts";
import { TenantLimits } from "../limits/service.ts";
import { BadRequest, Forbidden, unavailable } from "../errors.ts";
import { readVmCreation } from "../proofs/vm-creation.ts";
import { audited, withCaller } from "./common.ts";

const publicStatus = (status: VmCreationState): VmCreationStatus => {
  const cancellation = status.state === "cancelling" ? "requested" : status.state === "cancelled" ? "completed" : null;
  return new VmCreationStatus({
    id: status.id, ...(status.receipt === undefined ? {} : { receipt: status.receipt }),
    state: status.state === "cancelling" ? "pending" : status.state === "cancelled" ? "deleted" : status.state,
    ...(cancellation === null ? {} : { cancellation }),
  });
};
const cancellationStatus = (status: VmCreationState) => status.id !== null && (status.state === "cancelling" || status.state === "cancelled" || status.state === "deleted")
  ? Effect.succeed(new VmCreationCancellation({ id: status.id, state: status.state, ...(status.receipt === undefined ? {} : { receipt: status.receipt }) }))
  : Effect.fail(unavailable());

const list = (cursor: string | undefined, limit: number, pending = false) => withCaller("vm:read", "read", (caller) => Effect.gen(function* () {
  if (caller.value.resourceAllowlist !== null) return yield* Effect.fail(new Forbidden({ message: "A key limited to specific resources cannot list creation history" }));
  if (cursor !== undefined && (pending ? !/^(?:p1_[a-f0-9]{16}-[a-f0-9]{64}|i1_[a-f0-9]{32})$/.test(cursor) : !/^[a-f0-9]{64}$/.test(cursor)))
    return yield* Effect.fail(new BadRequest({ message: "The cursor belongs to a different history view" }));
  const page = yield* (yield* TenantLimits).listGenerated(caller.value.tenantId, creationDiscoveryScope(caller.value), cursor, limit, pending).pipe(Effect.mapError(() => unavailable()));
  if (pending && page.pendingIndex === undefined) return yield* Effect.fail(unavailable());
  const items = yield* Effect.forEach(page.items, (generated) => readVmCreation(caller, generated.key).pipe(
    Effect.map((status) => pending && status.state !== "pending" && status.state !== "cancelling" ? null : new VmCreationListItem({ ...publicStatus(status), creationKey: generated.key,
      createdAt: generated.createdAt, operation: generated.operation, displayName: generated.displayName,
      ...(generated.sourceId === undefined ? {} : { sourceId: generated.sourceId }),
    })),
    Effect.catchTag("NotFound", () => Effect.succeed(null)),
  ), { concurrency: 4 });
  return new VmCreationList({ items: items.filter((item) => item !== null), nextCursor: page.nextCursor, ...(pending ? { pendingIndex: page.pendingIndex } : {}) });
}));

const inspect = (key: string) => withCaller("vm:read", "read", (caller) => readVmCreation(caller, key));

const reconcile = (key: string) => withCaller("vm:write", "write", (caller, scope) =>
  reconcileCreation(caller, scope, key).pipe(Effect.flatMap((status) =>
    status.state === "cancelling" || status.state === "cancelled" ? continueCancellation(caller, scope, key) : Effect.succeed(status),
  )),
).pipe(Effect.uninterruptible);

export const creationHandlers = HttpApiBuilder.group(CmuxVmApi, "vmCreations", (handlers) => handlers
  .handle("listVmCreations", ({ urlParams }) => list(urlParams.cursor, urlParams.limit ?? 50, urlParams.state === "pending"))
  .handle("cancelVmCreation", ({ headers }) => audited("vm.create.cancel", null, cancelVmCreation(headers["idempotency-key"]).pipe(Effect.flatMap(cancellationStatus)), (result) => result.id))
  .handle("getVmCreation", ({ headers }) => inspect(headers["idempotency-key"]).pipe(Effect.map(publicStatus)))
  .handle("reconcileVmCreation", ({ headers }) => audited("vm.create.reconcile", null, reconcile(headers["idempotency-key"]).pipe(Effect.map(publicStatus)), (result) => result.id)));
