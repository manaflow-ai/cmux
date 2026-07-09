import { cloudDb } from "../../../../../db/client";
import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requestedVmTeamIdFromRequest,
  requiresBrowserMutationProtection,
} from "../../../../../services/vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
} from "../../../../../services/vms/auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
} from "../../../../../services/subrouter/client";
import {
  withAccountDeletionUserMutationLock,
} from "../../../../../services/account/deletion";
import {
  resolveTeam,
  serviceUnavailableResponse,
  subrouterErrorResponse,
} from "../../../../../services/subrouter/routeHelpers";
import { getTenantForTeam } from "../../../../../services/subrouter/tenants";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RouteContext = {
  params: Promise<{ accountId: string }>;
};

export async function DELETE(request: Request, context: RouteContext): Promise<Response> {
  const { accountId } = await context.params;
  const normalizedAccountId = accountId.trim();
  if (!normalizedAccountId || normalizedAccountId.length > 200) {
    return jsonResponse({ error: "invalid_request" }, 400);
  }

  const requestedTeamId = requestedVmTeamIdFromRequest(request);
  const user = await verifyRequest(request, {
    requestedTeamId,
    allowCookie: true,
  });
  if (!user) return unauthorized();
  const bearer = parseBearer(request);
  if (requiresBrowserMutationProtection(request.method, bearer) && !browserMutationOriginAllowed(request)) {
    return jsonResponse({ error: "forbidden" }, 403);
  }

  const team = resolveTeam(request, user);
  if (!team.ok) return team.response;

  const config = subrouterRuntimeConfig();
  if (!config) return serviceUnavailableResponse();
  const client = createSubrouterClient({
    baseUrl: config.baseUrl,
    adminToken: config.adminToken,
  });

  try {
    const db = cloudDb();
    const tenant = await withAccountDeletionUserMutationLock(
      db,
      user.id,
      async (tx) =>
        await getTenantForTeam(
          tx,
          team.teamId,
          {
            tenantKeySecret: config.tenantKeySecret,
          },
        ),
    );
    if (!tenant) return jsonResponse({ ok: true, teamId: team.teamId });

    await client.deleteAccount(tenant.tenantKey, normalizedAccountId);
    await withAccountDeletionUserMutationLock(db, user.id, async () => undefined);
    return jsonResponse({ ok: true, teamId: team.teamId });
  } catch (err) {
    return subrouterErrorResponse(err);
  }
}
