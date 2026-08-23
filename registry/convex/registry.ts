import { v } from "convex/values";
import { internalMutation, mutation, query } from "./_generated/server";
import type { Doc } from "./_generated/dataModel";

// Staging-grade auth: a shared key checked against deployment env
// (REGISTRY_AUTH_KEY). Replaced by real account identity (Stack) at
// graduation; the tuple (account, deviceId, appIdentity) flows explicitly
// so nothing else changes when auth does.
function requireAuth(authKey: string) {
  const expected = process.env.REGISTRY_AUTH_KEY;
  if (!expected || authKey !== expected) {
    throw new Error("registry: unauthorized");
  }
}

// 30s beats renew a 90s lease (three missed beats = offline). The sweep
// runs on a cron and flips `online` — the ONE data change per transition
// that pushes fresh lists to subscribers.
export const LEASE_MS = 90_000;

const identityArgs = {
  authKey: v.string(),
  account: v.string(),
  deviceId: v.string(),
  appIdentity: v.string(),
};

async function findDevice(
  ctx: { db: any },
  account: string,
  deviceId: string,
  appIdentity: string,
): Promise<Doc<"devices"> | null> {
  return await ctx.db
    .query("devices")
    .withIndex("by_identity", (q: any) =>
      q.eq("account", account).eq("deviceId", deviceId).eq("appIdentity", appIdentity),
    )
    .unique();
}

async function writeBeat(ctx: { db: any }, device: Doc<"devices">, now: number) {
  const beat = await ctx.db
    .query("presenceBeats")
    .withIndex("by_device", (q: any) => q.eq("device", device._id))
    .unique();
  if (beat) {
    await ctx.db.patch(beat._id, { lastSeenAt: now });
  } else {
    await ctx.db.insert("presenceBeats", { device: device._id, lastSeenAt: now });
  }
}

/// Durable row upsert: sign-in, launch, or route change. Marks online
/// (an explicit liveness signal) and writes a beat.
export const upsertDevice = mutation({
  args: {
    ...identityArgs,
    kind: v.union(v.literal("mac"), v.literal("phone")),
    name: v.string(),
    endpointKey: v.string(),
    homeRelay: v.optional(v.string()),
    directAddrs: v.optional(v.array(v.string())),
    capabilities: v.optional(v.array(v.string())),
  },
  handler: async (ctx, args) => {
    requireAuth(args.authKey);
    const now = Date.now();
    const existing = await findDevice(ctx, args.account, args.deviceId, args.appIdentity);
    const fields = {
      kind: args.kind,
      name: args.name,
      endpointKey: args.endpointKey,
      homeRelay: args.homeRelay,
      directAddrs: args.directAddrs ?? [],
      capabilities: args.capabilities ?? [],
      online: true,
      updatedAt: now,
    };
    let device: Doc<"devices">;
    if (existing) {
      await ctx.db.patch(existing._id, fields);
      device = (await ctx.db.get(existing._id))!;
    } else {
      const id = await ctx.db.insert("devices", {
        account: args.account,
        deviceId: args.deviceId,
        appIdentity: args.appIdentity,
        hiddenFrom: [],
        ...fields,
      });
      device = (await ctx.db.get(id))!;
    }
    await writeBeat(ctx, device, now);
    return { ok: true };
  },
});

/// Proof of life. Touches only the beats side table unless the device was
/// offline, in which case coming back IS a transition and flips the row.
export const beat = mutation({
  args: identityArgs,
  handler: async (ctx, args) => {
    requireAuth(args.authKey);
    const device = await findDevice(ctx, args.account, args.deviceId, args.appIdentity);
    if (!device) return { ok: false, reason: "unknown-device" };
    const now = Date.now();
    await writeBeat(ctx, device, now);
    if (!device.online) {
      await ctx.db.patch(device._id, { online: true, updatedAt: now });
    }
    return { ok: true };
  },
});

