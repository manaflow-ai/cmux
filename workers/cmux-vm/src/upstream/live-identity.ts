import { Effect } from "effect";
import { instanceFingerprint } from "../../../../libs/vm-instance-identity/src/identity.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import type { UpstreamClientService } from "./client.ts";

/** The ownership proof is the only source of a canonical private identity. */
export const vmInstanceIdentity: Pick<UpstreamClientService, "instanceFingerprint"> = {
  instanceFingerprint: (_vm, { owns }) => Effect.promise(() => instanceFingerprint(upstreamIdOf(owns))),
};
