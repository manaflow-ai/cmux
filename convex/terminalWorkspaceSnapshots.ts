import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const update = mutation({
  args: {
    userId: v.string(),
    deviceId: v.string(),
    workspaces: v.array(
      v.object({
        id: v.string(),
        title: v.string(),
        surfaceCount: v.number(),
        hasActivity: v.boolean(),
      })
    ),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("terminalWorkspaceSnapshots")
      .withIndex("by_user_device", (q) =>
        q.eq("userId", args.userId).eq("deviceId", args.deviceId)
      )
      .unique();

    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        workspaces: args.workspaces,
        updatedAt: now,
      });
      return existing._id;
    }

    return await ctx.db.insert("terminalWorkspaceSnapshots", {
      ...args,
      updatedAt: now,
    });
  },
});

export const getForDevice = query({
  args: {
    userId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("terminalWorkspaceSnapshots")
      .withIndex("by_user_device", (q) =>
        q.eq("userId", args.userId).eq("deviceId", args.deviceId)
      )
      .unique();
  },
});
