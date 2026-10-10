import { Effect } from "effect";
import { getStackServerApp } from "../../app/lib/stack";
import { authorizedSubrouterTeams } from "../subrouter/routeHelpers";
import {
  deadlineGatedStackCall,
  SubrouterAuthorizationUnavailableError,
  type AuthedUser,
} from "../vms/auth";

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

/** The organization catalog: every team with its API-key administration grant.
 * Runs inside the caller's authorization deadline. The Stack user is fetched
 * once for all teams (the per-team form fetched it N times), and every call
 * goes through the deadline gate so nothing new starts after the 503. */
export async function authorizedCoderouterTeams(user: AuthedUser, signal: AbortSignal) {
  const teams = authorizedSubrouterTeams(user);
  const memberTeamIds = teams.map(team => team.teamId).filter(teamId => teamId !== user.id);
  const grants = await apiKeyAdministrationGrants(user.id, memberTeamIds, signal);
  return teams.map(team => ({ ...team,
    manageApiKeys: team.teamId === user.id || grants.has(team.teamId),
  }));
}

async function apiKeyAdministrationGrants(
  userId: string,
  teamIds: readonly string[],
  signal: AbortSignal,
): Promise<ReadonlySet<string>> {
  if (teamIds.length === 0) return new Set();
  const app = getStackServerApp();
  const stackUser = await deadlineGatedStackCall(() => app.getUser(userId), signal, "get_user_by_id");
  if (!stackUser) return new Set();
  // Bounded below the shared gate (8 active, 32 queued per instance): an
  // unbounded fan-out for a user in 41+ teams would overflow the queue and
  // turn a healthy request into a 503, and would starve concurrent logins.
  const granted = await mapBounded(teamIds, API_KEY_GRANT_CONCURRENCY, async (teamId) => {
    const team = await deadlineGatedStackCall(() => app.getTeam(teamId), signal, "get_team");
    if (!team) return null;
    const allowed = await deadlineGatedStackCall(
      () => stackUser.hasPermission(team, "$manage_api_keys"),
      signal,
      "has_permission",
    );
    return allowed ? teamId : null;
  });
  return new Set(granted.filter((teamId): teamId is string => teamId !== null));
}

const API_KEY_GRANT_CONCURRENCY = 4;

/** `work` over `items` with at most `limit` in flight, in input order. The
 * first rejection stops workers from starting more items. */
async function mapBounded<Item, Result>(
  items: readonly Item[],
  limit: number,
  work: (item: Item) => Promise<Result>,
): Promise<Result[]> {
  const results: Result[] = new Array(items.length);
  let next = 0;
  let failed = false;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (!failed && next < items.length) {
      const index = next++;
      try {
        results[index] = await work(items[index]!);
      } catch (error) {
        failed = true;
        throw error;
      }
    }
  });
  await Promise.all(workers);
  return results;
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
