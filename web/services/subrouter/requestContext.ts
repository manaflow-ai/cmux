import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requestedVmTeamIdFromRequest,
  requiresBrowserMutationProtection,
} from "../vms/routeHelpers";
import {
  unauthorized,
  verifyRequest,
  type AuthedUser,
} from "../vms/auth";
import {
  createSubrouterClient,
  subrouterRuntimeConfig,
  type SubrouterClient,
  type SubrouterRuntimeConfig,
} from "./client";
import {
  resolveTeam,
  serviceUnavailableResponse,
} from "./routeHelpers";

export type SubrouterRequestContext = {
  readonly user: AuthedUser;
  readonly team: {
    readonly teamId: string;
    readonly teamName: string;
    readonly use: boolean;
    readonly manageAccounts: boolean;
  };
  readonly config: SubrouterRuntimeConfig;
  readonly client: SubrouterClient;
};

export async function resolveSubrouterRequestContext(
  request: Request,
  options: { readonly manageAccounts?: boolean } = {},
): Promise<
  | { readonly ok: true; readonly value: SubrouterRequestContext }
  | { readonly ok: false; readonly response: Response }
> {
  const requestedTeamId = requestedVmTeamIdFromRequest(request);
  const user = await verifyRequest(request, {
    requestedTeamId,
    allowCookie: true,
  });
  if (!user) return { ok: false, response: unauthorized() };

  const bearer = parseBearer(request);
  if (
    requiresBrowserMutationProtection(request.method, bearer) &&
    !browserMutationOriginAllowed(request)
  ) {
    return {
      ok: false,
      response: jsonResponse({ error: "forbidden" }, 403),
    };
  }

  const team = resolveTeam(request, user);
  if (!team.ok) return team;
  const permitted = options.manageAccounts
    ? team.manageAccounts
    : team.use;
  if (!permitted) {
    return {
      ok: false,
      response: jsonResponse({ error: "forbidden" }, 403),
    };
  }

  const config = subrouterRuntimeConfig();
  if (!config) {
    return {
      ok: false,
      response: serviceUnavailableResponse(),
    };
  }

  return {
    ok: true,
    value: {
      user,
      team,
      config,
      client: createSubrouterClient({
        baseUrl: config.baseUrl,
        adminToken: config.adminToken,
      }),
    },
  };
}
