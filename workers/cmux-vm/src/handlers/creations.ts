import { reconcileCreation } from "./creation-recovery.ts";
import { cancelVmCreation, continueCancellation } from "./creation-cancellation.ts";
import { HttpApiBuilder } from "@effect/platform";
import { Effect } from "effect";
import { VmCreationStatus, VmCreationCancellation, type VmCreationState } from "../api/creations.ts";
import { CmuxVmApi } from "../api.ts";
import { unavailable } from "../errors.ts";
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

const inspect = (key: string) => withCaller("vm:read", "read", (caller) => readVmCreation(caller, key));

const reconcile = (key: string) => withCaller("vm:write", "write", (caller, scope) =>
  reconcileCreation(caller, scope, key).pipe(Effect.flatMap((status) =>
    status.state === "cancelling" || status.state === "cancelled" ? continueCancellation(caller, scope, key) : Effect.succeed(status),
  )),
).pipe(Effect.uninterruptible);

export const creationHandlers = HttpApiBuilder.group(CmuxVmApi, "vmCreations", (handlers) => handlers
  .handle("cancelVmCreation", ({ headers }) => audited("vm.create.cancel", null, cancelVmCreation(headers["idempotency-key"]).pipe(Effect.flatMap(cancellationStatus)), (result) => result.id))
  .handle("getVmCreation", ({ headers }) => inspect(headers["idempotency-key"]).pipe(Effect.map(publicStatus)))
  .handle("reconcileVmCreation", ({ headers }) => audited("vm.create.reconcile", null, reconcile(headers["idempotency-key"]).pipe(Effect.map(publicStatus)), (result) => result.id)));
