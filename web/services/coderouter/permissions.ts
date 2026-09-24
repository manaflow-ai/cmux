import { Effect } from "effect";
import { getStackServerApp } from "../../app/lib/stack";
import { authorizedSubrouterTeams } from "../subrouter/routeHelpers";
import { SubrouterAuthorizationUnavailableError, type AuthedUser } from "../vms/auth";

/** Provider credentials follow Stack's API-key administration permission.
 * A VM principal never reaches this human-only control-plane check. */
export async function canManageCoderouterAccounts(userId: string, teamId: string): Promise<boolean> {
  if (userId === teamId) return true;
  const result = await Effect.runPromise(Effect.tryPromise(async () => {
    const app = getStackServerApp();
    const [user, team] = await Promise.all([app.getUser(userId), app.getTeam(teamId)]);
    if (!user || !team) return false;
    return user.hasPermission(team, "$manage_api_keys");
  }).pipe(Effect.timeout("10 seconds"), Effect.either));
  if (result._tag === "Left") throw new SubrouterAuthorizationUnavailableError("CodeRouter management authorization unavailable");
  return result.right;
}

export async function authorizedCoderouterTeams(user: AuthedUser) {
  const teams = authorizedSubrouterTeams(user);
  return Promise.all(teams.map(async team => ({ ...team,
    manageAccounts: await canManageCoderouterAccounts(user.id, team.teamId),
  })));
}
