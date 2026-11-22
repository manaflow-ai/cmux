/**
 * Snapshots: a VM's memory and disk captured so new VMs can boot exactly where
 * it was. Listing reads the ownership table only; reading one snapshot adds its
 * live retention fields.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { Conflict, NotFound, PaymentRequired, QuotaExceeded } from "../errors.ts";
import { SnapshotId, VmId } from "../lib/ids.ts";
import { describe, DisplayName, GroupCreateHeaders, GroupTeamHeaders, InvalidRequest } from "./common.ts";

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

export class CreateSnapshotRequest extends Schema.Class<CreateSnapshotRequest>("CreateSnapshotRequest")({
  displayName: Schema.optional(DisplayName),
  labels: Schema.optional(Labels),
  /** Delete the snapshot this many seconds after it is taken. Omit for no deadline. */
  ttlSeconds: Schema.optional(RetentionSeconds),
  /** Delete the snapshot once this many seconds pass without a VM being created from it. Omit for never. */
  autoDeleteSeconds: Schema.optional(RetentionSeconds),
}) {}

export const ListSnapshotsParams = Schema.Struct({
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
          `The snapshot captures memory and disk; VMs can boot from it as soon as this returns. ${RESTORE_NOTE}`,
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
