import { TeamGoneError } from "./errors";
import { grantsByUser, roleFromGrants, viewerPermissionsFromGrants } from "./permissions";
import { defaultTeamStackApp, withStackDeadline, type StackTeamSummary, type TeamStackApp } from "./stack";
import type { TeamListing, TeamListResponse } from "./types";

/** Stack permission reads in flight at once for one listing. */
export const TEAM_LIST_PERMISSION_CONCURRENCY = 4;

export type ListTeamsDependencies = { readonly stack?: TeamStackApp };

/**
 * The signed-in user's teams with their role and capabilities in each. The
 * membership list is read fresh from Stack (one paged read), then each team's
 * grants are read the same way `requireTeamAccess` reads them, at most
 * `TEAM_LIST_PERMISSION_CONCURRENCY` at a time. A team deleted while this runs
 * is left out; any other Stack failure fails the whole listing as a retryable
 * 503, so a role is never guessed.
 */
export async function listTeamsForUser(
  userId: string,
  dependencies: ListTeamsDependencies = {},
): Promise<TeamListResponse> {
  const stack = dependencies.stack ?? defaultTeamStackApp();
  const listed = await withStackDeadline(() => stack.listUserTeams(userId));
  if (!listed) return { teams: [], selectedTeamId: null };
  const unique = uniqueTeams(listed.teams);
  const rows = await mapWithConcurrency(unique, TEAM_LIST_PERMISSION_CONCURRENCY, (team) =>
    teamListing(stack, userId, team));
  const teams = rows.filter((row): row is TeamListing => row !== null);
  const selectedTeamId = teams.some((team) => team.id === listed.selectedTeamId) ? listed.selectedTeamId : null;
  return { teams, selectedTeamId };
}

async function teamListing(stack: TeamStackApp, userId: string, team: StackTeamSummary): Promise<TeamListing | null> {
  let rows: readonly { readonly userId: string; readonly permissionId: string }[];
  try {
    rows = await withStackDeadline(() => stack.listTeamMemberPermissions(team.id, { recursive: true }));
  } catch (error) {
    if (error instanceof TeamGoneError) return null;
    throw error;
  }
  const grants = grantsByUser(rows).get(userId) ?? new Set<string>();
  return {
    id: team.id,
    displayName: team.displayName,
    profileImageUrl: team.profileImageUrl ?? null,
    role: roleFromGrants(grants),
    permissions: viewerPermissionsFromGrants(grants),
  };
}

function uniqueTeams(teams: readonly StackTeamSummary[]): StackTeamSummary[] {
  const seen = new Set<string>();
  return teams.filter((team) => {
    if (seen.has(team.id)) return false;
    seen.add(team.id);
    return true;
  });
}

/** Run `work` over `items` with at most `limit` in flight, in order; the first failure stops new work. */
async function mapWithConcurrency<Item, Result>(
  items: readonly Item[],
  limit: number,
  work: (item: Item) => Promise<Result>,
): Promise<Result[]> {
  const results: Result[] = new Array(items.length);
  let next = 0;
  let failed = false;
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
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
