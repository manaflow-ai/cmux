import {
  creatorFor,
  readCreatorNames,
} from "../../../../services/vms/creators";
import { normalizedDisplayName } from "../../../../services/vms/displayName";
import { readVmRunningSince, vmCostFields } from "../../../../services/vms/machineCost";
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
import { gcpCredentialFromRequest } from "../../../../services/vms/routeInput";


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
      const providerCredential = gcpCredentialFromRequest(request);
      const run = await runVmRoute(getVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        // A status read is how a gone machine is usually noticed first, and the
        // row it retires is one no destroy or cron pass can revisit.
        modelPlane: vmModelPlaneRevoker(),
        providerCredential,
      }), { request, readDeadline: { operation: "getVm" } });
      if (!run.ok) return run.response;
      const vm = run.value;
      const live = vm.status === "running" || vm.status === "provisioning";
      // Both side reads are bounded and best effort; start them together so a
      // stalled database costs one bound, not two, as in the list.
      const [creatorNames, runningSince] = await Promise.all([
        readCreatorNames({
          userIds: [vm.createdByUserId],
          teamId: vm.ownerTeamId,
          caller: user,
        }),
        live
          ? readVmRunningSince([vm.providerVmId], {
            onFailure: (error) => setSpanAttributes(span, {
              "cmux.vm.running_since_error": error instanceof Error ? error.name : "unknown",
            }),
          })
          : Promise.resolve(new Map<string, Date>()),
      ]);
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
        // Same field the list carries. A client that merges a detail read into
        // the row it already listed would otherwise overwrite the author with
        // nothing, and the resulting "Unknown" reads as a client bug.
        createdBy: creatorFor(vm, creatorNames),
        address: { ipv4: vm.addressIpv4 ?? null, ipv6: vm.addressIpv6 ?? null },
        agentUpdates: vm.agentUpdates,
        idlePauseMinutes: vm.idlePauseMinutes,
        pauseReason: vm.pauseReason,
        // Contract recorded when the provider attached cmux-tui. This is
        // rollout metadata, not a live daemon probe.
        cmuxTuiContract: vm.cmuxTuiContract,
        // Same cost fields as the list, so a detail read never drops them.
        ...vmCostFields(vm, runningSince.get(vm.providerVmId)),
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
      const providerCredential = gcpCredentialFromRequest(request);
      const run = await runVmRoute(destroyVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
        modelPlane: vmModelPlaneRevoker(),
        providerCredential,
      }), { request, deadline: { operation: "destroy" } });
      if (!run.ok) return run.response;
      return jsonResponse({ ok: true });
    },
  );
}
