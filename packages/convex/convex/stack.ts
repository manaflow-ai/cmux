import { v } from "convex/values";
import { internalMutation, type MutationCtx } from "./_generated/server";
import { authMutation } from "./users/utils";

type UpsertUserArgs = {
  id: string;
  primaryEmail?: string;
  primaryEmailVerified: boolean;
  primaryEmailAuthEnabled: boolean;
  displayName?: string;
  selectedTeamId?: string;
  selectedTeamDisplayName?: string;
  selectedTeamProfileImageUrl?: string;
  profileImageUrl?: string;
  signedUpAtMillis: number;
  lastActiveAtMillis: number;
  hasPassword: boolean;
  otpAuthEnabled: boolean;
  passkeyAuthEnabled: boolean;
  clientMetadata?: unknown;
  clientReadOnlyMetadata?: unknown;
  serverMetadata?: unknown;
  isAnonymous: boolean;
  oauthProviders?: Array<{ id: string; accountId: string; email?: string }>;
};

async function upsertUserCore(ctx: MutationCtx, args: UpsertUserArgs) {
  const now = Date.now();
  const existing = await ctx.db
    .query("users")
    .withIndex("by_uuid", (q) => q.eq("uuid", args.id))
    .first();
  if (existing) {
    await ctx.db.patch(existing._id, {
      primaryEmail: args.primaryEmail,
      primaryEmailVerified: args.primaryEmailVerified,
      primaryEmailAuthEnabled: args.primaryEmailAuthEnabled,
      displayName: args.displayName,
      selectedTeamId: args.selectedTeamId,
      selectedTeamDisplayName: args.selectedTeamDisplayName,
      selectedTeamProfileImageUrl: args.selectedTeamProfileImageUrl,
      profileImageUrl: args.profileImageUrl,
      signedUpAtMillis: args.signedUpAtMillis,
      lastActiveAtMillis: args.lastActiveAtMillis,
      hasPassword: args.hasPassword,
      otpAuthEnabled: args.otpAuthEnabled,
      passkeyAuthEnabled: args.passkeyAuthEnabled,
      clientMetadata: args.clientMetadata,
      clientReadOnlyMetadata: args.clientReadOnlyMetadata,
      serverMetadata: args.serverMetadata,
      isAnonymous: args.isAnonymous,
      oauthProviders: args.oauthProviders,
      updatedAt: now,
    });
  } else {
    await ctx.db.insert("users", {
      uuid: args.id,
      primaryEmail: args.primaryEmail,
      primaryEmailVerified: args.primaryEmailVerified,
      primaryEmailAuthEnabled: args.primaryEmailAuthEnabled,
      displayName: args.displayName,
      selectedTeamId: args.selectedTeamId,
      selectedTeamDisplayName: args.selectedTeamDisplayName,
      selectedTeamProfileImageUrl: args.selectedTeamProfileImageUrl,
      profileImageUrl: args.profileImageUrl,
      signedUpAtMillis: args.signedUpAtMillis,
      lastActiveAtMillis: args.lastActiveAtMillis,
      hasPassword: args.hasPassword,
      otpAuthEnabled: args.otpAuthEnabled,
      passkeyAuthEnabled: args.passkeyAuthEnabled,
      clientMetadata: args.clientMetadata,
      clientReadOnlyMetadata: args.clientReadOnlyMetadata,
      serverMetadata: args.serverMetadata,
      isAnonymous: args.isAnonymous,
      oauthProviders: args.oauthProviders,
      createdAt: now,
      updatedAt: now,
    });
  }
}

export const upsertUser = internalMutation({
  args: {
    id: v.string(),
    primaryEmail: v.optional(v.string()),
    primaryEmailVerified: v.boolean(),
    primaryEmailAuthEnabled: v.boolean(),
    displayName: v.optional(v.string()),
    selectedTeamId: v.optional(v.string()),
    selectedTeamDisplayName: v.optional(v.string()),
    selectedTeamProfileImageUrl: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    signedUpAtMillis: v.number(),
    lastActiveAtMillis: v.number(),
    hasPassword: v.boolean(),
    otpAuthEnabled: v.boolean(),
    passkeyAuthEnabled: v.boolean(),
    clientMetadata: v.optional(v.any()),
    clientReadOnlyMetadata: v.optional(v.any()),
    serverMetadata: v.optional(v.any()),
    isAnonymous: v.boolean(),
    oauthProviders: v.optional(
      v.array(
        v.object({
          id: v.string(),
          accountId: v.string(),
          email: v.optional(v.string()),
        })
      )
    ),
  },
  handler: async (ctx, args) => upsertUserCore(ctx, args),
});

