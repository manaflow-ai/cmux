import { beforeEach, describe, expect, test, vi } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api, internal } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614170009";

describe("github queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("repos and branches CRUD + provider connections", async () => {
    const t = convexTest(schema, modules);
    const userId = "u1";
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", { teamId: TEAM_ID, userId, createdAt: now, updatedAt: now });
      // An unassigned active provider connection
      await ctx.db.insert("providerConnections", {
        type: "github_app",
        installationId: 1001,
        accountLogin: "acme",
        accountType: "Organization",
        isActive: true,
        createdAt: now,
        updatedAt: now,
      });
    });
    const asUser = t.withIdentity({ subject: userId });

    // Unassigned provider connections
    const unassigned = await asUser.query(api.github.listUnassignedProviderConnections, {});
    expect(unassigned.length).toBe(1);

    // Assign connection to team
    await asUser.mutation(api.github.assignProviderConnectionToTeam, { teamSlugOrId: TEAM_ID, installationId: 1001 });
    const assigned = await asUser.query(api.github.listProviderConnections, { teamSlugOrId: TEAM_ID });
    expect(assigned.length).toBe(1);
    expect(assigned[0].installationId).toBe(1001);

    // Upsert repo (insert)
    await asUser.mutation(api.github.upsertRepo, { teamSlugOrId: TEAM_ID, fullName: "acme/app", org: "acme", name: "app", gitRemote: "git@github.com:acme/app.git" });
    // Upsert repo (update)
    await asUser.mutation(api.github.upsertRepo, { teamSlugOrId: TEAM_ID, fullName: "acme/app", org: "acme", name: "app", gitRemote: "git@github.com:acme/app.git", provider: "github" });
    const all = await asUser.query(api.github.getAllRepos, { teamSlugOrId: TEAM_ID });
    expect(all.length).toBe(1);

    // Group by org
    const byOrg = await asUser.query(api.github.getReposByOrg, { teamSlugOrId: TEAM_ID });
    expect(Object.keys(byOrg)).toContain("acme");

    // Bulk insert repos (dedupe existing)
    const insertedIds = await asUser.mutation(api.github.bulkInsertRepos, {
      teamSlugOrId: TEAM_ID,
      repos: [
        { fullName: "acme/app", org: "acme", name: "app", gitRemote: "git@github.com:acme/app.git" },
        { fullName: "acme/web", org: "acme", name: "web", gitRemote: "git@github.com:acme/web.git" },
      ],
    });
    expect(insertedIds.length).toBe(1);

    // Replace all repos
    const replaced = await asUser.mutation(api.github.replaceAllRepos, {
      teamSlugOrId: TEAM_ID,
      repos: [
        { fullName: "acme/api", org: "acme", name: "api", gitRemote: "git@github.com:acme/api.git" },
      ],
    });
    expect(replaced.length).toBe(1);

    // Branches
    await t.mutation(internal.github.insertBranch, { repo: "acme/api", name: "main", userId, teamSlugOrId: TEAM_ID });
    await asUser.mutation(api.github.bulkInsertBranches, { teamSlugOrId: TEAM_ID, repo: "acme/api", branches: ["main", "dev"] });
    const branches = await asUser.query(api.github.getBranches, { teamSlugOrId: TEAM_ID, repo: "acme/api" });
    expect(branches.sort()).toEqual(["dev", "main"]);
    const branchesFull = await asUser.query(api.github.getBranchesByRepo, { teamSlugOrId: TEAM_ID, repo: "acme/api" });
    expect(branchesFull.length).toBe(2);

    // Remove provider connection
    await asUser.mutation(api.github.removeProviderConnection, { teamSlugOrId: TEAM_ID, installationId: 1001 });
    const assignedAfter = await asUser.query(api.github.listProviderConnections, { teamSlugOrId: TEAM_ID });
    // After removal, the connection is detached from the team, so none should be listed
    expect(assignedAfter.length).toBe(0);

    // Internal repo/branch deletes
    // map to ids
    const repoRows = await t.run(async (ctx) => ctx.db.query("repos").collect());
    const branchRows = await t.run(async (ctx) => ctx.db.query("branches").collect());
    for (const b of branchRows) await t.mutation(internal.github.deleteBranch, { id: b._id });
    for (const r of repoRows) await t.mutation(internal.github.deleteRepo, { id: r._id });
    const emptyRepos = await asUser.query(api.github.getAllRepos, { teamSlugOrId: TEAM_ID });
    expect(emptyRepos.length).toBe(0);
  });
});
