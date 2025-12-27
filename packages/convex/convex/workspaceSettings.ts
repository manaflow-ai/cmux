import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { internalQuery } from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();
    return settings ?? null;
  },
});

export const update = authMutation({
  args: {
    teamSlugOrId: v.string(),
    worktreePath: v.optional(v.string()),
    autoPrEnabled: v.optional(v.boolean()),
    crownModel: v.optional(v.string()),
    crownSystemPrompt: v.optional(v.string()),
    heatmapModel: v.optional(v.string()),
    heatmapThreshold: v.optional(v.number()),
    heatmapTooltipLanguage: v.optional(v.string()),
    heatmapColors: v.optional(
      v.object({
        line: v.object({ start: v.string(), end: v.string() }),
        token: v.object({ start: v.string(), end: v.string() }),
      })
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();
    const now = Date.now();

    if (existing) {
      const updates: {
        worktreePath?: string;
        autoPrEnabled?: boolean;
        crownModel?: string;
        crownSystemPrompt?: string;
        heatmapModel?: string;
        heatmapThreshold?: number;
        heatmapTooltipLanguage?: string;
        heatmapColors?: {
          line: { start: string; end: string };
          token: { start: string; end: string };
        };
        updatedAt: number;
      } = { updatedAt: now };

      if (args.worktreePath !== undefined) {
        updates.worktreePath = args.worktreePath;
      }
      if (args.autoPrEnabled !== undefined) {
        updates.autoPrEnabled = args.autoPrEnabled;
      }
      if (args.crownModel !== undefined) {
        updates.crownModel = args.crownModel;
      }
      if (args.crownSystemPrompt !== undefined) {
        updates.crownSystemPrompt = args.crownSystemPrompt;
      }
      if (args.heatmapModel !== undefined) {
        updates.heatmapModel = args.heatmapModel;
      }
      if (args.heatmapThreshold !== undefined) {
        updates.heatmapThreshold = args.heatmapThreshold;
      }
      if (args.heatmapTooltipLanguage !== undefined) {
        updates.heatmapTooltipLanguage = args.heatmapTooltipLanguage;
      }
      if (args.heatmapColors !== undefined) {
        updates.heatmapColors = args.heatmapColors;
      }

      await ctx.db.patch(existing._id, updates);
    } else {
      await ctx.db.insert("workspaceSettings", {
        worktreePath: args.worktreePath,
        autoPrEnabled: args.autoPrEnabled,
        crownModel: args.crownModel,
        crownSystemPrompt: args.crownSystemPrompt,
        heatmapModel: args.heatmapModel,
        heatmapThreshold: args.heatmapThreshold,
        heatmapTooltipLanguage: args.heatmapTooltipLanguage,
        heatmapColors: args.heatmapColors,
        nextLocalWorkspaceSequence: 0,
        createdAt: now,
        updatedAt: now,
        userId,
        teamId,
      });
    }
  },
});

export const getByTeamAndUserInternal = internalQuery({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, args) => {
    const settings = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", args.teamId).eq("userId", args.userId)
      )
      .first();
    return settings ?? null;
  },
});
