import { Effect } from "effect";
import { getStackServerApp } from "../../app/lib/stack";
import { authorizedSubrouterTeams } from "../subrouter/routeHelpers";
import { SubrouterAuthorizationUnavailableError, type AuthedUser } from "../vms/auth";
import { CODEROUTER_ADMIN_PERMISSION } from "./accountAdministration";

/** Account administration follows Stack's API-key administration permission.
 * What it gates is listed in accountAdministration.ts. A VM principal never
 * reaches this human-only control-plane check. */
export async function canManageCoderouterAccounts(userId: string, teamId: string): Promise<boolean> {
  if (userId === teamId) return true;
  const result = await Effect.runPromise(Effect.tryPromise(async () => {
    const app = getStackServerApp();
    const [user, team] = await Promise.all([app.getUser(userId), app.getTeam(teamId)]);
    if (!user || !team) return false;
    return user.hasPermission(team, CODEROUTER_ADMIN_PERMISSION);
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
