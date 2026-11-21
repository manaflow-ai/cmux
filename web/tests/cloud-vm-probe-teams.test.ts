import { describe, expect, test } from "bun:test";

import { deleteProbeUser, isProbeTeamName, listOrphanProbeTeams } from "../scripts/cloud-vm/probeTeams.mjs";

type FakeTeam = { id: string; displayName: string; members: string[]; deleted: boolean };

function directory(teams: FakeTeam[]) {
  const live = () => teams.filter((team) => !team.deleted);
  const view = (team: FakeTeam) => ({
    id: team.id,
    displayName: team.displayName,
    listUsers: async () => team.members.map((id) => ({ id })),
    delete: async () => { team.deleted = true; },
  });
  return {
    async getTeam(id: string) {
      const team = live().find((candidate) => candidate.id === id);
      return team ? view(team) : null;
    },
    async listTeams(options: { query?: string; limit?: number; cursor?: string }) {
      const matching = live().filter((team) => team.displayName.toLowerCase().includes((options.query ?? "").toLowerCase()));
      const start = options.cursor ? Number(options.cursor) : 0;
      const end = start + (options.limit ?? 100);
      return Object.assign(matching.slice(start, end).map(view), { nextCursor: end < matching.length ? String(end) : null });
    },
  };
}

describe("probe teams", () => {
  test("deleting a probe account deletes its personal team and keeps a team someone else is in", async () => {
    const personal: FakeTeam = { id: "personal", displayName: "cmux prod smoke's Team", members: ["probe"], deleted: false };
    const shared: FakeTeam = { id: "shared", displayName: "Acme", members: ["probe", "pat"], deleted: false };
    const app = directory([personal, shared]);
    const user = {
      listTeams: async () => [{ id: "personal" }, { id: "shared" }],
      delete: async () => {
        personal.members = [];
        shared.members = ["pat"];
      },
    };
    expect(await deleteProbeUser(app, user)).toEqual({ teamsDeleted: 1, teamsKept: ["shared"] });
    expect(personal.deleted).toBe(true);
    expect(shared.deleted).toBe(false);
  });

  test("a failed account delete throws and deletes no team", async () => {
    const personal: FakeTeam = { id: "personal", displayName: "cmux prod smoke's Team", members: ["probe"], deleted: false };
    const user = { listTeams: async () => [{ id: "personal" }], delete: async () => { throw new Error("provider down"); } };
    await expect(deleteProbeUser(directory([personal]), user)).rejects.toThrow("provider down");
    expect(personal.deleted).toBe(false);
  });

  test("the orphan sweep lists only empty teams with a probe account's exact name", async () => {
    const teams: FakeTeam[] = [
      { id: "old-smoke", displayName: "cmux prod smoke's Team", members: [], deleted: false },
      { id: "old-stress", displayName: "cmux prod stress 3's Team", members: [], deleted: false },
      { id: "running-smoke", displayName: "cmux prod smoke's Team", members: ["probe"], deleted: false },
      { id: "company", displayName: "cmux", members: [], deleted: false },
      { id: "lookalike", displayName: "my cmux prod smoke's Team", members: [], deleted: false },
    ];
    const { orphans, scanned, complete } = await listOrphanProbeTeams(directory(teams), { pageSize: 2 });
    expect(orphans.map((team: { id: string }) => team.id)).toEqual(["old-smoke", "old-stress"]);
    expect(scanned).toBe(5);
    expect(complete).toBe(true);
  });

  test("probe names match exactly, never a person's look-alike team", () => {
    for (const name of ["cmux prod smoke's Team", "cmux staging stress 12's Team", "cmux dogfood's Team", "cmux Iroh production gate's Team"]) {
      expect(isProbeTeamName(name)).toBe(true);
    }
    for (const name of ["cmux", "cmux Team", "my cmux prod smoke's Team", "cmux prod smoke"]) expect(isProbeTeamName(name)).toBe(false);
  });
});
