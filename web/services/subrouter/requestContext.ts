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
  parseNativeStackTokens,
} from "../vms/auth";
import { getStackServerApp } from "../../app/lib/stack";
import {
  createHostedSubrouterClient,
  type HostedSubrouterClient,
} from "./hostedClient";
import { hostedSubrouterCutoverReadyForTeam } from "./cutover";
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
  readonly accessToken: string;
  readonly client: HostedSubrouterClient;
};

export async function resolveSubrouterRequestContext(
  request: Request,
  options: {
    readonly allowCookie?: boolean;
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
        allowCookie: options.allowCookie ?? true,
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

      // Membership is the only requirement; resolveTeam already rejected
      // non-members with team_not_found.
      const team = resolveTeam(request, user);
      if (!team.ok) return team;

      let hostedCutoverReady: boolean;
      try {
        hostedCutoverReady = await hostedSubrouterCutoverReadyForTeam(
          team.teamId,
        );
      } catch (error) {
        console.error("Subrouter cutover state unavailable", {
          errorType: error instanceof Error ? error.name : typeof error,
        });
        return {
          ok: false,
          response: serviceUnavailableResponse(),
        };
      }
      if (!hostedCutoverReady) {
        return {
          ok: false,
          response: jsonResponse(
            { error: "subrouter_migration_pending" },
            503,
          ),
        };
      }

      const client = createHostedSubrouterClient();
      if (!client.tenantControlConfigured) {
        return {
          ok: false,
          response: serviceUnavailableResponse(),
        };
      }

      const nativeTokens = parseNativeStackTokens(request);
      const tokenStore = nativeTokens ?? {
        headers: {
          get: (name: string): string | null => request.headers.get(name),
        },
      };
      // Stack may refresh a native session while verifying it. Forward the
      // authoritative token instead of the possibly stale request header.
      let accessToken: string | null | undefined;
      try {
        const authoritativeTokens = await getStackServerApp().getAuthJson({
          tokenStore,
        });
        accessToken = authoritativeTokens?.accessToken;
      } catch (error) {
        console.error("Subrouter Stack token refresh unavailable", {
          errorType: error instanceof Error ? error.name : typeof error,
        });
        return {
          ok: false,
          response: serviceUnavailableResponse(),
        };
      }
      if (!accessToken) {
        return {
          ok: false,
          response: unauthorized(),
        };
      }

      return {
        ok: true,
        value: {
          user,
          team,
          accessToken,
          client,
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
