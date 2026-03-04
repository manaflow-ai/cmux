import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  terminalDevices: defineTable({
    userId: v.string(),
    deviceId: v.string(),
    hostname: v.string(),
    tailscaleHostname: v.optional(v.string()),
    sshPort: v.number(),
    capabilities: v.array(v.string()),
    osVersion: v.string(),
    appVersion: v.string(),
    status: v.union(v.literal("online"), v.literal("offline")),
    lastSeen: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_device", ["userId", "deviceId"]),

  terminalWorkspaceSnapshots: defineTable({
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
    updatedAt: v.number(),
  }).index("by_user_device", ["userId", "deviceId"]),

  terminalEvents: defineTable({
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
    createdAt: v.number(),
    read: v.boolean(),
  })
    .index("by_user", ["userId", "createdAt"])
    .index("by_user_unread", ["userId", "read"]),
});
