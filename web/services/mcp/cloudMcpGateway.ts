import { cmuxTuiRunCommand } from "../vms/drivers/cmuxTuiDaemon";
import type { VmRouteResult } from "../vms/routeWorkflow";
import { execVm, listUserVms, type VmModelPlaneRevoker, type VmWorkflowProgram } from "../vms/workflows";
import { CloudMcpToolError, type CloudMcpGateway } from "./cloudMcp";

/** Billing scope and limits for machine access, as `POST /api/vm/:id/exec` resolves them. */
export type CloudMcpAccessScope = {
  readonly billingTeamId: string | null;
  readonly maxActiveVms: number | null;
  readonly planId: string | null;
};

/**
 * The authenticated caller. Scopes resolve lazily, on the first tool that needs
 * them, so `initialize` and `tools/list` work even when a team choice is missing;
 * a scope that cannot resolve throws `CloudMcpToolError`.
 */
export type CloudMcpCaller = {
  readonly userId: string;
  readonly teamIds: readonly string[];
  /** As `GET /api/vm` resolves it: null lists a personal account's own machines. */
  readonly listScope: () => Promise<string | null>;
  readonly accessScope: () => Promise<CloudMcpAccessScope>;
};

export type CloudMcpProgramRunner = <A>(program: VmWorkflowProgram<A>) => Promise<VmRouteResult<A>>;

/** Turns an `/api/vm` error response into the tool error the MCP client sees. */
export async function toolErrorFromResponse(response: Response): Promise<CloudMcpToolError> {
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
      const listed = await run(listUserVms(caller.userId, await caller.listScope()));
      if (!listed.ok) throw await toolErrorFromResponse(listed.response);
      return listed.value.map((entry) => ({
        id: entry.providerVmId,
        name: entry.displayName ?? entry.slug ?? null,
        status: entry.status,
      }));
    },
    runCmuxTui: async (machineId, args, timeoutMs) => {
      const scope = await caller.accessScope();
      const result = await run(execVm({
        userId: caller.userId,
        billingTeamId: scope.billingTeamId,
        teamIds: caller.teamIds,
        maxActiveVms: scope.maxActiveVms,
        callerPlanId: scope.planId,
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
