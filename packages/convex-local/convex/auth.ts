import { mutation, query } from "./_generated/server";
import { v } from "convex/values";

// Helper function to get or create user
export const getOrCreateUser = mutation({
  args: {
    stackUserId: v.string(),
    email: v.string(),
    displayName: v.optional(v.string()),
    avatarUrl: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    // Check if user already exists
    const existingUser = await ctx.db
      .query("users")
      .withIndex("by_stackUserId", (q) => q.eq("stackUserId", args.stackUserId))
      .first();

    if (existingUser) {
      // Update user info if changed
      if (
        existingUser.email !== args.email ||
        existingUser.displayName !== args.displayName ||
        existingUser.avatarUrl !== args.avatarUrl
      ) {
        await ctx.db.patch(existingUser._id, {
          email: args.email,
          displayName: args.displayName,
          avatarUrl: args.avatarUrl,
          updatedAt: Date.now(),
        });
      }
      return existingUser._id;
    }

    // Create new user
    const userId = await ctx.db.insert("users", {
      stackUserId: args.stackUserId,
      email: args.email,
      displayName: args.displayName,
      avatarUrl: args.avatarUrl,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });

    return userId;
  },
});

// Get user by Stack Auth ID
export const getUserByStackId = query({
  args: { stackUserId: v.string() },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("users")
      .withIndex("by_stackUserId", (q) => q.eq("stackUserId", args.stackUserId))
      .first();
  },
});

// Helper to extract Stack Auth user ID from auth header
export function getStackUserIdFromHeader(authHeader: string | null): string | null {
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return null;
  }
  
  // For now, we'll pass the Stack user ID as the bearer token
  // In production, you'd decode a JWT or validate the token with Stack Auth
  return authHeader.substring(7);
}