export const deleteUser = internalMutation({
  args: { id: v.string() },
  handler: async (ctx, { id }) => deleteUserCore(ctx, id),
});

async function deleteUserCore(ctx: MutationCtx, id: string) {
  const existing = await ctx.db
    .query("users")
    .withIndex("by_uuid", (q) => q.eq("uuid", id))
    .first();
  if (existing) await ctx.db.delete(existing._id);

  // Clean up memberships and permissions for this user
  const memberships = await ctx.db
    .query("teamMemberships")
    .withIndex("by_user", (q) => q.eq("userId", id))
    .collect();
  for (const m of memberships) await ctx.db.delete(m._id);

  const perms = await ctx.db
    .query("teamPermissions")
    .withIndex("by_user", (q) => q.eq("userId", id))
    .collect();
  for (const p of perms) await ctx.db.delete(p._id);
}

// Public, auth-checked variants
export const upsertUserPublic = authMutation({
  args: {
    id: v.string(),
    primaryEmail: v.optional(v.string()),
    primaryEmailVerified: v.boolean(),
    primaryEmailAuthEnabled: v.boolean(),
    displayName: v.optional(v.string()),
    selectedTeamId: v.optional(v.string()),
    selectedTeamDisplayName: v.optional(v.string()),
    selectedTeamProfileImageUrl: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    signedUpAtMillis: v.number(),
    lastActiveAtMillis: v.number(),
    hasPassword: v.boolean(),
    otpAuthEnabled: v.boolean(),
    passkeyAuthEnabled: v.boolean(),
    clientMetadata: v.optional(v.any()),
    clientReadOnlyMetadata: v.optional(v.any()),
    serverMetadata: v.optional(v.any()),
    isAnonymous: v.boolean(),
    oauthProviders: v.optional(
      v.array(v.object({ id: v.string(), accountId: v.string(), email: v.optional(v.string()) }))
    ),
  },
  handler: async (ctx, args) => upsertUserCore(ctx, args),
});

export const deleteUserPublic = authMutation({
  args: { id: v.string() },
  handler: async (ctx, { id }) => deleteUserCore(ctx as unknown as MutationCtx, id),
});

type UpsertTeamArgs = {
  id: string;
  displayName?: string;
  profileImageUrl?: string;
  clientMetadata?: unknown;
  clientReadOnlyMetadata?: unknown;
  serverMetadata?: unknown;
  createdAtMillis: number;
};

async function upsertTeamCore(ctx: MutationCtx, args: UpsertTeamArgs) {
  const now = Date.now();
  const existing = await ctx.db
    .query("teams")
    .withIndex("by_uuid", (q) => q.eq("uuid", args.id))
    .first();
  const patch = {
    displayName: args.displayName,
    profileImageUrl: args.profileImageUrl,
    clientMetadata: args.clientMetadata,
    clientReadOnlyMetadata: args.clientReadOnlyMetadata,
    serverMetadata: args.serverMetadata,
    createdAtMillis: args.createdAtMillis,
    updatedAt: now,
  } as const;
  if (existing) {
    await ctx.db.patch(existing._id, patch);
  } else {
    await ctx.db.insert("teams", {
      uuid: args.id,
      ...patch,
      createdAt: now,
    });
  }
}

export const upsertTeam = internalMutation({
  args: {
    id: v.string(),
    displayName: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    clientMetadata: v.optional(v.any()),
    clientReadOnlyMetadata: v.optional(v.any()),
    serverMetadata: v.optional(v.any()),
    createdAtMillis: v.number(),
  },
  handler: async (ctx, args) => upsertTeamCore(ctx, args),
});

export const deleteTeam = internalMutation({
  args: { id: v.string() },
  handler: async (ctx, { id }) => deleteTeamCore(ctx, id),
});

async function deleteTeamCore(ctx: MutationCtx, id: string) {
  const existing = await ctx.db
    .query("teams")
    .withIndex("by_uuid", (q) => q.eq("uuid", id))
    .first();
  if (existing) await ctx.db.delete(existing._id);

  // Clean up memberships and permissions for this team
  const memberships = await ctx.db
    .query("teamMemberships")
    .withIndex("by_team", (q) => q.eq("teamId", id))
    .collect();
  for (const m of memberships) await ctx.db.delete(m._id);

  const perms = await ctx.db
    .query("teamPermissions")
    .withIndex("by_team", (q) => q.eq("teamId", id))
    .collect();
  for (const p of perms) await ctx.db.delete(p._id);
}

