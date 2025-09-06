import { describe, expect, test, vi, beforeEach } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { api, internal } from "./_generated/api";

const UUID1 = "123e4567-e89b-12d3-a456-426614174000";
const UUID2 = "123e4567-e89b-12d3-a456-426614174001";

describe("teams queries and mutations", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("setSlug: normalize, validate and enforce uniqueness", async () => {
    const t = convexTest(schema, modules);

    // Seed memberships so slug operations via slug path are allowed
    await t.run(async (ctx) => {
      const now = Date.now();
      // Two teams without records yet
      await ctx.db.insert("teamMemberships", {
        teamId: UUID1,
        userId: "user-1",
        createdAt: now,
        updatedAt: now,
      });
      await ctx.db.insert("teamMemberships", {
        teamId: UUID2,
        userId: "user-1",
        createdAt: now,
        updatedAt: now,
      });
    });

    const asUser1 = t.withIdentity({ subject: "user-1" });

    // Normalize (trim + lowercase), create team row if missing
    await asUser1.mutation(api.teams.setSlug, {
      teamSlugOrId: UUID1,
      slug: " My-Team ",
    });

    // Using slug path should resolve and allow update
    await asUser1.mutation(api.teams.setSlug, {
      teamSlugOrId: "my-team",
      slug: "my-team-v2",
    });

    // Uniqueness: conflicting slug on another team should throw
    await expect(
      asUser1.mutation(api.teams.setSlug, {
        teamSlugOrId: UUID2,
        slug: "my-team-v2",
      }),
    ).rejects.toThrowError("Slug is already taken");

    // Invalid slug characters should throw
    await expect(
      asUser1.mutation(api.teams.setSlug, {
        teamSlugOrId: UUID1,
        slug: "has space",
      }),
    ).rejects.toThrowError(
      "Slug can contain lowercase letters, numbers, and hyphens, and must start/end with a letter or number",
    );

    // Verify DB state
    const teams = await t.run(async (ctx) => {
      return await ctx.db.query("teams").collect();
    });
    expect(teams.length).toBe(1); // only team 1 created via setSlug
    expect(teams[0]).toMatchObject({ teamId: UUID1, slug: "my-team-v2" });
  });

  test("setName: trims, validates length and upserts", async () => {
    const t = convexTest(schema, modules);
    const asUser1 = t.withIdentity({ subject: "user-1" });

    // Ensure membership so operations are permitted
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teamMemberships", {
        teamId: UUID1,
        userId: "user-1",
        createdAt: now,
        updatedAt: now,
      });
    });

    // Upsert path with no existing team row
    await asUser1.mutation(api.teams.setName, {
      teamSlugOrId: UUID1,
      name: "  My Team  ",
    });

    // Update existing row
    vi.setSystemTime(new Date("2024-01-02T00:00:00Z"));
    await asUser1.mutation(api.teams.setName, {
      teamSlugOrId: UUID1,
      name: "My Team 2",
    });

    // Invalid length
    await expect(
      asUser1.mutation(api.teams.setName, {
        teamSlugOrId: UUID1,
        name: "x".repeat(33),
      }),
    ).rejects.toThrowError("Name must be 1–32 characters long");

    const team = await t.run(async (ctx) => {
      return await ctx.db.query("teams").withIndex("by_teamId", (q) => q.eq("teamId", UUID1)).first();
    });
    expect(team).toMatchObject({ name: "My Team 2" });
  });

  test("get: membership required for both slug and id", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teams", {
        teamId: UUID1,
        slug: "alpha",
        createdAt: now,
        updatedAt: now,
      });
      // Only user-1 is a member
      await ctx.db.insert("teamMemberships", {
        teamId: UUID1,
        userId: "user-1",
        createdAt: now,
        updatedAt: now,
      });
    });

    const asUser1 = t.withIdentity({ subject: "user-1" });
    const asUser2 = t.withIdentity({ subject: "user-2" });

    // Member can get by slug
    const got = await asUser1.query(api.teams.get, { teamSlugOrId: "alpha" });
    expect(got).toMatchObject({ uuid: UUID1, slug: "alpha" });

    // Non-member denied when using slug
    await expect(
      asUser2.query(api.teams.get, { teamSlugOrId: "alpha" }),
    ).rejects.toThrowError("Forbidden: Not a member of this team");

    // Non-member also denied when using teamId now
    await expect(
      asUser2.query(api.teams.get, { teamSlugOrId: UUID1 }),
    ).rejects.toThrowError("Forbidden: Not a member of this team");
  });

  test("auth wrappers: queries and mutations require authentication", async () => {
    const t = convexTest(schema, modules);
    // No identity set
    await expect(
      t.query(api.teams.get, { teamSlugOrId: UUID1 }),
    ).rejects.toThrowError("Not authenticated!");

    await expect(
      t.mutation(api.teams.setName, { teamSlugOrId: UUID1, name: "X" }),
    ).rejects.toThrowError("Not authenticated!");
  });

  test("listTeamMemberships returns memberships with team embedded", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();
    await t.run(async (ctx) => {
      await ctx.db.insert("teams", { teamId: UUID1, slug: "alpha", createdAt: now, updatedAt: now });
      await ctx.db.insert("teams", { teamId: UUID2, slug: "beta", createdAt: now, updatedAt: now });
      await ctx.db.insert("teamMemberships", { teamId: UUID1, userId: "user-1", createdAt: now, updatedAt: now });
      await ctx.db.insert("teamMemberships", { teamId: UUID2, userId: "user-1", createdAt: now, updatedAt: now });
      await ctx.db.insert("teamMemberships", { teamId: UUID2, userId: "user-2", createdAt: now, updatedAt: now });
    });

    const asUser1 = t.withIdentity({ subject: "user-1" });
    const list = await asUser1.query(api.teams.listTeamMemberships, {});
    expect(list.length).toBe(2);
    expect(list[0].team.teamId === UUID1 || list[0].team.teamId === UUID2).toBe(true);
    expect(list[1].team.teamId === UUID1 || list[1].team.teamId === UUID2).toBe(true);
    const ids = list.map((m) => m.team.teamId).sort();
    expect(ids).toEqual([UUID1, UUID2].sort());
  });

  test("getByTeamIdInternal returns uuid and slug or null", async () => {
    const t = convexTest(schema, modules);
    await t.run(async (ctx) => {
      const now = Date.now();
      await ctx.db.insert("teams", { teamId: UUID1, slug: "alpha", createdAt: now, updatedAt: now });
    });
    const found = await t.query(internal.teams.getByTeamIdInternal, { teamId: UUID1 });
    expect(found).toEqual({ uuid: UUID1, slug: "alpha" });
    const notFound = await t.query(internal.teams.getByTeamIdInternal, { teamId: UUID2 });
    expect(notFound).toBeNull();
  });
});
