import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const create = mutation({
  args: {
    userId: v.string(),
    deviceId: v.string(),
    type: v.union(
      v.literal("agent_complete"),
      v.literal("build_complete"),
      v.literal("build_failed"),
      v.literal("notification_bell"),
      v.literal("command_complete")
    ),
    title: v.string(),
    body: v.optional(v.string()),
    workspaceId: v.optional(v.string()),
    metadata: v.optional(v.any()),
  },
  handler: async (ctx, args) => {
    return await ctx.db.insert("terminalEvents", {
      ...args,
      createdAt: Date.now(),
      read: false,
    });
  },
});

export const listForUser = query({
  args: {
    userId: v.string(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = args.limit ?? 50;
    return await ctx.db
      .query("terminalEvents")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .order("desc")
      .take(limit);
  },
});

export const markRead = mutation({
  args: {
    userId: v.string(),
    eventId: v.id("terminalEvents"),
  },
  handler: async (ctx, args) => {
    const event = await ctx.db.get(args.eventId);
    if (!event || event.userId !== args.userId) {
      throw new Error("Event not found");
    }
    await ctx.db.patch(args.eventId, { read: true });
  },
});
