/** Key-addressed allocation receipts; committed ownership does not imply a running VM. */
import { HttpApiEndpoint, HttpApiGroup } from "@effect/platform";
import { Schema } from "effect";
import { NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
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
  state: Schema.Literal("pending", "committed", "deleted", "unresolved"),
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
    .annotateContext(describe("Reconcile a retained VM creation", "vm:write", "Records an existing allocation after verifying its original intent. Never creates, starts or grows a VM. Provider absence remains pending; it does not prove cancellation."))) {}
