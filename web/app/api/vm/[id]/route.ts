import { publicVmDetail } from "../../../../services/vms/publicVm";
import {
  creatorFor,
  readCreatorNames,
} from "../../../../services/vms/creators";
import { normalizedDisplayName } from "../../../../services/vms/displayName";
import {
  invalidVmDisplayNameResponse,
  jsonResponse,
  notFoundVm,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../services/telemetry";
import { runVmRoute } from "../../../../services/vms/routeWorkflow";
import { destroyVm, getVm, renameVm } from "../../../../services/vms/workflows";
import { PublicationNotFoundError } from "../../../../services/vm-publications/repository";
import { deleteVmPublicationsForVmDeletion } from "../../../../services/vm-publications/vmDeletion";
import { publicationErrorResponse } from "../publications/routeShared";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";


// Mirrors VM_ROUTE_DEADLINES (services/vms/routeDeadline.ts): work past the
// route's answer deadline continues through after() until this limit.
export const maxDuration = 300;

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]",
    { "cmux.vm.operation": "status" },
    "/api/vm/[id] GET failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      const run = await runVmRoute(getVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        // A status read is how a gone machine is usually noticed first, and the
        // row it retires is one no destroy or cron pass can revisit.
        modelPlane: vmModelPlaneRevoker(),
      }), { request, readDeadline: { operation: "getVm" } });
      if (!run.ok) return run.response;
      const vm = run.value;
      return jsonResponse(publicVmDetail(vm, creatorFor(vm, await readCreatorNames({
        userIds: [vm.createdByUserId],
        teamId: vm.ownerTeamId,
        caller: user,
      }))));
    },
  );
}


export async function PATCH(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]",
    { "cmux.vm.operation": "rename" },
    "/api/vm/[id] PATCH failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: "invalid JSON body" }, 400);
      }
      if (typeof body !== "object" || body === null || !("displayName" in body)) {
        return jsonResponse({ error: "body must include `displayName`" }, 400);
      }
      const displayName = normalizedDisplayName((body as { displayName: unknown }).displayName);
      if (displayName === undefined) {
        return invalidVmDisplayNameResponse(request);
      }
      const run = await runVmRoute(renameVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        displayName,
      }), { request, deadline: { operation: "rename" } });
      if (!run.ok) return run.response;
      const vm = run.value;
      return jsonResponse({
        id: vm.providerVmId,
        displayName: vm.displayName,
        slug: vm.slug,
      });
    },
  );
}

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]",
    { "cmux.vm.operation": "destroy" },
    "/api/vm/[id] DELETE failed",
    async ({ user, span }) => {
      const { id } = await params;
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id });
      try {
        await deleteVmPublicationsForVmDeletion({
          requesterUserId: user.id,
          billingTeamId: account.entitlements.billingTeamId,
          teamIds: user.teamIds,
          providerVmId: id,
        });
      } catch (err) {
        if (err instanceof PublicationNotFoundError && err.resource === "vm") {
          return notFoundVm(id);
        }
        return publicationErrorResponse(err);
      }
      const run = await runVmRoute(destroyVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        modelPlane: vmModelPlaneRevoker(),
      }), { request, deadline: { operation: "destroy" } });
      if (!run.ok) return run.response;
      return jsonResponse({ ok: true });
    },
  );
}
