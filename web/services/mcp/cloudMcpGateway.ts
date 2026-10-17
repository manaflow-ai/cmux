import { cmuxTuiRunCommand } from "../vms/drivers/cmuxTuiDaemon";
import type { VmRouteResult } from "../vms/routeWorkflow";
import { execVm, listUserVms, type VmModelPlaneRevoker, type VmWorkflowProgram } from "../vms/workflows";
import { CloudMcpToolError, type CloudMcpGateway, type CloudMcpMachine } from "./cloudMcp";
import { CLOUD_PLAN_INFO_URL, type CloudMcpProfile } from "./cloudMcpCloudTools";

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
  /** Granted OAuth scopes; null for a full Stack session. */
  readonly scopes: readonly string[] | null;
  readonly profile: CloudMcpProfile;
  readonly teamName: string | null;
  readonly insufficientScopeChallenge?: (scope: string) => string;
  readonly settings: {
    readonly read: () => Promise<Record<string, unknown>>;
    readonly write: (values: Record<string, unknown>) => Promise<void>;
  };
  /** Runs an `/api/vm` route handler in process as this caller. */
  readonly vmRoute: CloudMcpVmRouteCaller;
  /** As `GET /api/vm` resolves it: null lists a personal account's own machines. */
  readonly listScope: () => Promise<string | null>;
  readonly accessScope: () => Promise<CloudMcpAccessScope>;
};

export type CloudMcpVmRouteCaller = (input: {
  readonly method: "GET" | "POST" | "DELETE";
  /** `/api/vm`, `/api/vm/<id>`, `/api/vm/<id>/pause` or `/api/vm/<id>/resume`. */
  readonly path: string;
  readonly body?: Record<string, unknown>;
  readonly idempotencyKey?: string;
}) => Promise<Response>;

export type CloudMcpProgramRunner = <A>(program: VmWorkflowProgram<A>) => Promise<VmRouteResult<A>>;

/**
 * Turns an `/api/vm` error response into the tool error the MCP client sees.
 * A plan refusal keeps the route's explanation and points at the pricing page;
 * the route's own "upgrade" call to action is dropped, because a plugin may
 * explain a plan limit but not promote an upgrade.
 */
export async function toolErrorFromResponse(response: Response): Promise<CloudMcpToolError> {
  let code = `http_${response.status}`;
  let message = `The machine request failed with HTTP ${response.status}.`;
  let planRequired = response.status === 402;
  try {
    const body = await response.json() as { error?: unknown; message?: unknown; upgradeRequired?: unknown };
    if (typeof body.error === "string") code = body.error;
    if (typeof body.message === "string") message = body.message;
    if (body.upgradeRequired === true) planRequired = true;
  } catch {
    // keep the status-only message
  }
  if (!planRequired) return new CloudMcpToolError(code, message);
  return new CloudMcpToolError(
    code,
    `${message} This is not included in the connected team's current plan. Plans are described at ${CLOUD_PLAN_INFO_URL}.`,
    { plan_required: true, plan_info_url: CLOUD_PLAN_INFO_URL },
  );
}

async function vmJson(caller: CloudMcpCaller, input: Parameters<CloudMcpVmRouteCaller>[0]): Promise<Record<string, unknown>> {
  const response = await caller.vmRoute(input);
  if (!response.ok) throw await toolErrorFromResponse(response);
  return await response.json() as Record<string, unknown>;
}

function machineFrom(body: Record<string, unknown>, fallbackStatus: string): CloudMcpMachine {
  const name = typeof body.displayName === "string" ? body.displayName : typeof body.slug === "string" ? body.slug : null;
  return {
    id: String(body.id),
    name,
    status: typeof body.status === "string" ? body.status : fallbackStatus,
  };
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
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
  const machinePath = (machineId: string) => `/api/vm/${encodeURIComponent(machineId)}`;
  return {
    scopes: caller.scopes,
    insufficientScopeChallenge: caller.insufficientScopeChallenge,
    profile: async () => caller.profile,
    account: async () => {
      const body = await vmJson(caller, { method: "GET", path: "/api/vm" });
      const limits = (body.limits ?? {}) as Record<string, unknown>;
      return {
        planId: typeof limits.planId === "string" ? limits.planId : null,
        teamName: caller.teamName,
        maxActiveVms: numberOrNull(limits.maxActiveVms),
        activeVmCount: numberOrNull(limits.activeVmCount),
        memoryOptionsMb: Array.isArray(limits.memoryOptionsMb) ? limits.memoryOptionsMb.filter((mb): mb is number => typeof mb === "number") : [],
      };
    },
    createMachine: async (input) => {
      const created = await vmJson(caller, {
        method: "POST",
        path: "/api/vm",
        body: { ...(input.displayName ? { displayName: input.displayName } : {}), memoryMb: input.memoryMb },
        idempotencyKey: input.idempotencyKey,
      });
      const machine = machineFrom(created, "running");
      // The create reply has no status; read it once so the caller sees the real state.
      const status = await caller.vmRoute({ method: "GET", path: machinePath(machine.id) });
      if (!status.ok) return machine;
      return machineFrom({ ...created, ...(await status.json() as Record<string, unknown>) }, machine.status);
    },
    setMachineState: async (machineId, action) => {
      const body = await vmJson(caller, { method: "POST", path: `${machinePath(machineId)}/${action}` });
      return machineFrom(body, action === "pause" ? "paused" : "running");
    },
    deleteMachine: async (machineId) => {
      await vmJson(caller, { method: "DELETE", path: machinePath(machineId) });
    },
    readSettings: caller.settings.read,
    writeSettings: caller.settings.write,
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
