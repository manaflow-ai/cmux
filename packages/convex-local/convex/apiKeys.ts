import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

export const getAll = query({
  args: {},
  handler: async (ctx) => {
    return await ctx.db.query("apiKeys").collect();
  },
});

export const getByEnvVar = query({
  args: {
    envVar: v.string(),
  },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("apiKeys")
      .withIndex("by_envVar", (q) => q.eq("envVar", args.envVar))
      .first();
  },
});

export const upsert = mutation({
  args: {
    envVar: v.string(),
    value: v.string(),
    displayName: v.string(),
    description: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("apiKeys")
      .withIndex("by_envVar", (q) => q.eq("envVar", args.envVar))
      .first();

    if (existing) {
      await ctx.db.patch(existing._id, {
        value: args.value,
        displayName: args.displayName,
        description: args.description,
        updatedAt: Date.now(),
      });
      return existing._id;
    } else {
      return await ctx.db.insert("apiKeys", {
        envVar: args.envVar,
        value: args.value,
        displayName: args.displayName,
        description: args.description,
        createdAt: Date.now(),
        updatedAt: Date.now(),
      });
    }
  },
});

export const remove = mutation({
  args: {
    envVar: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("apiKeys")
      .withIndex("by_envVar", (q) => q.eq("envVar", args.envVar))
      .first();

    if (existing) {
      await ctx.db.delete(existing._id);
    }
  },
});

export const getAllForAgents = query({
  args: {},
  handler: async (ctx) => {
    const apiKeys = await ctx.db.query("apiKeys").collect();
    const keyMap: Record<string, string> = {};

    for (const key of apiKeys) {
      keyMap[key.envVar] = key.value;
    }

    return keyMap;
  },
});
