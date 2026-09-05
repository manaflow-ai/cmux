import {
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { isVmNotFoundError } from "../../../../../services/vms/errors";
import { resizeVm, runVmWorkflow } from "../../../../../services/vms/workflows";
import { VM_DISK_MB_MAX, VM_DISK_MB_STEP } from "../../../../../services/vms/machineSpec";

/** Grow a Cloud VM's disk. The provider and this route both enforce grow-only semantics. */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/resize",
    { "cmux.vm.operation": "resize" },
    "/api/vm/[id]/resize POST failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      const storageMb = body && typeof body === "object" && "storageMb" in body
        ? (body as { storageMb: unknown }).storageMb
        : undefined;
      if (
        typeof storageMb !== "number" ||
        !Number.isSafeInteger(storageMb) ||
        storageMb <= 0 ||
        storageMb % VM_DISK_MB_STEP !== 0 ||
        storageMb > VM_DISK_MB_MAX
      ) {
        return jsonResponse({
          error: "invalid disk size",
          message: `storageMb must be a whole GiB size between ${VM_DISK_MB_STEP / 1024} and ${VM_DISK_MB_MAX / 1024} GiB.`,
          details: { minGiB: VM_DISK_MB_STEP / 1024, maxGiB: VM_DISK_MB_MAX / 1024, stepGiB: VM_DISK_MB_STEP / 1024 },
        }, 400);
      }
      span.setAttribute("cmux.vm.id", id);
      try {
        const stats = await runVmWorkflow(resizeVm({
          userId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          billingPlanId: account.entitlements.planId,
          teamIds: user.teamIds,
          providerVmId: id,
          storageMb,
          maxActiveVms: account.entitlements.maxActiveVms,
        }));
        return jsonResponse({
          id,
          diskTotalMb: stats.diskTotalMb,
          diskUsedMb: stats.diskUsedMb,
          state: stats.state,
          sampledAt: stats.sampledAt,
          maxDiskMb: VM_DISK_MB_MAX,
        });
      } catch (err) {
        if (isVmNotFoundError(err)) return notFoundVm(id);
        throw err;
      }
    },
  );
}
