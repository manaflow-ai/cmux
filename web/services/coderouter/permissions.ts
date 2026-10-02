import { Effect } from "effect";
import { getStackServerApp } from "../../app/lib/stack";
import { authorizedSubrouterTeams } from "../subrouter/routeHelpers";
import { SubrouterAuthorizationUnavailableError, type AuthedUser } from "../vms/auth";

/** Provider accounts are team resources: every member may add, change, share
 * their own imports, transfer and remove them (routeHelpers MEMBER_CAPABILITIES).
 * No route ever returns a stored provider secret, so management never grants
 * reading one. CodeRouter API keys are different: each is a long-lived bearer
 * credential for the whole team, so creating or revoking one follows Stack's
 * API-key administration permission. A VM principal never reaches this
 * human-only control-plane check. */
export async function canManageCoderouterApiKeys(userId: string, teamId: string): Promise<boolean> {
  if (userId === teamId) return true;
  const result = await Effect.runPromise(Effect.tryPromise(async () => {
    const app = getStackServerApp();
    const [user, team] = await Promise.all([app.getUser(userId), app.getTeam(teamId)]);
    if (!user || !team) return false;
    return user.hasPermission(team, "$manage_api_keys");
  }).pipe(Effect.timeout("10 seconds"), Effect.either));
  if (result._tag === "Left") throw new SubrouterAuthorizationUnavailableError("CodeRouter API key authorization unavailable");
  return result.right;
}

export async function authorizedCoderouterTeams(user: AuthedUser) {
  const teams = authorizedSubrouterTeams(user);
  return Promise.all(teams.map(async team => ({ ...team,
    manageApiKeys: await canManageCoderouterApiKeys(user.id, team.teamId),
  })));
}

/** The API-key routes' gate: null when the caller may create or revoke the
 * team's API keys, otherwise the response to send. */
export async function apiKeyAdministrationRefusal(
  userId: string,
  teamId: string,
  canManage: typeof canManageCoderouterApiKeys = canManageCoderouterApiKeys,
): Promise<Response | null> {
  let allowed: boolean;
  try {
    allowed = await canManage(userId, teamId);
  } catch (error) {
    if (!(error instanceof SubrouterAuthorizationUnavailableError)) throw error;
    return Response.json(
      { error: "authorization_unavailable", retryable: true },
      { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } },
    );
  }
  return allowed
    ? null
    : Response.json({ error: "forbidden", permission: "$manage_api_keys" }, { status: 403 });
}
