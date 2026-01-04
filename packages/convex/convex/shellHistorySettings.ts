import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { internalQuery } from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

// Default settings
const DEFAULT_SETTINGS = {
  enabled: false,
  sanitizedHistory: null as string | null,
};

// Get shell history settings
export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("shellHistorySettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .first();
    if (!settings) {
      return {
        ...DEFAULT_SETTINGS,
        _id: null,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      };
    }
    return settings;
  },
});

// Update shell history settings
export const update = authMutation({
  args: {
    teamSlugOrId: v.string(),
    enabled: v.boolean(),
    sanitizedHistory: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("shellHistorySettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .first();
    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        enabled: args.enabled,
        sanitizedHistory: args.sanitizedHistory,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("shellHistorySettings", {
        enabled: args.enabled,
        sanitizedHistory: args.sanitizedHistory,
        userId,
        teamId,
        createdAt: now,
        updatedAt: now,
      });
    }
  },
});

// Internal query for fetching shell history during VM provisioning
export const getShellHistoryInternal = internalQuery({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, args) => {
    const settings = await ctx.db
      .query("shellHistorySettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", args.teamId).eq("userId", args.userId),
      )
      .first();

    if (!settings || !settings.enabled) {
      return null;
    }

    return settings.sanitizedHistory || null;
  },
});
