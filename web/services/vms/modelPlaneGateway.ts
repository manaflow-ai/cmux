// Adapter between the VM workflows and the coderouter model plane, so
// workflows.ts never imports coderouter code. Routes build the gateway with
// the caller's billing team and hand it to createVm/restoreVm; destroy paths
// hand over the revoker only.
import {
  provisionVmModelPlane,
  revokeVmModelPlane,
  vmModelPlaneEnabled,
  type VmModelPlaneProvision,
} from "../coderouter/vmModelPlane";
import { captureCoderouterError } from "../errors";
import { VmModelPlaneError } from "./errors";

export type VmModelPlaneGateway = {
  /** Rejects with {@link VmModelPlaneError}; the workflow fails the create on it. */
  readonly provision: (cloudVmId: string) => Promise<VmModelPlaneProvision>;
  /** Idempotent; the workflow calls it best-effort on destroy and on every create rollback. */
  readonly revoke: (cloudVmId: string) => Promise<void>;
};

/**
 * The gateway for one provisioning call, or undefined when the local-dev
 * kill switch (CMUX_VM_CODEROUTER_ENV_ENABLED=0) asks for an unwired machine.
 */
export function vmModelPlaneGatewayFor(input: {
  readonly teamId: string;
  readonly stackUserId: string;
}): VmModelPlaneGateway | undefined {
  if (!vmModelPlaneEnabled(process.env.CMUX_VM_CODEROUTER_ENV_ENABLED)) {
    console.warn(
      "[vm] CMUX_VM_CODEROUTER_ENV_ENABLED is off: creating an unwired machine (local development only)",
    );
    return undefined;
  }
  return {
    provision: async (cloudVmId) => {
      try {
        return await provisionVmModelPlane({
          teamId: input.teamId,
          stackUserId: input.stackUserId,
          cloudVmId,
        });
      } catch (cause) {
        captureCoderouterError(cause, { operation: "provision_vm_model_plane", vmId: cloudVmId });
        throw new VmModelPlaneError({ kind: "unavailable", cause });
      }
    },
    revoke: revokeVmModelPlaneTokens,
  };
}

/** The revoke half alone, for destroy paths that have no provisioning context. */
export function vmModelPlaneRevoker(): Pick<VmModelPlaneGateway, "revoke"> {
  return { revoke: revokeVmModelPlaneTokens };
}

async function revokeVmModelPlaneTokens(cloudVmId: string): Promise<void> {
  try {
    await revokeVmModelPlane(cloudVmId);
  } catch (cause) {
    captureCoderouterError(cause, { operation: "revoke_vm_model_plane", vmId: cloudVmId });
    throw cause;
  }
}
