import { cmuxTuiRunCommand } from "../vms/drivers/cmuxTuiDaemon";
import type { VmRouteResult } from "../vms/routeWorkflow";
import { execVm, listUserVms, type VmModelPlaneRevoker, type VmWorkflowProgram } from "../vms/workflows";
import { CloudMcpToolError, type CloudMcpGateway } from "./cloudMcp";

/** The authenticated caller, resolved exactly as `/api/vm` resolves it. */
export type CloudMcpCaller = {
  readonly userId: string;
  readonly teamIds: readonly string[];
  /** Scope for machine access (exec), as `POST /api/vm/:id/exec` resolves it. */
  readonly billingTeamId: string | null;
  /** Scope for listing, as `GET /api/vm` resolves it: null lists a personal account's own machines. */
  readonly listBillingTeamId: string | null;
  readonly maxActiveVms: number | null;
  readonly planId: string | null;
};

export type CloudMcpProgramRunner = <A>(program: VmWorkflowProgram<A>) => Promise<VmRouteResult<A>>;

async function toolErrorFromResponse(response: Response): Promise<CloudMcpToolError> {
  let code = `http_${response.status}`;
  let message = `The machine request failed with HTTP ${response.status}.`;
  try {
    const body = await response.json() as { error?: unknown; message?: unknown };
    if (typeof body.error === "string") code = body.error;
    if (typeof body.message === "string") message = body.message;
  } catch {
    // keep the status-only message
  }
  return new CloudMcpToolError(code, message);
}

/**
 * Binds the MCP tools to one caller. Machine listing and every guest command go
 * through the same Effect programs as `GET /api/vm` and `POST /api/vm/:id/exec`,
 * so a machine outside the caller's scope fails as `vm_not_found` before the
 * provider is asked to run anything.
 */
export function cloudMcpGatewayFor(
  caller: CloudMcpCaller,
  run: CloudMcpProgramRunner,
  modelPlane?: VmModelPlaneRevoker,
): CloudMcpGateway {
  return {
    listMachines: async () => {
      const listed = await run(listUserVms(caller.userId, caller.listBillingTeamId));
      if (!listed.ok) throw await toolErrorFromResponse(listed.response);
      return listed.value.map((entry) => ({
        id: entry.providerVmId,
        name: entry.displayName ?? entry.slug ?? null,
        status: entry.status,
      }));
    },
    runCmuxTui: async (machineId, args, timeoutMs) => {
      const result = await run(execVm({
        userId: caller.userId,
        billingTeamId: caller.billingTeamId,
        teamIds: caller.teamIds,
        maxActiveVms: caller.maxActiveVms,
        callerPlanId: caller.planId,
        providerVmId: machineId,
        command: cmuxTuiRunCommand(args),
        timeoutMs,
        modelPlane,
      }));
      if (!result.ok) throw await toolErrorFromResponse(result.response);
      return result.value;
    },
  };
}
