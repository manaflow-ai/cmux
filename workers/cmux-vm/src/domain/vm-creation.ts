/** Safe retained evidence: public intent, domain-separated digests and resource floors only. */
import { Schema } from "effect";
import { VmCreationReceipt } from "../api/creations.ts";

export const VmCreationProbe = Schema.Struct({
  provider: Schema.String,
  environment: Schema.String,
  request: Schema.String,
  source: Schema.optional(Schema.String),
});
export type VmCreationProbe = typeof VmCreationProbe.Type;

export const RetainedVmCreation = Schema.Struct({
  receipt: VmCreationReceipt,
  probe: VmCreationProbe,
  createdAt: Schema.String,
  floors: Schema.Struct({ vcpus: Schema.optional(Schema.Number), memoryMib: Schema.optional(Schema.Number), diskMib: Schema.optional(Schema.Number) }),
});
export type RetainedVmCreation = typeof RetainedVmCreation.Type;