/// Sign-out is NEVER lease-waited (Aziz 08-22): explicit, implicit, or
/// graceful-shutdown sign-outs flip presence immediately.
export const signOut = mutation({
  args: identityArgs,
  handler: async (ctx, args) => {
    requireAuth(args.authKey);
    const device = await findDevice(ctx, args.account, args.deviceId, args.appIdentity);
    if (!device) return { ok: false, reason: "unknown-device" };
    if (device.online) {
      await ctx.db.patch(device._id, { online: false, updatedAt: Date.now() });
    }
    return { ok: true };
  },
});

/// The device's own visibility policy: hide me from these viewer deviceIds.
export const setVisibility = mutation({
  args: { ...identityArgs, hiddenFrom: v.array(v.string()) },
  handler: async (ctx, args) => {
    requireAuth(args.authKey);
    const device = await findDevice(ctx, args.account, args.deviceId, args.appIdentity);
    if (!device) return { ok: false, reason: "unknown-device" };
    await ctx.db.patch(device._id, { hiddenFrom: args.hiddenFrom, updatedAt: Date.now() });
    return { ok: true };
  },
});

/// Revocation (stolen device, unpair): the row IS the handle — remove it
/// and its beats. Grants/bindings revocation rides the broker (9.3); this
/// removes discoverability and the device-list entry everywhere.
export const revoke = mutation({
  args: identityArgs,
  handler: async (ctx, args) => {
    requireAuth(args.authKey);
    const device = await findDevice(ctx, args.account, args.deviceId, args.appIdentity);
    if (!device) return { ok: false, reason: "unknown-device" };
    const beat = await ctx.db
      .query("presenceBeats")
      .withIndex("by_device", (q: any) => q.eq("device", device._id))
      .unique();
    if (beat) await ctx.db.delete(beat._id);
    await ctx.db.delete(device._id);
    return { ok: true };
  },
});

/// The phone's standing subscription: the full, fresh Mac list for the
/// account (snapshot semantics — Aziz 08-22: whole lists, never deltas),
/// visibility enforced server-side so hidden Macs never reach an excluded
/// viewer's snapshot.
export const macsFor = query({
  args: {
    authKey: v.string(),
    account: v.string(),
    viewerDeviceId: v.string(),
  },
  handler: async (ctx, args) => {
    requireAuth(args.authKey);
    const rows = await ctx.db
      .query("devices")
      .withIndex("by_account", (q: any) => q.eq("account", args.account))
      .collect();
    return rows
      .filter((d: Doc<"devices">) => d.kind === "mac")
      .filter((d: Doc<"devices">) => !d.hiddenFrom.includes(args.viewerDeviceId))
      .map((d: Doc<"devices">) => ({
        deviceId: d.deviceId,
        appIdentity: d.appIdentity,
        name: d.name,
        endpointKey: d.endpointKey,
        homeRelay: d.homeRelay ?? null,
        directAddrs: d.directAddrs,
        online: d.online,
        updatedAt: d.updatedAt,
      }))
      .sort((a, b) => a.name.localeCompare(b.name));
  },
});

/// The lease sweep: flip online -> offline for devices whose last beat is
/// older than the lease. Runs on a cron (see crons.ts); each flip is one
/// real transition and one push to subscribers.
export const sweep = internalMutation({
  args: {},
  handler: async (ctx) => {
    const cutoff = Date.now() - LEASE_MS;
    const online = await ctx.db
      .query("devices")
      .filter((q) => q.eq(q.field("online"), true))
      .collect();
    let flipped = 0;
    for (const device of online) {
      const beat = await ctx.db
        .query("presenceBeats")
        .withIndex("by_device", (q: any) => q.eq("device", device._id))
        .unique();
      if (!beat || beat.lastSeenAt < cutoff) {
        await ctx.db.patch(device._id, { online: false, updatedAt: Date.now() });
        flipped += 1;
      }
    }
    return { flipped };
  },
});
