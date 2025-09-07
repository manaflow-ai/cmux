import { describe, expect, test, vi, beforeEach } from "vitest";
import { convexTest } from "convex-test";
import schema from "./schema";
import { modules } from "./test.setup";
import { internal } from "./_generated/api";

const TEAM_ID = "123e4567-e89b-12d3-a456-426614174100";
const USER_ID = "user-1";

describe("memberships and permissions", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2024-01-01T00:00:00Z"));
  });

  test("ensureMembership is idempotent and updates timestamp; deleteMembership removes", async () => {
    const t = convexTest(schema, modules);

    // First ensure inserts
    await t.mutation(internal.stack.ensureMembership, { teamId: TEAM_ID, userId: USER_ID });
    let membership = await t.run(async (ctx) => {
      return await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) => q.eq("teamId", TEAM_ID).eq("userId", USER_ID))
        .first();
    });
    expect(membership).not.toBeNull();
    const firstUpdated = membership!.updatedAt;

    // Second ensure only patches updatedAt
    vi.setSystemTime(new Date("2024-01-02T00:00:00Z"));
    await t.mutation(internal.stack.ensureMembership, { teamId: TEAM_ID, userId: USER_ID });
    membership = await t.run(async (ctx) => {
      return await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) => q.eq("teamId", TEAM_ID).eq("userId", USER_ID))
        .first();
    });
    expect(membership!.updatedAt).toBeGreaterThan(firstUpdated);

    // Delete removes the row
    await t.mutation(internal.stack.deleteMembership, { teamId: TEAM_ID, userId: USER_ID });
    const afterDelete = await t.run(async (ctx) => {
      return await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) => q.eq("teamId", TEAM_ID).eq("userId", USER_ID))
        .first();
    });
    expect(afterDelete).toBeNull();
  });

  test("ensurePermission is idempotent per (team,user,perm); deletePermission removes", async () => {
    const t = convexTest(schema, modules);
    const perm = "$update_team";

    await t.mutation(internal.stack.ensurePermission, { teamId: TEAM_ID, userId: USER_ID, permissionId: perm });
    let row = await t.run(async (ctx) => {
      return await ctx.db
        .query("teamPermissions")
        .withIndex("by_team_user_perm", (q) =>
          q.eq("teamId", TEAM_ID).eq("userId", USER_ID).eq("permissionId", perm),
        )
        .first();
    });
    expect(row).not.toBeNull();
    const firstUpdated = row!.updatedAt;

    vi.setSystemTime(new Date("2024-01-02T00:00:00Z"));
    await t.mutation(internal.stack.ensurePermission, { teamId: TEAM_ID, userId: USER_ID, permissionId: perm });
    row = await t.run(async (ctx) => {
      return await ctx.db
        .query("teamPermissions")
        .withIndex("by_team_user_perm", (q) =>
          q.eq("teamId", TEAM_ID).eq("userId", USER_ID).eq("permissionId", perm),
        )
        .first();
    });
    expect(row!.updatedAt).toBeGreaterThan(firstUpdated);

    await t.mutation(internal.stack.deletePermission, { teamId: TEAM_ID, userId: USER_ID, permissionId: perm });
    const afterDelete = await t.run(async (ctx) => {
      return await ctx.db
        .query("teamPermissions")
        .withIndex("by_team_user_perm", (q) =>
          q.eq("teamId", TEAM_ID).eq("userId", USER_ID).eq("permissionId", perm),
        )
        .first();
    });
    expect(afterDelete).toBeNull();
  });

  test("upsertUser creates and updates; deleteUser cleans memberships and permissions", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    // Upsert create
    await t.mutation(internal.stack.upsertUser, {
      id: USER_ID,
      primaryEmail: "u1@example.com",
      primaryEmailVerified: true,
      primaryEmailAuthEnabled: true,
      displayName: "U1",
      selectedTeamId: TEAM_ID,
      selectedTeamDisplayName: "Team",
      selectedTeamProfileImageUrl: undefined,
      profileImageUrl: undefined,
      signedUpAtMillis: now - 1000,
      lastActiveAtMillis: now,
      hasPassword: true,
      otpAuthEnabled: false,
      passkeyAuthEnabled: false,
      isAnonymous: false,
    });

    // Prepare related rows
    await t.mutation(internal.stack.ensureMembership, { teamId: TEAM_ID, userId: USER_ID });
    await t.mutation(internal.stack.ensurePermission, {
      teamId: TEAM_ID,
      userId: USER_ID,
      permissionId: "team_member",
    });

    // Upsert update
    vi.setSystemTime(new Date("2024-01-02T00:00:00Z"));
    await t.mutation(internal.stack.upsertUser, {
      id: USER_ID,
      primaryEmail: "u1+new@example.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: false,
      displayName: "U1 New",
      selectedTeamId: TEAM_ID,
      selectedTeamDisplayName: "Team New",
      selectedTeamProfileImageUrl: "http://img",
      profileImageUrl: "http://p",
      signedUpAtMillis: now - 500,
      lastActiveAtMillis: now + 100,
      hasPassword: false,
      otpAuthEnabled: true,
      passkeyAuthEnabled: true,
      isAnonymous: false,
    });

    const user = await t.run(async (ctx) => {
      return await ctx.db
        .query("users")
        .withIndex("by_userId", (q) => q.eq("userId", USER_ID))
        .first();
    });
    expect(user).toMatchObject({
      userId: USER_ID,
      primaryEmail: "u1+new@example.com",
      primaryEmailVerified: false,
      primaryEmailAuthEnabled: false,
      displayName: "U1 New",
      selectedTeamId: TEAM_ID,
      selectedTeamDisplayName: "Team New",
      selectedTeamProfileImageUrl: "http://img",
      profileImageUrl: "http://p",
    });

    // Delete user cleans up user row and related membership/permissions
    await t.mutation(internal.stack.deleteUser, { id: USER_ID });
    const [u2, m2, p2] = await t.run(async (ctx) => {
      const user = await ctx.db
        .query("users")
        .withIndex("by_userId", (q) => q.eq("userId", USER_ID))
        .first();
      const membership = await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) => q.eq("teamId", TEAM_ID).eq("userId", USER_ID))
        .first();
      const perm = await ctx.db
        .query("teamPermissions")
        .withIndex("by_team_user", (q) => q.eq("teamId", TEAM_ID).eq("userId", USER_ID))
        .first();
      return [user, membership, perm] as const;
    });
    expect(u2).toBeNull();
    expect(m2).toBeNull();
    expect(p2).toBeNull();
  });

  test("upsertTeam creates and updates; deleteTeam cleans memberships and permissions for the team", async () => {
    const t = convexTest(schema, modules);
    const now = Date.now();

    // Create team by upsert
    await t.mutation(internal.stack.upsertTeam, {
      id: TEAM_ID,
      displayName: "Alpha",
      profileImageUrl: "http://img/a.png",
      clientMetadata: { a: 1 },
      clientReadOnlyMetadata: { b: 2 },
      serverMetadata: { c: 3 },
      createdAtMillis: now - 1000,
    });

    // Add related entries to be cleaned by deleteTeam
    await t.mutation(internal.stack.ensureMembership, { teamId: TEAM_ID, userId: USER_ID });
    await t.mutation(internal.stack.ensurePermission, {
      teamId: TEAM_ID,
      userId: USER_ID,
      permissionId: "team_member",
    });

    // Update via upsert
    vi.setSystemTime(new Date("2024-01-03T00:00:00Z"));
    await t.mutation(internal.stack.upsertTeam, {
      id: TEAM_ID,
      displayName: "Alpha 2",
      profileImageUrl: "http://img/b.png",
      clientMetadata: { a: 2 },
      clientReadOnlyMetadata: { b: 3 },
      serverMetadata: { c: 4 },
      createdAtMillis: now - 500,
    });

    const team = await t.run(async (ctx) => {
      return await ctx.db
        .query("teams")
        .withIndex("by_teamId", (q) => q.eq("teamId", TEAM_ID))
        .first();
    });
    expect(team).toMatchObject({
      teamId: TEAM_ID,
      displayName: "Alpha 2",
      profileImageUrl: "http://img/b.png",
      clientMetadata: { a: 2 },
      clientReadOnlyMetadata: { b: 3 },
      serverMetadata: { c: 4 },
    });

    // Delete team removes team and related rows
    await t.mutation(internal.stack.deleteTeam, { id: TEAM_ID });
    const [t2, m2, p2] = await t.run(async (ctx) => {
      const team = await ctx.db
        .query("teams")
        .withIndex("by_teamId", (q) => q.eq("teamId", TEAM_ID))
        .first();
      const membership = await ctx.db
        .query("teamMemberships")
        .withIndex("by_team", (q) => q.eq("teamId", TEAM_ID))
        .first();
      const perm = await ctx.db
        .query("teamPermissions")
        .withIndex("by_team", (q) => q.eq("teamId", TEAM_ID))
        .first();
      return [team, membership, perm] as const;
    });
    expect(t2).toBeNull();
    expect(m2).toBeNull();
    expect(p2).toBeNull();

    // Deleting again is a no-op
    await t.mutation(internal.stack.deleteTeam, { id: TEAM_ID });
  });
});
