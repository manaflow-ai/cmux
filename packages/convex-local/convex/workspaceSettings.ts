import { v } from "convex/values";
import { mutation, query } from "./_generated/server.js";

export const get = query({
  args: {},
  handler: async (ctx) => {
    const settings = await ctx.db.query("workspaceSettings").first();
    return settings;
  },
});

export const update = mutation({
  args: {
    worktreePath: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db.query("workspaceSettings").first();
    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        worktreePath: args.worktreePath,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("workspaceSettings", {
        worktreePath: args.worktreePath,
        createdAt: now,
        updatedAt: now,
      });
    }
  },
});
