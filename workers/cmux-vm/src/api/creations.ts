/** Key-addressed allocation receipts; committed ownership does not imply a running VM. */
import { HttpApiEndpoint, HttpApiGroup } from "@effect/platform";
import { Schema } from "effect";
import { Conflict, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { VmId } from "../lib/ids.ts";
import { describe, GroupCreationKeyHeaders } from "./common.ts";
import { VmImage } from "./images.ts";
import { InitialVmNetworkReceipt } from "./initial-network.ts";

export const VmCreationReceipt = Schema.Struct({
  id: VmId,
  displayName: Schema.NullOr(Schema.String),
  labels: Schema.Record({ key: Schema.String, value: Schema.String }),
  idleTimeoutSeconds: Schema.Number,
  bootImage: Schema.optional(VmImage),
  initialNetwork: Schema.optional(InitialVmNetworkReceipt),
}).annotations({ identifier: "VmCreationReceipt", description: "Original accepted creation intent. Contains no provider identifiers or proxy credentials." });
export type VmCreationReceipt = typeof VmCreationReceipt.Type;

export class VmCreationStatus extends Schema.Class<VmCreationStatus>("VmCreationStatus")({
  state: Schema.Literal("pending", "committed", "deleted", "unresolved", "cancelling", "cancelled").annotations({ description: "Committed means ownership recorded, not running. Cancelling retains uncertain provider work; only verified rejection/deletion reaches cancelled. Cancelled keys cannot be reused." }),
  id: Schema.NullOr(VmId),
  receipt: Schema.optional(VmCreationReceipt),
}) {}

export class VmCreationsGroupDefinition extends HttpApiGroup.make("vmCreations")
  .add(HttpApiEndpoint.get("getVmCreation", "/v1/vm-creations/by-key")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(VmCreationStatus)
    .addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Inspect a VM creation by its Idempotency-Key", "vm:read", "Reads retained intent and ownership only; never contacts the provider. Unknown keys return 404.")))
  .add(HttpApiEndpoint.post("reconcileVmCreation", "/v1/vm-creations/by-key/reconcile")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(VmCreationStatus)
    .addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Reconcile a retained VM creation", "vm:write", "Records a verified allocation or finishes a previously requested cancellation. Never creates, starts or grows a VM. Provider absence alone is not cancellation.")))
  .add(HttpApiEndpoint.post("cancelVmCreation", "/v1/vm-creations/by-key/cancel")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(VmCreationStatus)
    .addError(Conflict).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Cancel a pending VM creation", "vm:write", "Fences future sends before cleanup. Unknown work stays cancelling; cancelled requires verified rejection or deletion. Completed or legacy creates return 409. Cancellation keys cannot be reused."))) {}
