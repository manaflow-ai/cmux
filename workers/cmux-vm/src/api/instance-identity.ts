import { Schema } from "effect";
import { VmId } from "../lib/ids.ts";
import { INSTANCE_IDENTITY_SCHEME } from "../../../../libs/vm-instance-identity/src/identity.ts";

export class VmInstanceIdentity extends Schema.Class<VmInstanceIdentity>("VmInstanceIdentity")({
  id: VmId,
  scheme: Schema.Literal(INSTANCE_IDENTITY_SCHEME),
  fingerprint: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)),
  presence: Schema.optional(Schema.Literal("present", "missing").annotations({ description: "Present only when checkPresence=true. Missing means this caller owns the allocation but its VM is gone; an inaccessible allocation remains 404." })),
}) {}

export const VmInstanceIdentityQuery = Schema.Struct({ checkPresence: Schema.optional(Schema.Literal("true")) });
