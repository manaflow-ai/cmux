import {
  browserMutationOriginAllowed,
  jsonResponse,
  parseBearer,
  requestedVmTeamIdFromRequest,
  requiresBrowserMutationProtection,
} from "../vms/routeHelpers";
import {
  isSubrouterAuthorizationError,
  unauthorized,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
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
  options: {
    readonly permission?: "use" | "manage" | "use-or-manage";
  } = {},
): Promise<
  | { readonly ok: true; readonly value: SubrouterRequestContext }
  | { readonly ok: false; readonly response: Response }
> {
  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const requestedTeamId = requestedVmTeamIdFromRequest(request);
      const user = await verifySubrouterRequest(request, signal, {
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

      const team = await resolveTeam(request, user);
      if (!team.ok) return team;
      const permission = options.permission ?? "use";
      const permitted = permission === "manage"
        ? team.manageAccounts
        : permission === "use-or-manage"
        ? team.use || team.manageAccounts
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
    });
  } catch (error) {
    if (isSubrouterAuthorizationError(error)) {
      console.error("Subrouter authorization unavailable", {
        errorType: error.name,
      });
      return {
        ok: false,
        response: serviceUnavailableResponse(),
      };
    }
    throw error;
  }
}
