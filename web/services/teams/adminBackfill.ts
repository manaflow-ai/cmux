import type { HexclaveSource } from "../auth/hexclave/serverApi";
import { TEAM_ADMIN_PERMISSION } from "./permissions";

/**
 * Find teams that no member administers (the iOS Worker created teams without
 * granting the creator `team_admin` until this was fixed) and propose an admin
 * only where the answer is unambiguous: a team with exactly one member gets
 * that member. Every other orphan needs a person to choose.
 */
export type TeamAdminBackfillSource = Pick<HexclaveSource, "listTeamsPage" | "listTeamMembersPage" | "listAllTeamPermissions">;

export type OrphanTeam =
  | { readonly teamId: string; readonly memberCount: 1; readonly action: "grant"; readonly proposedAdminUserId: string }
  | { readonly teamId: string; readonly memberCount: 0 | 1 | "2+"; readonly action: "needs_human"; readonly proposedAdminUserId: null };

export type TeamAdminBackfillReport = {
  readonly teamsScanned: number;
  readonly orphans: readonly OrphanTeam[];
};

export type TeamAdminBackfillOptions = {
  readonly source: TeamAdminBackfillSource;
  readonly concurrency: number;
  readonly pageSize: number;
  readonly log?: (message: string) => void;
};

const MAX_TEAM_PAGES = 10_000;

export async function findTeamsWithoutAdmin(options: TeamAdminBackfillOptions): Promise<TeamAdminBackfillReport> {
  const { source, concurrency, pageSize } = options;
  const log = options.log ?? (() => {});
  const teamIds = await listAllTeamIds(source, pageSize);
  log(`teams: ${teamIds.length}`);
  const administered = new Set(
    (await source.listAllTeamPermissions())
      .filter((permission) => permission.id === TEAM_ADMIN_PERMISSION)
      .map((permission) => permission.team_id),
  );
  const orphanIds = teamIds.filter((teamId) => !administered.has(teamId));
  log(`teams without an admin: ${orphanIds.length}`);
  const orphans = await mapBounded(orphanIds, concurrency, (teamId) => classifyOrphan(source, teamId));
  return { teamsScanned: teamIds.length, orphans };
}

/** Two members are enough to know a team is ambiguous; never read more. */
export async function classifyOrphan(source: Pick<TeamAdminBackfillSource, "listTeamMembersPage">, teamId: string): Promise<OrphanTeam> {
  const page = await source.listTeamMembersPage(teamId, null, 2);
  const [only] = page.items;
  // An anonymous sole member is not someone to hand a team to.
  if (page.items.length === 1 && !page.nextCursor && only && !only.is_anonymous) {
    return { teamId, memberCount: 1, action: "grant", proposedAdminUserId: only.id };
  }
  return { teamId, memberCount: page.items.length === 0 ? 0 : page.items.length === 1 && !page.nextCursor ? 1 : "2+", action: "needs_human", proposedAdminUserId: null };
}

export type TeamAdminGrantOutcome = { readonly teamId: string; readonly userId: string; readonly result: "granted" | "skipped_changed" | "failed" };

/**
 * Grant each proposal after re-reading the team: a team whose sole member
 * changed since the scan is skipped. One grant at a time; a failure is
 * recorded and the rest continue.
 */
export async function applyTeamAdminProposals(
  orphans: readonly OrphanTeam[],
  dependencies: {
    readonly source: Pick<TeamAdminBackfillSource, "listTeamMembersPage">;
    readonly grant: (userId: string, teamId: string) => Promise<void>;
  },
): Promise<TeamAdminGrantOutcome[]> {
  const outcomes: TeamAdminGrantOutcome[] = [];
  for (const orphan of orphans) {
    if (orphan.action !== "grant") continue;
    const { teamId, proposedAdminUserId: userId } = orphan;
    try {
      const current = await classifyOrphan(dependencies.source, teamId);
      if (current.action !== "grant" || current.proposedAdminUserId !== userId) {
        outcomes.push({ teamId, userId, result: "skipped_changed" });
        continue;
      }
      await dependencies.grant(userId, teamId);
      outcomes.push({ teamId, userId, result: "granted" });
    } catch {
      outcomes.push({ teamId, userId, result: "failed" });
    }
  }
  return outcomes;
}

async function listAllTeamIds(source: Pick<TeamAdminBackfillSource, "listTeamsPage">, pageSize: number): Promise<string[]> {
  const ids: string[] = [];
  const seen = new Set<string>();
  let cursor: string | null = null;
  for (let page = 0; page < MAX_TEAM_PAGES; page++) {
    const result = await source.listTeamsPage(cursor, pageSize);
    for (const team of result.items) ids.push(team.id);
    if (!result.nextCursor) return [...new Set(ids)];
    if (seen.has(result.nextCursor)) throw new Error("team pagination repeated a cursor");
    seen.add(result.nextCursor);
    cursor = result.nextCursor;
  }
  throw new Error("team pagination exceeded its page limit");
}

async function mapBounded<Item, Result>(items: readonly Item[], limit: number, work: (item: Item) => Promise<Result>): Promise<Result[]> {
  const results: Result[] = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await work(items[index]!);
    }
  }));
  return results;
}
