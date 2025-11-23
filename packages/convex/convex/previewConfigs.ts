import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";
import { internalQuery } from "./_generated/server";

function normalizeRepoFullName(value: string): string {
  const trimmed = value.trim();
  if (!trimmed.includes("/")) {
    throw new Error("repoFullName must be in the form owner/name");
  }
  return trimmed.replace(/\.git$/i, "").toLowerCase();
}

export const listByTeam = authQuery({
  args: {
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const configs = await ctx.db
      .query("previewConfigs")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .order("desc")
      .collect();
    return configs;
  },
});

export const get = authQuery({
  args: {
    teamSlugOrId: v.string(),
    previewConfigId: v.id("previewConfigs"),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const config = await ctx.db.get(args.previewConfigId);
    if (!config || config.teamId !== teamId) {
      return null;
    }
    return config;
  },
});

export const getByRepo = authQuery({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const repoFullName = normalizeRepoFullName(args.repoFullName);
    const config = await ctx.db
      .query("previewConfigs")
      .withIndex("by_team_repo", (q) =>
        q.eq("teamId", teamId).eq("repoFullName", repoFullName),
      )
      .first();
    return config ?? null;
  },
});

export const upsert = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    environmentId: v.optional(v.id("environments")),
    repoInstallationId: v.optional(v.number()),
    repoDefaultBranch: v.optional(v.string()),
    status: v.optional(
      v.union(
        v.literal("active"),
        v.literal("paused"),
        v.literal("disabled"),
      ),
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    if (!userId) {
      throw new Error("Authentication required");
    }
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const repoFullName = normalizeRepoFullName(args.repoFullName);
    const now = Date.now();

    // Verify environment exists and belongs to team if provided
    if (args.environmentId) {
      const environment = await ctx.db.get(args.environmentId);
      if (!environment || environment.teamId !== teamId) {
        throw new Error("Environment not found");
      }
    }

    const existing = await ctx.db
      .query("previewConfigs")
      .withIndex("by_team_repo", (q) =>
        q.eq("teamId", teamId).eq("repoFullName", repoFullName),
      )
      .first();

    if (existing) {
      await ctx.db.patch(existing._id, {
        environmentId: args.environmentId ?? existing.environmentId,
        repoInstallationId: args.repoInstallationId ?? existing.repoInstallationId,
        repoDefaultBranch: args.repoDefaultBranch ?? existing.repoDefaultBranch,
        status: args.status ?? existing.status ?? "active",
        updatedAt: now,
      });
      return existing._id;
    }

    const id = await ctx.db.insert("previewConfigs", {
      teamId,
      createdByUserId: userId,
      repoFullName,
      repoProvider: "github",
      environmentId: args.environmentId,
      repoInstallationId: args.repoInstallationId,
      repoDefaultBranch: args.repoDefaultBranch,
      status: args.status ?? "active",
      lastRunAt: undefined,
      createdAt: now,
      updatedAt: now,
    });
    return id;
  },
});

export const getByTeamAndRepo = internalQuery({
  args: {
    teamId: v.string(),
    repoFullName: v.string(),
  },
  handler: async (ctx, args) => {
    const repoFullName = normalizeRepoFullName(args.repoFullName);
    const config = await ctx.db
      .query("previewConfigs")
      .withIndex("by_team_repo", (q) =>
        q.eq("teamId", args.teamId).eq("repoFullName", repoFullName),
      )
      .first();
    return config ?? null;
  },
});
