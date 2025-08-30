import { v } from "convex/values";
import { env } from "../_shared/convex-env";
import { internalMutation, internalQuery } from "./_generated/server";
import { authMutation } from "./users/utils";

function base64urlFromBytes(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  const abc =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let out = "";
  let i = 0;
  for (; i + 2 < bytes.length; i += 3) {
    const x = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
    out += abc[(x >> 6) & 63];
    out += abc[x & 63];
  }
  if (i + 1 === bytes.length) {
    const x = bytes[i] << 16;
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
  } else if (i < bytes.length) {
    const x = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += abc[(x >> 18) & 63];
    out += abc[(x >> 12) & 63];
    out += abc[(x >> 6) & 63];
  }
  return out;
}

async function hmacSha256(secret: string, payload: string): Promise<ArrayBuffer> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  return await crypto.subtle.sign("HMAC", key, enc.encode(payload));
}

export const recordWebhookDelivery = internalMutation({
  args: {
    provider: v.string(),
    deliveryId: v.string(),
    installationId: v.optional(v.number()),
    payloadHash: v.string(),
  },
  handler: async (
    ctx,
    { provider, deliveryId, installationId, payloadHash }
  ) => {
    const existing = await ctx.db
      .query("webhookDeliveries")
      .withIndex("by_deliveryId", (q) => q.eq("deliveryId", deliveryId))
      .first();
    if (existing) return { created: false } as const;
    await ctx.db.insert("webhookDeliveries", {
      provider,
      deliveryId,
      installationId,
      payloadHash,
      receivedAt: Date.now(),
    });
    return { created: true } as const;
  },
});

export const upsertProviderConnectionFromInstallation = internalMutation({
  args: {
    installationId: v.number(),
    accountLogin: v.optional(v.string()),
    accountId: v.optional(v.number()),
    accountType: v.optional(
      v.union(v.literal("User"), v.literal("Organization"))
    ),
    // Optional: if the installation was initiated from a specific team context
    teamId: v.optional(v.string()),
    connectedByUserId: v.optional(v.string()),
    isActive: v.optional(v.boolean()),
  },
  handler: async (
    ctx,
    {
      installationId,
      accountLogin,
      accountId,
      accountType,
      teamId,
      connectedByUserId,
      isActive,
    }
  ) => {
    const now = Date.now();
    const existing = await ctx.db
      .query("providerConnections")
      .withIndex("by_installationId", (q) =>
        q.eq("installationId", installationId)
      )
      .first();
    if (existing) {
      await ctx.db.patch(existing._id, {
        ...(accountLogin !== undefined ? { accountLogin } : {}),
        ...(accountId !== undefined ? { accountId } : {}),
        ...(accountType !== undefined ? { accountType } : {}),
        teamId: teamId ?? existing.teamId,
        connectedByUserId: connectedByUserId ?? existing.connectedByUserId,
        isActive: isActive ?? true,
        updatedAt: now,
      });
      return existing._id;
    }
    const id = await ctx.db.insert("providerConnections", {
      installationId,
      accountLogin,
      accountId,
      accountType,
      teamId, // may be undefined until mapped
      connectedByUserId,
      type: "github_app",
      isActive: isActive ?? true,
      createdAt: now,
      updatedAt: now,
    });
    return id;
  },
});

export const deactivateProviderConnection = internalMutation({
  args: { installationId: v.number() },
  handler: async (ctx, { installationId }) => {
    const existing = await ctx.db
      .query("providerConnections")
      .withIndex("by_installationId", (q) =>
        q.eq("installationId", installationId)
      )
      .first();
    if (!existing) return { ok: true } as const;
    await ctx.db.patch(existing._id, {
      isActive: false,
      updatedAt: Date.now(),
    });
    return { ok: true } as const;
  },
});

// Mint a signed, single-use install state token for mapping installation -> team
export const mintInstallState = authMutation({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, { teamSlugOrId }) => {
    if (!env.INSTALL_STATE_SECRET)
      throw new Error("Missing INSTALL_STATE_SECRET");
    const identity = ctx.identity;
    const userId = identity.subject;
    // Enforce membership
    // Avoid import cycles by replicating minimal getTeamId check here would be heavy; reuse queries not possible.
    // We'll query teams by slug and ensure membership.
    const teamId = await (async () => {
      // Try by UUID (fast path)
      const uuidRegex =
        /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
      if (uuidRegex.test(teamSlugOrId)) return teamSlugOrId;
      const team = await ctx.db
        .query("teams")
        .withIndex("by_slug", (q) => q.eq("slug", teamSlugOrId))
        .first();
      if (!team) throw new Error("Unknown team");
      // Check membership
      const membership = await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) =>
          q.eq("teamId", team.uuid).eq("userId", userId)
        )
        .first();
      if (!membership) throw new Error("Forbidden");
      return team.uuid;
    })();

    // Generate random nonce
    const nonceBytes = new Uint8Array(16);
    crypto.getRandomValues(nonceBytes);
    const nonce = Array.from(nonceBytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    const now = Date.now();
    const exp = now + 10 * 60 * 1000; // 10 minutes
    const payloadObj = {
      ver: 1,
      teamId,
      userId,
      iat: now,
      exp,
      nonce,
    } as const;
    const payload = JSON.stringify(payloadObj);
    const sigBuf = await hmacSha256(env.INSTALL_STATE_SECRET, payload);
    const payloadB64 = base64urlFromBytes(new TextEncoder().encode(payload));
    const sigB64 = base64urlFromBytes(sigBuf);
    const token = `v2.${payloadB64}.${sigB64}`;

    await ctx.db.insert("installStates", {
      nonce,
      teamId,
      userId,
      iat: now,
      exp,
      status: "pending",
      createdAt: now,
    });

    return { state: token } as const;
  },
});

export const getInstallStateByNonce = internalQuery({
  args: { nonce: v.string() },
  handler: async (ctx, { nonce }) => {
    return await ctx.db
      .query("installStates")
      .withIndex("by_nonce", (q) => q.eq("nonce", nonce))
      .first();
  },
});

export const consumeInstallState = internalMutation({
  args: { nonce: v.string(), expire: v.optional(v.boolean()) },
  handler: async (ctx, { nonce, expire }) => {
    const row = await ctx.db
      .query("installStates")
      .withIndex("by_nonce", (q) => q.eq("nonce", nonce))
      .first();
    if (!row) return { ok: false as const };
    await ctx.db.patch(row._id, { status: expire ? "expired" : "used" });
    return { ok: true as const };
  },
});
