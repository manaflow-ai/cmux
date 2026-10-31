/**
 * Snapshots: a VM's memory and disk captured so new VMs can boot exactly where
 * it was. Listing reads the ownership table only; reading one snapshot adds its
 * live retention fields.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, PaymentRequired, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { SnapshotId, VmId } from "../lib/ids.ts";
import { CreatedByCaller, describe, DisplayName, GroupCreateHeaders, GroupCreationKeyHeaders, GroupTeamHeaders, InvalidRequest } from "./common.ts";

const MAX_RETENTION_SECONDS = 365 * 24 * 60 * 60;
const RetentionSeconds = Schema.Int.pipe(Schema.between(60, MAX_RETENTION_SECONDS));

/**
 * Snapshot labels follow the VM label rules in src/api.ts exactly (that module
 * composes this one, so the schema cannot be imported from it).
 */
export const LABEL_KEY = /^[a-z0-9]([a-z0-9._/-]{0,61}[a-z0-9])?$/u;
export const LabelValue = Schema.String.pipe(Schema.pattern(/^[A-Za-z0-9._:/@-]{0,63}$/));
export const MAX_LABELS = 16;
// Record key schemas only drop keys that do not match, so keys are checked by a filter that rejects.
export const Labels = Schema.Record({ key: Schema.String, value: LabelValue })
  .pipe(
    Schema.filter((labels) => Object.keys(labels).length <= MAX_LABELS && Object.keys(labels).every((key) => LABEL_KEY.test(key)), {
      message: () => `at most ${MAX_LABELS} labels, keys of lowercase letters, digits and . _ / -`,
    }),
  )
  .annotations({
    identifier: "SnapshotLabels",
    description: `Up to ${MAX_LABELS} key/value labels for finding snapshots (list filters by them). Same rules as VM labels. Stored by cmux, not secret.`,
  });

const RESTORE_NOTE =
  "A VM booted from a snapshot resumes from the captured memory. Whether the guest kernel's random number generator is " +
  "reseeded, and whether the machine id, hostname and clock change on restore, is not documented by the platform and is " +
  "not yet verified: assume every VM booted from one snapshot starts with identical RNG state, machine id and hostname, " +
  "and reseed, regenerate and resync them in the guest when that matters.";

export class SnapshotSummary extends Schema.Class<SnapshotSummary>("SnapshotSummary")({
  id: SnapshotId,
  /** The VM the snapshot was taken from, while that id still means something to the caller. */
  sourceVmId: Schema.NullOr(VmId),
  displayName: Schema.NullOr(Schema.String),
  labels: Labels,
  createdAt: Schema.String,
}) {}

export class Snapshot extends Schema.Class<Snapshot>("Snapshot")({
  id: SnapshotId,
  sourceVmId: Schema.NullOr(VmId),
  displayName: Schema.NullOr(Schema.String),
  labels: Labels,
  createdAt: Schema.String,
  /** When a VM was last created from this snapshot; null if none has been. */
  lastUsedAt: Schema.NullOr(Schema.String),
  /** Seconds after creation before the snapshot is deleted; null means no deadline. */
  ttlSeconds: Schema.NullOr(Schema.Number),
  /** Seconds without a VM being created from it before it is deleted; null means never. */
  autoDeleteSeconds: Schema.NullOr(Schema.Number),
}, { description: `A VM's memory and disk, captured. ${RESTORE_NOTE}` }) {}

export class SnapshotList extends Schema.Class<SnapshotList>("SnapshotList")({
  items: Schema.Array(SnapshotSummary),
  /** Pass as `cursor` to read the next page; null on the last page. */
  nextCursor: Schema.NullOr(Schema.String),
}) {}

