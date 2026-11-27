import { describe, expect, test } from "bun:test";
import { listTeamsForUser, TEAM_LIST_PERMISSION_CONCURRENCY } from "../services/teams/list";
import { listAllUserTeamPages, type StackTeamSummary } from "../services/teams/stack";
import { ADMIN_GRANTS, ADMIN_ID, FakeStack } from "./teams-fixture";

function teamId(index: number): string {
  return `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`;
}

describe("listTeamsForUser", () => {
  test("reads team grants with bounded concurrency and keeps Stack's order", async () => {
    const stack = new FakeStack().addUser({ id: ADMIN_ID });
    for (let index = 1; index <= 10; index++) stack.addTeam(teamId(index), `T${index}`).addMember(teamId(index), ADMIN_ID, ADMIN_GRANTS);
    const app = stack.app();
    let inFlight = 0;
    let peak = 0;
    const listing = await listTeamsForUser(ADMIN_ID, {
      stack: {
        ...app,
        listTeamMemberPermissions: async (id, options) => {
          inFlight += 1;
          peak = Math.max(peak, inFlight);
          await Promise.resolve();
          await Promise.resolve();
          try {
            return await app.listTeamMemberPermissions(id, options);
          } finally {
            inFlight -= 1;
          }
        },
      },
    });
    expect(listing.teams.map((team) => team.displayName)).toEqual(Array.from({ length: 10 }, (_, index) => `T${index + 1}`));
    expect(listing.teams.every((team) => team.role === "admin")).toBe(true);
    expect(peak).toBe(TEAM_LIST_PERMISSION_CONCURRENCY);
  });

  test("an unknown user has no teams", async () => {
    expect(await listTeamsForUser(ADMIN_ID, { stack: new FakeStack().app() })).toEqual({ teams: [], selectedTeamId: null });
  });
});

describe("listAllUserTeamPages", () => {
  function page(teams: readonly StackTeamSummary[], nextCursor: string | null) {
    return Object.assign([...teams], { nextCursor });
  }

  test("walks every page", async () => {
    const cursors: (string | undefined)[] = [];
    const teams = await listAllUserTeamPages(async ({ cursor }) => {
      cursors.push(cursor);
      return cursor
        ? page([{ id: teamId(2), displayName: "B", profileImageUrl: null }], null)
        : page([{ id: teamId(1), displayName: "A", profileImageUrl: "https://example.com/a.png" }], "next");
    });
    expect(cursors).toEqual([undefined, "next"]);
    expect(teams.map((team) => team.id)).toEqual([teamId(1), teamId(2)]);
  });

  test("refuses a repeated cursor instead of returning a partial list", async () => {
    await expect(listAllUserTeamPages(async () => page([], "same"))).rejects.toThrow("repeated a cursor");
  });
});
