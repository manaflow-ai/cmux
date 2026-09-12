import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../services/vms/routeHelpers";
import { runVmRoute } from "../../../../../services/vms/routeWorkflow";
import { resizeVm } from "../../../../../services/vms/workflows";
import { VM_DISK_MB_MAX, VM_DISK_MB_STEP } from "../../../../../services/vms/machineSpec";
import { maxDiskMbForPlan, maxMemoryMbForPlan, maxVcpusForPlan } from "../../../../../services/vms/entitlements";

/** Grow a Cloud VM's resources. The workflow owns plan and grow-only checks. */
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
      const candidate = body && typeof body === "object" && !Array.isArray(body)
        ? body as Record<string, unknown> : {};
      const { storageMb, cpu, memoryMb } = candidate;
      const dimensions = [storageMb, cpu, memoryMb];
      if (dimensions.every((value) => value === undefined) || dimensions.some((value) =>
        value !== undefined && (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0)
      ) || (typeof storageMb === "number" && (storageMb % VM_DISK_MB_STEP !== 0 || storageMb > VM_DISK_MB_MAX)) ||
        (typeof memoryMb === "number" && (memoryMb % 1024 !== 0 || memoryMb > 64 * 1024)) ||
        (typeof cpu === "number" && cpu > 32)) {
        return jsonResponse({
          error: "invalid resize size",
          message: "Provide cpu (1–32), memoryMb (whole GiB, up to 64 GiB), or storageMb (4 GiB steps, up to 256 GiB).",
        }, 400);
      }
      span.setAttribute("cmux.vm.id", id);
      const run = await runVmRoute(resizeVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        billingPlanId: account.entitlements.planId,
        teamIds: user.teamIds,
        providerVmId: id,
        storageMb: storageMb as number | undefined,
        cpu: cpu as number | undefined,
        memoryMb: memoryMb as number | undefined,
        maxActiveVms: account.entitlements.maxActiveVms,
      }), { request });
      if (!run.ok) return run.response;
      const stats = run.value;
      return jsonResponse({
        id,
        ...stats,
        maxDiskMb: maxDiskMbForPlan(account.entitlements.planId),
        maxMemoryMb: maxMemoryMbForPlan(account.entitlements.planId),
        maxVcpus: maxVcpusForPlan(account.entitlements.planId),
      });
    },
  );
}
