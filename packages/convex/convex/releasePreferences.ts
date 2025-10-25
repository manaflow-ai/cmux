import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { internalQuery } from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

const DEFAULT_SETTINGS = {
  alwaysUseLatestRelease: false,
};

export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("releasePreferences")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();

    if (!settings) {
      const now = Date.now();
      return {
        ...DEFAULT_SETTINGS,
        _id: null,
        createdAt: now,
        updatedAt: now,
      };
    }

    return {
      ...DEFAULT_SETTINGS,
      ...settings,
    };
  },
});

export const update = authMutation({
  args: {
    teamSlugOrId: v.string(),
    alwaysUseLatestRelease: v.boolean(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("releasePreferences")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();

    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        alwaysUseLatestRelease: args.alwaysUseLatestRelease,
        userId,
        teamId,
        updatedAt: now,
      });
      return;
    }

    await ctx.db.insert("releasePreferences", {
      alwaysUseLatestRelease: args.alwaysUseLatestRelease,
      createdAt: now,
      updatedAt: now,
      userId,
      teamId,
    });
  },
});

export const getByTeamAndUserInternal = internalQuery({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, args) => {
    const settings = await ctx.db
      .query("releasePreferences")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", args.teamId).eq("userId", args.userId)
      )
      .first();

    return {
      alwaysUseLatestRelease:
        settings?.alwaysUseLatestRelease ??
        DEFAULT_SETTINGS.alwaysUseLatestRelease,
    };
  },
});
