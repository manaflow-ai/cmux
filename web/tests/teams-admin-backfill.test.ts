import { describe, expect, test } from "bun:test";
import type { HexclaveServerTeam, HexclaveServerUser, HexclaveTeamPermission } from "../services/auth/hexclave/serverApi";
import { applyTeamAdminProposals, findTeamsWithoutAdmin, type TeamAdminBackfillSource } from "../services/teams/adminBackfill";

const ADMINED = "11111111-1111-4111-8111-111111111111";
const SOLO = "22222222-2222-4222-8222-222222222222";
const CROWDED = "33333333-3333-4333-8333-333333333333";
const EMPTY = "44444444-4444-4444-8444-444444444444";

const ANON = "55555555-5555-4555-8555-555555555555";

function fakeSource(members: Record<string, string[]>, admins: Record<string, string>, anonymous: ReadonlySet<string> = new Set()) {
  const memberReads: { teamId: string; limit: number }[] = [];
  const source: TeamAdminBackfillSource = {
    listTeamsPage: async (cursor) => {
      const ids = Object.keys(members);
      const half = Math.ceil(ids.length / 2);
      const slice = cursor ? ids.slice(half) : ids.slice(0, half);
      return { items: slice.map((id) => ({ id }) as HexclaveServerTeam), nextCursor: cursor ? null : "page-2" };
    },
    listTeamMembersPage: async (teamId, _cursor, limit) => {
      memberReads.push({ teamId, limit });
      const all = members[teamId] ?? [];
      return { items: all.slice(0, limit).map((id) => ({ id, is_anonymous: anonymous.has(id) }) as HexclaveServerUser), nextCursor: all.length > limit ? "more" : null };
    },
    listAllTeamPermissions: async () =>
      Object.entries(admins).map(([teamId, userId]) => ({ id: "team_admin", team_id: teamId, user_id: userId }) as HexclaveTeamPermission),
  };
  return { source, memberReads };
}

describe("team admin backfill", () => {
  test("proposes the sole member of an orphan team and leaves every other orphan to a person", async () => {
    const { source, memberReads } = fakeSource(
      { [ADMINED]: ["u-admin", "u-2"], [SOLO]: ["u-solo"], [CROWDED]: ["u-a", "u-b", "u-c"], [EMPTY]: [] },
      { [ADMINED]: "u-admin" },
    );
    const report = await findTeamsWithoutAdmin({ source, concurrency: 2, pageSize: 2 });
    expect(report.teamsScanned).toBe(4);
    expect(report.orphans).toEqual([
      { teamId: SOLO, memberCount: 1, action: "grant", proposedAdminUserId: "u-solo" },
      { teamId: CROWDED, memberCount: "2+", action: "needs_human", proposedAdminUserId: null },
      { teamId: EMPTY, memberCount: 0, action: "needs_human", proposedAdminUserId: null },
    ]);
    // Administered teams are never read; orphans read at most two members.
    expect(memberReads.some((read) => read.teamId === ADMINED)).toBe(false);
    expect(memberReads.every((read) => read.limit === 2)).toBe(true);
  });

  test("an anonymous sole member is never proposed as admin", async () => {
    const { source } = fakeSource({ [ANON]: ["u-anon"] }, {}, new Set(["u-anon"]));
    const report = await findTeamsWithoutAdmin({ source, concurrency: 1, pageSize: 10 });
    expect(report.orphans).toEqual([{ teamId: ANON, memberCount: 1, action: "needs_human", proposedAdminUserId: null }]);
  });

  test("apply grants proposals, skips a team whose sole member changed, and records failures", async () => {
    const membership: Record<string, string[]> = { [SOLO]: ["u-solo"], [CROWDED]: ["u-x"], [EMPTY]: ["u-fail"] };
    const { source } = fakeSource(membership, {});
    const report = await findTeamsWithoutAdmin({ source, concurrency: 4, pageSize: 200 });
    membership[CROWDED] = ["u-x", "u-y"];
    const granted: string[] = [];
    const outcomes = await applyTeamAdminProposals(report.orphans, {
      source,
      grant: async (userId, teamId) => {
        if (userId === "u-fail") throw new Error("grant failed");
        granted.push(`${teamId}:${userId}`);
      },
    });
    expect(granted).toEqual([`${SOLO}:u-solo`]);
    expect(outcomes).toEqual([
      { teamId: SOLO, userId: "u-solo", result: "granted" },
      { teamId: CROWDED, userId: "u-x", result: "skipped_changed" },
      { teamId: EMPTY, userId: "u-fail", result: "failed" },
    ]);
  });
});
