import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

// Contract 9.6: durable device rows (pairing is a relationship, not
// presence) with a volatile `online` field. Rows are removed only by
// revocation/unpairing; presence transitions gray devices out, never
// delete them. Beats live in a side table so proof-of-life writes never
// re-push subscribed device lists; only real transitions do.
export default defineSchema({
  devices: defineTable({
    account: v.string(),
    deviceId: v.string(),
    // Build identity (bundle id): INTERNAL/BETA/release on one phone are
    // fully separate participants (contract 1.5).
    appIdentity: v.string(),
    kind: v.union(v.literal("mac"), v.literal("phone")),
    name: v.string(),
    endpointKey: v.string(),
    homeRelay: v.optional(v.string()),
    directAddrs: v.array(v.string()),
    capabilities: v.array(v.string()),
    online: v.boolean(),
    // Visibility policy, owned by the device itself: deviceIds of viewers
    // this device hides from. Enforced server-side in queries.
    hiddenFrom: v.array(v.string()),
    updatedAt: v.number(),
  })
    .index("by_account", ["account"])
    .index("by_identity", ["account", "deviceId", "appIdentity"]),

  presenceBeats: defineTable({
    device: v.id("devices"),
    lastSeenAt: v.number(),
  }).index("by_device", ["device"]),
});
