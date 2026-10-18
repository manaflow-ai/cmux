import { Schema } from "effect";
import { VmId } from "../lib/ids.ts";
import { INSTANCE_IDENTITY_SCHEME } from "../../../../libs/vm-instance-identity/src/identity.ts";

export class VmInstanceIdentity extends Schema.Class<VmInstanceIdentity>("VmInstanceIdentity")({
  id: VmId,
  scheme: Schema.Literal(INSTANCE_IDENTITY_SCHEME),
  fingerprint: Schema.String.pipe(Schema.pattern(/^[0-9a-f]{64}$/)),
}) {}
