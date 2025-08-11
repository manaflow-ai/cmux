import { v } from "convex/values";
import { mutation, query } from "./_generated/server";

// Default settings
const DEFAULT_SETTINGS = {
  maxRunningContainers: 5,
  reviewPeriodMinutes: 60,
  autoCleanupEnabled: true,
  stopImmediatelyOnCompletion: false,
  minContainersToKeep: 0,
};

// Get container settings
export const get = query({
  handler: async (ctx) => {
    const settings = await ctx.db.query("containerSettings").first();
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
export const update = mutation({
  args: {
    maxRunningContainers: v.optional(v.number()),
    reviewPeriodMinutes: v.optional(v.number()),
    autoCleanupEnabled: v.optional(v.boolean()),
    stopImmediatelyOnCompletion: v.optional(v.boolean()),
    minContainersToKeep: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db.query("containerSettings").first();
    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        ...args,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("containerSettings", {
        ...args,
        createdAt: now,
        updatedAt: now,
      });
    }
  },
});

// Get effective settings with defaults
export const getEffective = query({
  handler: async (ctx) => {
    const settings = await ctx.db.query("containerSettings").first();
    return {
      maxRunningContainers: settings?.maxRunningContainers ?? DEFAULT_SETTINGS.maxRunningContainers,
      reviewPeriodMinutes: settings?.reviewPeriodMinutes ?? DEFAULT_SETTINGS.reviewPeriodMinutes,
      autoCleanupEnabled: settings?.autoCleanupEnabled ?? DEFAULT_SETTINGS.autoCleanupEnabled,
      stopImmediatelyOnCompletion: settings?.stopImmediatelyOnCompletion ?? DEFAULT_SETTINGS.stopImmediatelyOnCompletion,
      minContainersToKeep: settings?.minContainersToKeep ?? DEFAULT_SETTINGS.minContainersToKeep,
    };
  },
});