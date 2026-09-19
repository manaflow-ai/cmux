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
import { vmCapabilitiesFor } from "../../../../services/vms/drivers";
import { vmImageKindFor } from "../../../../services/vms/images/resolver";
import { PublicationNotFoundError } from "../../../../services/vm-publications/repository";
import { deleteVmPublicationsForVmDeletion } from "../../../../services/vm-publications/vmDeletion";
import { publicationErrorResponse } from "../publications/routeShared";
import { vmModelPlaneRevoker } from "../../../../services/vms/modelPlaneGateway";


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
      }), { request });
      if (!run.ok) return run.response;
      const vm = run.value;
      // The same machine shape `GET /api/vm` lists: `kind` is what the client
      // shows a Displays row and opens the desktop for (`cmux vm status`,
      // `cmux vm open`), and `address` is the private address those open.
      return jsonResponse({
        id: vm.providerVmId,
        provider: vm.provider,
        image: vm.image,
        imageVersion: vm.imageVersion,
        kind: vmImageKindFor(vm.provider, vm.image),
        capabilities: vmCapabilitiesFor(vm.provider),
        status: vm.status,
        createdAt: vm.createdAt,
        displayName: vm.displayName,
        slug: vm.slug,
        ...(vm.providerStatusObservedAt === null ? {} : { providerStatusObservedAt: vm.providerStatusObservedAt }),
        ...(vm.providerStatusCheckedAt === null ? {} : { providerStatusCheckedAt: vm.providerStatusCheckedAt }),
        address: { ipv4: vm.addressIpv4 ?? null, ipv6: vm.addressIpv6 ?? null },
      });
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
      }), { request });
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
      }), { request });
      if (!run.ok) return run.response;
      return jsonResponse({ ok: true });
    },
  );
}
