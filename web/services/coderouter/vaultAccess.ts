/**
 * Resolve whether a request may read the team's hosted Subrouter vault.
 *
 * The vault verifies the end user's Stack session itself, so a route token
 * cannot reach it. A CLI request authenticates with its route token in
 * `authorization` and may carry its Stack session in `x-stack-access-token`
 * plus `x-stack-refresh-token`. When that session is absent or no longer
 * valid, the vault is simply a source this caller cannot read: the rest of the
 * account list still answers.
 */
import { resolveTeam } from "../subrouter/routeHelpers";
import {
  isSubrouterAuthorizationError,
  verifySubrouterRequest,
  withSubrouterAuthorizationDeadline,
} from "../vms/auth";
import type { VaultAccess } from "./teamAccounts";

export async function vaultAccessFromStackHeaders(
  request: Request,
  teamId: string,
): Promise<VaultAccess> {
  const accessToken = request.headers.get("x-stack-access-token")?.trim();
  const refreshToken = request.headers.get("x-stack-refresh-token")?.trim();
  if (!accessToken || !refreshToken) return { kind: "none" };

  // verifySubrouterRequest reads a native Stack session from `authorization`,
  // which this request already spent on the route token. Hand it a request
  // carrying only the Stack session so one vetted code path decides identity.
  const stackRequest = new Request(request.url, {
    headers: {
      authorization: `Bearer ${accessToken}`,
      "x-stack-refresh-token": refreshToken,
      "x-cmux-team-id": teamId,
    },
  });

  try {
    return await withSubrouterAuthorizationDeadline(async (signal) => {
      const user = await verifySubrouterRequest(stackRequest, signal, {
        requestedTeamId: teamId,
        allowCookie: false,
      });
      if (!user) return { kind: "none" };
      const team = resolveTeam(stackRequest, user);
      if (!team.ok || team.teamId !== teamId) return { kind: "none" };
      return {
        kind: "session",
        accessToken,
        team: {
          teamId: team.teamId,
          teamName: team.teamName,
          use: team.use,
          manageAccounts: team.manageAccounts,
        },
      };
    });
  } catch (error) {
    if (!isSubrouterAuthorizationError(error)) throw error;
    return { kind: "none" };
  }
}
