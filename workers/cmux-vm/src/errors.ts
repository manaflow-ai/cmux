/**
 * Public errors. Every message is written for API clients: no provider names,
 * upstream ids, SQL or stack traces. A resource the caller cannot see is always
 * `NotFound`, whether it does not exist or belongs to another tenant.
 */
import { HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { Scope } from "./domain/scopes.ts";
import { SnapshotId } from "./lib/ids.ts";

export class Unauthorized extends Schema.TaggedError<Unauthorized>()(
  "Unauthorized",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 401 }),
) {}

export class Forbidden extends Schema.TaggedError<Forbidden>()(
  "Forbidden",
  { message: Schema.String, missingScope: Schema.optional(Scope) },
  HttpApiSchema.annotations({ status: 403 }),
) {}

export class NotFound extends Schema.TaggedError<NotFound>()(
  "NotFound",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 404 }),
) {}

export class ServiceUnavailable extends Schema.TaggedError<ServiceUnavailable>()(
  "ServiceUnavailable",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 503 }),
) {}

export const vmNotFound = () => new NotFound({ message: "VM not found" });
export const missingScope = (scope: Scope) =>
  new Forbidden({ message: `This credential lacks the ${scope} scope`, missingScope: scope });
export const unavailable = () => new ServiceUnavailable({ message: "The cmux VM service is temporarily unavailable" });

/** The request conflicts with the resource's current state (for example, starting a VM that is being deleted). */
export class Conflict extends Schema.TaggedError<Conflict>()(
  "Conflict",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 409 }),
) {}

/** The tenant's plan does not include this resource. */
export class PaymentRequired extends Schema.TaggedError<PaymentRequired>()(
  "PaymentRequired",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 402 }),
) {}

/** A tenant quota or rate limit was reached. */
export class QuotaExceeded extends Schema.TaggedError<QuotaExceeded>()(
  "QuotaExceeded",
  {
    message: Schema.String,
    retryAfterSeconds: Schema.optional(Schema.Int),
    /**
     * Which budget ran out: the team's live snapshots or live VMs, its
     * per-minute request rate, or the platform's VM capacity (not the team's);
     * for the mesh experiment, which mesh budget (meshes per team, devices per
     * mesh, firewall rules per mesh or per named resource, ACL applies per
     * mesh per minute, address changes per device) or the platform account's firewall rule limit.
     */
    budget: Schema.optional(
      Schema.Literal(
        "snapshots",
        "vms",
        "rate",
        "capacity",
        // Mesh experiment (cx-0op, DESIGN.md 7.1).
        "mesh.perTenant",
        "device.perMesh",
        "firewallRule.perMesh",
        "firewallRule.perResource",
        "firewallRule.account",
        "aclApply.perMeshPerMinute",
        "enrollmentCode.perMeshPerHour",
        "address.perDevice",
      ),
    ),
  },
  HttpApiSchema.annotations({ status: 429 }),
) {}

/** The endpoint is part of the published contract but not served yet. */
export class NotImplemented extends Schema.TaggedError<NotImplemented>()(
  "NotImplemented",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 501 }),
) {}

export const notImplemented = (operation: string) =>
  new NotImplemented({ message: `${operation} is not available yet` });

/** The request is well formed but not allowed as asked (for example, a dev/test idle timeout over 300 seconds). */
export class BadRequest extends Schema.TaggedError<BadRequest>()(
  "BadRequest",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 400 }),
) {}

/** The request body is larger than this endpoint accepts. */
export class PayloadTooLarge extends Schema.TaggedError<PayloadTooLarge>()(
  "PayloadTooLarge",
  { message: Schema.String, maxBytes: Schema.Int },
  HttpApiSchema.annotations({ status: 413 }),
) {}

/**
 * A fork took its snapshot but could not create the new VM. The snapshot is
 * kept and belongs to the caller's tenant. Retrying with the same
 * Idempotency-Key creates the VM from this snapshot without taking another.
 */
export class ForkIncomplete extends Schema.TaggedError<ForkIncomplete>()(
  "ForkIncomplete",
  { message: Schema.String, snapshotId: SnapshotId },
  HttpApiSchema.annotations({
    status: 503,
    description:
      "The fork's snapshot was taken but the new VM was not created. The snapshot is kept in the caller's tenant; retry with the same Idempotency-Key to create from it without a second snapshot.",
  }),
) {}

export const snapshotNotFound = () => new NotFound({ message: "Snapshot not found" });
export const fileNotFound = () => new NotFound({ message: "File not found" });
export const badRequest = (message: string) => new BadRequest({ message });
export const conflict = (message: string) => new Conflict({ message });
