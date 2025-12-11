import { v } from "convex/values";
import { authMutation, authQuery } from "./users/utils";

// List all SSH keys for the authenticated user
export const listByUser = authQuery({
  args: {},
  handler: async (ctx) => {
    const userId = ctx.identity.subject;
    return await ctx.db
      .query("userSshKeys")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .collect();
  },
});

// Get a specific SSH key by fingerprint for the authenticated user
export const getByFingerprint = authQuery({
  args: {
    fingerprint: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    return await ctx.db
      .query("userSshKeys")
      .withIndex("by_user_fingerprint", (q) =>
        q.eq("userId", userId).eq("fingerprint", args.fingerprint)
      )
      .first();
  },
});

// Create a new SSH key for the authenticated user
export const create = authMutation({
  args: {
    name: v.string(),
    publicKey: v.string(),
    fingerprint: v.string(),
    source: v.union(
      v.literal("manual"),
      v.literal("github"),
      v.literal("local")
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;

    // Check for duplicate fingerprint
    const existing = await ctx.db
      .query("userSshKeys")
      .withIndex("by_user_fingerprint", (q) =>
        q.eq("userId", userId).eq("fingerprint", args.fingerprint)
      )
      .first();

    if (existing) {
      throw new Error("SSH key with this fingerprint already exists");
    }

    return await ctx.db.insert("userSshKeys", {
      userId,
      name: args.name,
      publicKey: args.publicKey,
      fingerprint: args.fingerprint,
      source: args.source,
      createdAt: Date.now(),
    });
  },
});

// Remove an SSH key by its ID
export const remove = authMutation({
  args: {
    id: v.id("userSshKeys"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;

    const existing = await ctx.db.get(args.id);

    if (!existing) {
      throw new Error("SSH key not found");
    }

    if (existing.userId !== userId) {
      throw new Error("Not authorized to delete this SSH key");
    }

    await ctx.db.delete(args.id);
  },
});

// Update the lastUsedAt timestamp for an SSH key
export const updateLastUsed = authMutation({
  args: {
    id: v.id("userSshKeys"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;

    const existing = await ctx.db.get(args.id);

    if (!existing) {
      throw new Error("SSH key not found");
    }

    if (existing.userId !== userId) {
      throw new Error("Not authorized to update this SSH key");
    }

    await ctx.db.patch(args.id, {
      lastUsedAt: Date.now(),
    });
  },
});
