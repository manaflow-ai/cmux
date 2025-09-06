import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .first();
    return settings ?? null;
  },
});

export const update = authMutation({
  args: {
    teamSlugOrId: v.string(),
    worktreePath: v.optional(v.string()),
    autoPrEnabled: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const existing = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .first();
    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        worktreePath: args.worktreePath,
        autoPrEnabled: args.autoPrEnabled,
        userId,
        teamId,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("workspaceSettings", {
        worktreePath: args.worktreePath,
        autoPrEnabled: args.autoPrEnabled,
        createdAt: now,
        updatedAt: now,
        userId, // keep creator for auditing
        teamId,
      });
    }
  },
});
