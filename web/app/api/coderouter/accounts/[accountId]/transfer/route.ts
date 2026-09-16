import { transferAccount } from "../../../../../../services/coderouter/accounts";
import { resolveCodeRouterRequestContext } from "../../../../../../services/coderouter/requestContext";
import { authorizedSubrouterTeams } from "../../../../../../services/subrouter/routeHelpers";
import type { AuthedUser } from "../../../../../../services/vms/auth";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

type TransferDependencies = {
  readonly resolve: typeof resolveCodeRouterRequestContext;
  readonly listTeams: (user: AuthedUser) => ReturnType<typeof authorizedSubrouterTeams> | Promise<ReturnType<typeof authorizedSubrouterTeams>>;
  readonly transfer: typeof transferAccount;
};

const defaultTransferDependencies: TransferDependencies = {
  resolve: resolveCodeRouterRequestContext,
  listTeams: authorizedSubrouterTeams,
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
    const destination = (await dependencies.listTeams(resolved.value.user)).find(
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