export class SnapshotCreationStatus extends Schema.Class<SnapshotCreationStatus>("SnapshotCreationStatus")({
  state: Schema.Literal("pending", "committed", "deleted"), id: SnapshotId, receipt: SnapshotSummary,
  cancellation: Schema.optional(Schema.Literal("requested", "completed")),
  retryCreate: Schema.optional(Schema.Boolean).annotations({ description: "True only when admission needs the original create request retried with its original key; false for an uncertain capture send." }),
}) {}
export class SnapshotKeyCancellation extends Schema.Class<SnapshotKeyCancellation>("SnapshotKeyCancellation")({
  state: Schema.Literal("fenced", "cancelling", "cancelled"), id: Schema.NullOr(SnapshotId), receipt: Schema.optional(SnapshotSummary),
}) {}
export class CancelSnapshotKeyRequest extends Schema.Class<CancelSnapshotKeyRequest>("CancelSnapshotKeyRequest")({
  expectedSnapshotId: Schema.NullOr(SnapshotId).annotations({ description: "The capture id just inspected; null fences only an absent key. A different current id returns 409 without deleting anything." }),
}) {}
export class SnapshotCreationList extends Schema.Class<SnapshotCreationList>("SnapshotCreationList")({
  items: Schema.Array(SnapshotCreationStatus), nextCursor: Schema.NullOr(Schema.String),
}) {}
const CreationListParams = Schema.Struct({
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 100))),
  cursor: Schema.optional(Schema.String.pipe(Schema.pattern(/^[a-f0-9]{16}-snap_[0-9a-hjkmnp-tv-z]{26}$/))),
});

export class CreateSnapshotRequest extends Schema.Class<CreateSnapshotRequest>("CreateSnapshotRequest")({
  displayName: Schema.optional(DisplayName),
  labels: Schema.optional(Labels),
  /** Delete the snapshot this many seconds after it is taken. Omit for no deadline. */
  ttlSeconds: Schema.optional(RetentionSeconds),
  /** Delete the snapshot once this many seconds pass without a VM being created from it. Omit for never. */
  autoDeleteSeconds: Schema.optional(RetentionSeconds),
}) {}

/** cx-b4h.9: rename, relabel or change the retention of a snapshot. The provider slug is never a field. */
export class UpdateSnapshotRequest extends Schema.Class<UpdateSnapshotRequest>("UpdateSnapshotRequest")({
  displayName: Schema.optional(Schema.NullOr(DisplayName).annotations({ description: "A new name; null clears it." })),
  labels: Schema.optional(Labels.annotations({ description: "Replaces the whole label set. Labels starting with cmux. keep their values; a service or agent key keeps the labels it is limited to." })),
  ttlSeconds: Schema.optional(Schema.NullOr(RetentionSeconds).annotations({ description: "Delete the snapshot this many seconds after it was taken (not from now); null removes the deadline." })),
  autoDeleteSeconds: Schema.optional(Schema.NullOr(RetentionSeconds).annotations({ description: "Delete it once this many seconds pass without a VM being created from it; null removes the window." })),
}, {
  parseOptions: { onExcessProperty: "error" },
  description: "Omitted fields stay as they are; at least one is required. Any other field is refused with 400.",
}) {}

export const ListSnapshotsParams = Schema.Struct({
  createdBy: Schema.optional(CreatedByCaller),
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 100))),
  cursor: Schema.optional(Schema.String.pipe(Schema.maxLength(512))),
  /** Only snapshots taken from this VM. */
  sourceVmId: Schema.optional(Schema.String.pipe(Schema.maxLength(64))),
  /** Only snapshots carrying every one of these labels, as `key=value,key=value`. */
  labels: Schema.optional(Schema.String.pipe(Schema.maxLength(2048))),
});

