import { z } from "zod";
import * as accessGrantsRoute from "@/app/api/vm/access-grants/route";
import * as accessGrantRoute from "@/app/api/vm/access-grants/[id]/route";
import * as networkRoute from "@/app/api/vm/[id]/network/route";
import * as resumeRoute from "@/app/api/vm/[id]/resume/route";
import { VM_CLIENT_TIMEOUT_HEADER } from "@/services/vms/routeDeadline";
import { listUserVms, runVmWorkflow } from "@/services/vms/workflows";
import { authed, dashboardOS, requireDashboardOrigin } from "./base";
import { callRoute } from "./route-call";
import {
  cloudDevicesSchema,
  cloudMachineResumeSchema,
  cloudMachinesSchema,
  cloudNetworkStateSchema,
} from "./schemas/cloud";

/**
 * The VM access-grant routes own authentication, request telemetry, and the
 * Stack session revocation after a revoke, and the macOS app calls them, so
 * these procedures run them in process behind the browser origin check.
 */
const cloudOS = dashboardOS.use(requireDashboardOrigin);

const grantInput = z.object({ id: z.string().trim().min(1).max(200) });

const devices = cloudOS
  .output(cloudDevicesSchema)
  .handler(async ({ context }) =>
    cloudDevicesSchema.parse(await callRoute(context, accessGrantsRoute.GET, { method: "GET", path: "/api/vm/access-grants" }))
  );

const renameDevice = cloudOS
  .input(grantInput.extend({ displayName: z.string().trim().max(63) }))
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, accessGrantRoute.PATCH, {
      method: "PATCH",
      path: `/api/vm/access-grants/${encodeURIComponent(input.id)}`,
      params: { id: input.id },
      body: { displayName: input.displayName },
    });
    return null;
  });

const revokeDevice = cloudOS
  .input(grantInput)
  .output(z.null())
  .handler(async ({ context, input }) => {
    await callRoute(context, accessGrantRoute.DELETE, {
      method: "DELETE",
      path: `/api/vm/access-grants/${encodeURIComponent(input.id)}`,
      params: { id: input.id },
    });
    return null;
  });

/**
 * The caller's Cloud machines: personal machines plus the selected team's.
 * Team machines carry the team id so the network procedures resolve the same
 * account scope the VM routes use.
 */
const machines = authed
  .output(cloudMachinesSchema)
  .handler(async ({ context }) => {
    const { user } = context;
    const selectedTeamId = user.selectedTeam?.id ?? null;
    const teamId = selectedTeamId && selectedTeamId !== user.id ? selectedTeamId : null;
    const [personal, team] = await Promise.all([
      runVmWorkflow(listUserVms(user.id)),
      teamId ? runVmWorkflow(listUserVms(user.id, teamId)) : Promise.resolve([]),
    ]);
    return {
      machines: [
        ...personal.map((vm) => ({ vm, teamId: null })),
        ...team.map((vm) => ({ vm, teamId })),
      ].map(({ vm, teamId: owner }) => ({
        id: vm.providerVmId,
        name: vm.displayName ?? vm.slug ?? vm.providerVmId,
        status: vm.status,
        teamId: owner,
      })),
    };
  });

const machineInput = z.object({
  id: z.string().trim().min(1).max(200),
  teamId: z.string().trim().min(1).max(200).nullable(),
});

function machineCall(input: z.output<typeof machineInput>, action: "network" | "resume") {
  return {
    path: `/api/vm/${encodeURIComponent(input.id)}/${action}`,
    params: { id: input.id },
    search: { teamId: input.teamId },
  };
}

/** The `/api/vm/{id}/network` route owns auth, scope, and validation. */
const network = cloudOS
  .input(machineInput)
  .output(cloudNetworkStateSchema)
  .handler(async ({ context, input }) =>
    cloudNetworkStateSchema.parse(await callRoute(context, networkRoute.GET, { method: "GET", ...machineCall(input, "network") }))
  );

const setNetwork = cloudOS
  .input(machineInput.extend({ policy: z.unknown() }))
  .output(cloudNetworkStateSchema)
  .handler(async ({ context, input }) =>
    cloudNetworkStateSchema.parse(await callRoute(context, networkRoute.PUT, {
      method: "PUT",
      ...machineCall(input, "network"),
      body: input.policy,
    }))
  );

/**
 * Wake a paused machine from the browser, so a machine can be resumed without
 * the Mac app. `POST /api/vm/{id}/resume` (what `cmux vm resume` and the iPhone
 * call) owns auth, account scope, plan limits, and the provider wait; a running
 * machine answers `running`. The browser waits as long as the iPhone does (16
 * minutes), so the route waits for `running` instead of answering "still
 * resuming" after the CLI's 180 s budget.
 */
const DASHBOARD_RESUME_TIMEOUT_MS = 960_000;

const resumeMachine = cloudOS
  .input(machineInput)
  .output(cloudMachineResumeSchema)
  .handler(async ({ context, input }) =>
    cloudMachineResumeSchema.parse(await callRoute(context, resumeRoute.POST, {
      method: "POST",
      ...machineCall(input, "resume"),
      headers: { [VM_CLIENT_TIMEOUT_HEADER]: String(DASHBOARD_RESUME_TIMEOUT_MS) },
    }))
  );

export const cloudRouter = { devices, renameDevice, revokeDevice, machines, network, setNetwork, resumeMachine };
