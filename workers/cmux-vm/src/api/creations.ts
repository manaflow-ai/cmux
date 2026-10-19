/** Key-addressed allocation receipts; committed ownership does not imply a running VM. */
import { HttpApiEndpoint, HttpApiGroup } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { VmCreationKey, VmId } from "../lib/ids.ts";
import { describe, GroupCreationKeyHeaders, GroupTeamHeaders } from "./common.ts";
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
  cancellation: Schema.optional(Schema.Literal("requested", "completed")).annotations({ description: "Requested retains unknown provider work; completed means verified rejection/deletion. A completed cancellation permanently fences this key." }),
  id: Schema.NullOr(VmId),
  receipt: Schema.optional(VmCreationReceipt),
}) {}

export class VmCreationListItem extends VmCreationStatus.extend<VmCreationListItem>("VmCreationListItem")({
  creationKey: VmCreationKey, createdAt: Schema.String, operation: Schema.Literal("create", "fork"),
  displayName: Schema.NullOr(Schema.String), sourceId: Schema.optional(VmId),
}) {}
export class VmCreationList extends Schema.Class<VmCreationList>("VmCreationList")({
  items: Schema.Array(VmCreationListItem), nextCursor: Schema.NullOr(Schema.String),
  pendingIndex: Schema.optional(Schema.Literal("ready", "building", "unavailable")).annotations({ description: "Present for state=pending. Building needs the next cursor; unavailable means some older retained slots have no recoverable journal. Never treat either as complete history." }),
}) {}
export const VmCreationListQuery = Schema.Struct({
  state: Schema.optional(Schema.Literal("pending")),
  cursor: Schema.optional(Schema.String.pipe(Schema.pattern(/^(?:[a-f0-9]{64}|p1_[a-f0-9]{16}-[a-f0-9]{64}|i1_[a-f0-9]{32})$/))),
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 100))),
});

/** Internal lifecycle distinguishes cancellation from ordinary resource deletion. */
export interface VmCreationState {
  readonly state: "pending" | "committed" | "deleted" | "unresolved" | "cancelling" | "cancelled";
  readonly id: VmId | null;
  readonly receipt?: VmCreationReceipt;
}
export class VmCreationCancellation extends Schema.Class<VmCreationCancellation>("VmCreationCancellation")({
  state: Schema.Literal("cancelling", "cancelled", "deleted"), id: VmId, receipt: Schema.optional(VmCreationReceipt),
}) {}

export class VmCreationsGroupDefinition extends HttpApiGroup.make("vmCreations")
  .add(HttpApiEndpoint.get("listVmCreations", "/v1/vm-creations")
    .setHeaders(GroupTeamHeaders).setUrlParams(VmCreationListQuery).addSuccess(VmCreationList)
    .addError(BadRequest).addError(Forbidden).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("List server-issued VM creation handles", "vm:read", "Bounded creation history for requests that omitted their key. Never lists caller-supplied keys or contacts the provider. Current service labels apply; resource-allowlisted keys cannot list. Empty filtered pages can still have a nextCursor.")))
  .add(HttpApiEndpoint.get("getVmCreation", "/v1/vm-creations/by-key")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(VmCreationStatus)
    .addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Inspect a VM creation by its Idempotency-Key", "vm:read", "Reads retained intent and ownership only; never contacts the provider. Unknown keys return 404.")))
  .add(HttpApiEndpoint.post("reconcileVmCreation", "/v1/vm-creations/by-key/reconcile")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(VmCreationStatus)
    .addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Reconcile a retained VM creation", "vm:write", "Records a verified allocation or finishes a previously requested cancellation. Never creates, starts or grows a VM. Provider absence alone is not cancellation.")))
  .add(HttpApiEndpoint.post("cancelVmCreation", "/v1/vm-creations/by-key/cancel")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(VmCreationCancellation)
    .addError(Conflict).addError(NotFound).addError(QuotaExceeded).addError(ServiceUnavailable)
    .annotateContext(describe("Cancel a pending VM creation", "vm:write", "Fences future sends before cleanup. Unknown work stays cancelling; cancelled requires verified rejection or deletion. Completed or legacy creates return 409. Keys reported cancelled cannot be reused."))) {}
