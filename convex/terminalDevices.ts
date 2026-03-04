import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

export const register = mutation({
  args: {
    userId: v.string(),
    deviceId: v.string(),
    hostname: v.string(),
    tailscaleHostname: v.optional(v.string()),
    sshPort: v.number(),
    capabilities: v.array(v.string()),
    osVersion: v.string(),
    appVersion: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("terminalDevices")
      .withIndex("by_user_device", (q) =>
        q.eq("userId", args.userId).eq("deviceId", args.deviceId)
      )
      .unique();

    const now = Date.now();

    if (existing) {
      await ctx.db.patch(existing._id, {
        hostname: args.hostname,
        tailscaleHostname: args.tailscaleHostname,
        sshPort: args.sshPort,
        capabilities: args.capabilities,
        osVersion: args.osVersion,
        appVersion: args.appVersion,
        status: "online",
        lastSeen: now,
      });
      return existing._id;
    }

    return await ctx.db.insert("terminalDevices", {
      ...args,
      status: "online",
      lastSeen: now,
    });
  },
});

export const heartbeat = mutation({
  args: {
    userId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db
      .query("terminalDevices")
      .withIndex("by_user_device", (q) =>
        q.eq("userId", args.userId).eq("deviceId", args.deviceId)
      )
      .unique();

    if (!device) {
      throw new Error(`Device not found: ${args.deviceId}`);
    }

    await ctx.db.patch(device._id, {
      status: "online",
      lastSeen: Date.now(),
    });
  },
});

export const markOffline = mutation({
  args: {
    userId: v.string(),
    deviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const device = await ctx.db
      .query("terminalDevices")
      .withIndex("by_user_device", (q) =>
        q.eq("userId", args.userId).eq("deviceId", args.deviceId)
      )
      .unique();

    if (!device) {
      return;
    }

    await ctx.db.patch(device._id, {
      status: "offline",
    });
  },
});

export const listForUser = query({
  args: {
    userId: v.string(),
  },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("terminalDevices")
      .withIndex("by_user", (q) => q.eq("userId", args.userId))
      .take(100);
  },
});
