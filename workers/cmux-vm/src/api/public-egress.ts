/** Public Internet egress of an existing VM: read it, or turn it on. Provider rule ids never leave src/upstream. */
import { Schema } from "effect";
import { VmId } from "../lib/ids.ts";

export class VmPublicEgress extends Schema.Class<VmPublicEgress>("VmPublicEgress")({
  id: VmId,
  publicEgress: Schema.Boolean.annotations({
    description: "True when a rule whose source is exactly this VM allows the public Internet on every port (the rule a create with initialNetwork.publicEgress makes, or this endpoint's).",
  }),
}) {}
