import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

// Default settings
const DEFAULT_SETTINGS = {
  maxRunningContainers: 5,
  reviewPeriodMinutes: 60,
  autoCleanupEnabled: true,
  stopImmediatelyOnCompletion: false,
  minContainersToKeep: 0,
};

// Get container settings
export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("containerSettings")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .first();
    if (!settings) {
      // Return defaults if no settings exist
      return {
        ...DEFAULT_SETTINGS,
        _id: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
    }
    return {
      ...DEFAULT_SETTINGS,
      ...settings,
    };
  },
});

// Update container settings
export const update = authMutation({
  args: {
    teamSlugOrId: v.string(),
    maxRunningContainers: v.optional(v.number()),
    reviewPeriodMinutes: v.optional(v.number()),
    autoCleanupEnabled: v.optional(v.boolean()),
    stopImmediatelyOnCompletion: v.optional(v.boolean()),
    minContainersToKeep: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("containerSettings")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .first();
    const now = Date.now();

    // Only persist allowed fields; exclude teamSlugOrId
    const updates = {
      maxRunningContainers: args.maxRunningContainers,
      reviewPeriodMinutes: args.reviewPeriodMinutes,
      autoCleanupEnabled: args.autoCleanupEnabled,
      stopImmediatelyOnCompletion: args.stopImmediatelyOnCompletion,
      minContainersToKeep: args.minContainersToKeep,
    } as const;

    if (existing) {
      await ctx.db.patch(existing._id, {
        ...updates,
        userId,
        teamId,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("containerSettings", {
        ...updates,
        userId, // keep modifier for auditing
        teamId,
        createdAt: now,
        updatedAt: now,
      });
    }
  },
});

// Get effective settings with defaults
export const getEffective = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("containerSettings")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .first();
    return {
      maxRunningContainers:
        settings?.maxRunningContainers ?? DEFAULT_SETTINGS.maxRunningContainers,
      reviewPeriodMinutes:
        settings?.reviewPeriodMinutes ?? DEFAULT_SETTINGS.reviewPeriodMinutes,
      autoCleanupEnabled:
        settings?.autoCleanupEnabled ?? DEFAULT_SETTINGS.autoCleanupEnabled,
      stopImmediatelyOnCompletion:
        settings?.stopImmediatelyOnCompletion ??
        DEFAULT_SETTINGS.stopImmediatelyOnCompletion,
      minContainersToKeep:
        settings?.minContainersToKeep ?? DEFAULT_SETTINGS.minContainersToKeep,
    };
  },
});