const VmPath = Schema.Struct({ vmId: Schema.String });
const SnapshotPath = Schema.Struct({ snapshotId: Schema.String });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class SnapshotsGroupDefinition extends HttpApiGroup.make("snapshots")
  .add(HttpApiEndpoint.get("listSnapshotCreations", "/v1/snapshot-creations")
    .setHeaders(GroupTeamHeaders).setUrlParams(CreationListParams).addSuccess(SnapshotCreationList).addError(Forbidden).addError(QuotaExceeded)
    .annotateContext(describe("List snapshot captures, newest first", "snapshot:read", "Reads retained public intent only. Current service labels apply; resource-allowlisted keys cannot list. Filtered empty pages may have a nextCursor.")))
  .add(HttpApiEndpoint.post("cancelSnapshotCreationByKey", "/v1/snapshot-creations/by-key/cancel")
    .setHeaders(GroupCreationKeyHeaders).setPayload(CancelSnapshotKeyRequest).addSuccess(SnapshotKeyCancellation)
    .addError(NotFound).addError(Conflict).addError(Forbidden).addError(PaymentRequired).addError(QuotaExceeded)
    .annotateContext(describe("Stop captures under an original key and delete its verified snapshot", "snapshot:write", "Fences before cleanup, including absent keys and already committed captures. Fenced with id:null stops future admission; it does not prove legacy unrecorded effects were deleted. Cancelling retains unknown work. Fencing a never-admitted key requires snapshot entitlement; existing captures and fences can be cancelled after plan loss. Resource-allowlisted keys must use id-addressed controls.")))
  .add(HttpApiEndpoint.get("getSnapshotCreationByKey", "/v1/snapshot-creations/by-key")
    .setHeaders(GroupCreationKeyHeaders).addSuccess(SnapshotCreationStatus).addError(NotFound).addError(Conflict).addError(QuotaExceeded)
    .annotateContext(describe("Inspect a capture by its original Idempotency-Key", "snapshot:read", "Read only; never contacts the provider or requires the source VM. Legacy uncertain records return 409; unknown keys return 404.")))
  .add(HttpApiEndpoint.get("getSnapshotCreation", "/v1/snapshot-creations/:snapshotId")
    .setHeaders(GroupTeamHeaders).setPath(SnapshotPath).addSuccess(SnapshotCreationStatus).addError(NotFound).addError(QuotaExceeded)
    .annotateContext(describe("Inspect a snapshot capture", "snapshot:read", "Read only; never contacts the provider.")))
  .add(HttpApiEndpoint.post("reconcileSnapshotCreation", "/v1/snapshot-creations/:snapshotId/reconcile")
    .setHeaders(GroupTeamHeaders).setPath(SnapshotPath).addSuccess(SnapshotCreationStatus).addError(NotFound).addError(QuotaExceeded)
    .annotateContext(describe("Reconcile a snapshot capture", "snapshot:write", "Adopts a verified capture or finishes a requested cancellation. Never takes a new snapshot.")))
  .add(HttpApiEndpoint.post("cancelSnapshotCreation", "/v1/snapshot-creations/:snapshotId/cancel")
    .setHeaders(GroupTeamHeaders).setPath(SnapshotPath).addSuccess(SnapshotCreationStatus).addError(NotFound).addError(Conflict).addError(QuotaExceeded)
    .annotateContext(describe("Cancel a pending snapshot capture", "snapshot:write", "Fences before cleanup. An absent provider snapshot does not prove cancellation. Completed captures return 409; delete their snapshot instead.")))
  .add(
    HttpApiEndpoint.post("createSnapshot", "/v1/vms/:vmId/snapshots")
      .setPath(VmPath)
      .setPayload(CreateSnapshotRequest)
      .setHeaders(GroupCreateHeaders)
      .addSuccess(Snapshot, { status: 201 })
      .addError(NotFound)
      .addError(Conflict)
      .addError(PaymentRequired)
      .addError(QuotaExceeded)
      .annotateContext(
        describe(
          "Snapshot a running or paused VM",
          "snapshot:write",
          `Each capture is journaled before sending. A key permanently identifies one capture; use a fresh key for a new capture. Retained failures return pendingSnapshotId. Inspect, reconcile or cancel it at /v1/snapshot-creations/:snapshotId; reconcile never captures again. Omitted-key requests are separate captures; recover a lost handle from GET /v1/snapshot-creations. Unknown outcomes retain quota. ${RESTORE_NOTE}`,
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listSnapshots", "/v1/snapshots")
      .setUrlParams(ListSnapshotsParams)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(SnapshotList)
      .addError(InvalidRequest)
      .addError(QuotaExceeded)
      .annotateContext(describe("List the tenant's snapshots, newest first", "snapshot:read")),
  )
  .add(
    HttpApiEndpoint.get("getSnapshot", "/v1/snapshots/:snapshotId")
      .setPath(SnapshotPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(Snapshot)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describe("Get a snapshot", "snapshot:read")),
  )
  .add(
    HttpApiEndpoint.patch("updateSnapshot", "/v1/snapshots/:snapshotId")
      .setPath(SnapshotPath)
      .setHeaders(GroupTeamHeaders)
      .setPayload(UpdateSnapshotRequest)
      .addSuccess(Snapshot)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe("Update a snapshot's name, labels or retention", "snapshot:write", "Name and labels are stored by cmux; retention is applied to the snapshot. Labels replace the whole set; labels starting with cmux. cannot be added, removed or changed, and a service or agent key cannot drop the labels it is limited to (403). Audited."),
      ),
  )
  .add(
    HttpApiEndpoint.del("deleteSnapshot", "/v1/snapshots/:snapshotId")
      .setPath(SnapshotPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .annotateContext(
        describe("Delete a snapshot permanently", "snapshot:write", "VMs already created from it keep running."),
      ),
  ) {}