export const upsertTeamPublic = authMutation({
  args: {
    id: v.string(),
    displayName: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    clientMetadata: v.optional(v.any()),
    clientReadOnlyMetadata: v.optional(v.any()),
    serverMetadata: v.optional(v.any()),
    createdAtMillis: v.number(),
  },
  handler: async (ctx, args) => upsertTeamCore(ctx, args),
});

export const deleteTeamPublic = authMutation({
  args: { id: v.string() },
  handler: async (ctx, { id }) => deleteTeamCore(ctx as unknown as MutationCtx, id),
});

async function ensureMembershipCore(ctx: MutationCtx, teamId: string, userId: string) {
    const now = Date.now();
    const existing = await ctx.db
      .query("teamMemberships")
      .withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId))
      .first();
    if (existing) {
      await ctx.db.patch(existing._id, { updatedAt: now });
    } else {
      await ctx.db.insert("teamMemberships", {
        teamId,
        userId,
        createdAt: now,
        updatedAt: now,
      });
    }
}

export const ensureMembership = internalMutation({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, { teamId, userId }) => ensureMembershipCore(ctx, teamId, userId),
});

export const deleteMembership = internalMutation({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, { teamId, userId }) => deleteMembershipCore(ctx, teamId, userId),
});

async function deleteMembershipCore(ctx: MutationCtx, teamId: string, userId: string) {
  const existing = await ctx.db
    .query("teamMemberships")
    .withIndex("by_team_user", (q) => q.eq("teamId", teamId).eq("userId", userId))
    .first();
  if (existing) await ctx.db.delete(existing._id);
}

export const ensureMembershipPublic = authMutation({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, { teamId, userId }) => ensureMembershipCore(ctx, teamId, userId),
});

export const deleteMembershipPublic = authMutation({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, { teamId, userId }) => deleteMembershipCore(ctx as unknown as MutationCtx, teamId, userId),
});

async function ensurePermissionCore(
  ctx: MutationCtx,
  teamId: string,
  userId: string,
  permissionId: string,
) {
    const now = Date.now();
    const existing = await ctx.db
      .query("teamPermissions")
      .withIndex("by_team_user_perm", (q) =>
        q.eq("teamId", teamId).eq("userId", userId).eq("permissionId", permissionId)
      )
      .first();
    if (existing) {
      await ctx.db.patch(existing._id, { updatedAt: now });
    } else {
      await ctx.db.insert("teamPermissions", {
        teamId,
        userId,
        permissionId,
        createdAt: now,
        updatedAt: now,
      });
    }
}

export const ensurePermission = internalMutation({
  args: { teamId: v.string(), userId: v.string(), permissionId: v.string() },
  handler: async (ctx, { teamId, userId, permissionId }) =>
    ensurePermissionCore(ctx, teamId, userId, permissionId),
});

export const deletePermission = internalMutation({
  args: { teamId: v.string(), userId: v.string(), permissionId: v.string() },
  handler: async (ctx, { teamId, userId, permissionId }) =>
    deletePermissionCore(ctx, teamId, userId, permissionId),
});

async function deletePermissionCore(
  ctx: MutationCtx,
  teamId: string,
  userId: string,
  permissionId: string,
) {
  const existing = await ctx.db
    .query("teamPermissions")
    .withIndex("by_team_user_perm", (q) =>
      q.eq("teamId", teamId).eq("userId", userId).eq("permissionId", permissionId)
    )
    .first();
  if (existing) await ctx.db.delete(existing._id);
}

export const ensurePermissionPublic = authMutation({
  args: { teamId: v.string(), userId: v.string(), permissionId: v.string() },
  handler: async (ctx, { teamId, userId, permissionId }) =>
    ensurePermissionCore(ctx, teamId, userId, permissionId),
});

export const deletePermissionPublic = authMutation({
  args: { teamId: v.string(), userId: v.string(), permissionId: v.string() },
  handler: async (ctx, { teamId, userId, permissionId }) =>
    deletePermissionCore(ctx as unknown as MutationCtx, teamId, userId, permissionId),
});
