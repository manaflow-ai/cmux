import { transferAccount } from "../../../../../../services/coderouter/accounts";
import { resolveCodeRouterRequestContext } from "../../../../../../services/coderouter/requestContext";
import { authorizedSubrouterTeams } from "../../../../../../services/subrouter/routeHelpers";
import {
  isSubrouterAuthorizationError,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
  type AuthedUser,
} from "../../../../../../services/vms/auth";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type TransferDependencies = {
  readonly resolve: typeof resolveCodeRouterRequestContext;
  readonly listTeams: (
    user: AuthedUser,
    request: Request,
    destinationTeamId: string,
  ) => ReturnType<typeof authorizedSubrouterTeams> | Promise<ReturnType<typeof authorizedSubrouterTeams>>;
  readonly transfer: typeof transferAccount;
};

/**
 * The caller's teams, with the requested destination resolved. The source
 * request's identity lists only its selected and requested team, so a team
 * the caller belongs to is usually absent from `user.teams`. Re-verify the
 * same credentials with an exact Stack lookup of the destination and trust
 * the result only for the same user.
 */
export async function transferDestinationTeams(
  user: AuthedUser,
  request: Request,
  destinationTeamId: string,
  verify: typeof verifySubrouterRequest = verifySubrouterRequest,
): Promise<ReturnType<typeof authorizedSubrouterTeams>> {
  if (!destinationTeamId || destinationTeamId === user.id) return authorizedSubrouterTeams(user);
  const verified = await withSubrouterAuthorizationDeadline((signal) =>
    verify(request, signal, { requestedTeamId: destinationTeamId, allowCookie: true }));
  return verified?.id === user.id ? authorizedSubrouterTeams(verified) : [];
}

const defaultTransferDependencies: TransferDependencies = {
  resolve: resolveCodeRouterRequestContext,
  listTeams: transferDestinationTeams,
  transfer: transferAccount,
};

export const POST = makeCoderouterTransferHandler();

export function makeCoderouterTransferHandler(
  dependencies: TransferDependencies = defaultTransferDependencies,
) {
  return async function POST(
    request: Request,
    context: { params: Promise<{ accountId: string }> },
  ): Promise<Response> {
    const resolved = await dependencies.resolve(request);
    if (!resolved.ok) return resolved.response;
    if (!resolved.value.team.manageAccounts) {
      return Response.json({ error: "forbidden" }, { status: 403 });
    }
    const { accountId } = await context.params;
    if (!UUID.test(accountId)) {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return Response.json({ error: "invalid_request" }, { status: 400 });
    }
    const destinationTeamId = typeof body === "object" && body !== null &&
        "destinationTeamId" in body &&
        typeof (body as { destinationTeamId?: unknown }).destinationTeamId === "string"
      ? (body as { destinationTeamId: string }).destinationTeamId.trim()
      : "";
    let teams: Awaited<ReturnType<TransferDependencies["listTeams"]>>;
    try {
      teams = await dependencies.listTeams(resolved.value.user, request, destinationTeamId);
    } catch (error) {
      if (!isSubrouterAuthorizationError(error)) throw error;
      return Response.json(
        { error: "authorization_unavailable", retryable: true },
        { status: 503, headers: { "retry-after": "5" } },
      );
    }
    const destination = teams.find(
      (team) => team.teamId === destinationTeamId && team.manageAccounts,
    );
    if (!destination || destinationTeamId === resolved.value.team.teamId) {
      return Response.json({ error: "destination_forbidden" }, { status: 403 });
    }
    try {
      const moved = await dependencies.transfer({
        accountId,
        sourceTeamId: resolved.value.team.teamId,
        destinationTeamId,
        stackUserId: resolved.value.user.id,
      });
      return moved
        ? Response.json({ accountId, sourceTeamId: resolved.value.team.teamId, destinationTeamId })
        : Response.json({ error: "not_found" }, { status: 404 });
    } catch {
      return Response.json(
        { error: "account_transfer_unavailable", retryable: true },
        { status: 503, headers: { "retry-after": "5" } },
      );
    }
  };
}
