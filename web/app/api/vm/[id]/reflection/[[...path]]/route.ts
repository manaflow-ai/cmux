import {
  jsonResponse,
  resolveVmRouteAccountScope,
  withAuthedVmApiRoute,
} from "../../../../../../services/vms/routeHelpers";
import { setSpanAttributes } from "../../../../../../services/telemetry";
import { vmEdgeAliasDomain, vmReflectionAliasDomain } from "../../../../../../services/coderouter/vmGuestEnv";
import {
  normalizeReflectionPath,
  reflectionHasDesktop,
  reflectionPayload,
  type ReflectionContext,
  type ReflectionOwner,
} from "../../../../../../services/vms/reflection";
import { listOwnerLiveVms, loadReflectionOwner } from "../../../../../../services/vms/reflectionStore";
import { runVmRoute } from "../../../../../../services/vms/routeWorkflow";
import { reflectVm } from "../../../../../../services/vms/workflows";
import type { AuthedUser } from "../../../../../../services/vms/auth";

// cmux Reflection from the Mac (`cmux vm self <machine> [path]`): the same
// answer a machine gets from inside (app/api/vm/reflection), read with the
// user's session for a machine the user owns. Same payload builders and the
// same owner-machine loader, so the Mac and the guest never disagree about a
// machine's name, peers, routes, or integrations. Read-only; `cache-control:
// no-store` like the guest route.

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string; path?: string[] }> },
): Promise<Response> {
  return withAuthedVmApiRoute(
    request,
    "/api/vm/[id]/reflection",
    { "cmux.vm.operation": "reflection" },
    "/api/vm/[id]/reflection GET failed",
    async ({ user, span }) => {
      const { id, path: segments = [] } = await params;
      const path = normalizeReflectionPath(segments.join("/"));
      const account = resolveVmRouteAccountScope(user, request);
      if (!account.ok) return account.response;
      setSpanAttributes(span, { "cmux.vm.id": id, "cmux.reflection.path": path });
      const run = await runVmRoute(reflectVm({
        userId: user.id,
        billingTeamId: account.entitlements.billingTeamId,
        teamIds: user.teamIds,
        providerVmId: id,
      }), { request });
      if (!run.ok) return run.response;
      const vm = run.value;
      // The machine's team is its billing team; a personal machine reports the
      // caller's resolved billing scope, which is what its own token carries.
      const teamId = vm.billingTeamId ?? account.entitlements.billingTeamId;
      const [siblings, recordedOwner] = await Promise.all([
        listOwnerLiveVms(vm),
        loadReflectionOwner({ vm, userId: vm.userId, teamId }),
      ]);
      const context: ReflectionContext = {
        self: vm,
        owner: ownerForCaller(recordedOwner, user, account.entitlements.planId),
        siblings,
        aliasOrigin: `https://${vmEdgeAliasDomain()}`,
        reflectionOrigin: `https://${vmReflectionAliasDomain()}`,
        hasDesktop: reflectionHasDesktop(vm),
      };
      const answer = reflectionPayload(path, context);
      return jsonResponse(answer.body, answer.status, { "cache-control": "no-store" });
    },
  );
}

/**
 * The owner as recorded (identity snapshot), completed from the live session
 * when the caller IS the owner: the session is fresher than any snapshot, and
 * a machine created before snapshots existed still gets an email. A teammate
 * reading another member's machine sees only what the snapshot recorded.
 */
function ownerForCaller(recorded: ReflectionOwner, user: AuthedUser, callerPlanId: string): ReflectionOwner {
  const isOwner = user.id === recorded.userId;
  return {
    ...recorded,
    email: recorded.email ?? (isOwner ? user.primaryEmail : null),
    displayName: recorded.displayName ?? (isOwner ? user.displayName : null),
    planId: recorded.planId ?? callerPlanId,
  };
}
