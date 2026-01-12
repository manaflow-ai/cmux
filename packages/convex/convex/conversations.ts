import { v } from "convex/values";
import { SignJWT } from "jose";
import { env } from "../_shared/convex-env";
import { getTeamId } from "../_shared/team";
import { internal } from "./_generated/api";
import type { Doc, Id } from "./_generated/dataModel";
import {
  internalMutation,
  internalQuery,
  type MutationCtx,
  type QueryCtx,
} from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

// Validators for ACP types
const isolationModeValidator = v.union(
  v.literal("none"),
  v.literal("shared_namespace"),
  v.literal("dedicated_namespace")
);

const statusValidator = v.union(
  v.literal("active"),
  v.literal("completed"),
  v.literal("cancelled"),
  v.literal("error")
);

const stopReasonValidator = v.union(
  v.literal("end_turn"),
  v.literal("max_tokens"),
  v.literal("max_turn_requests"),
  v.literal("refusal"),
  v.literal("cancelled")
);

const providerIdValidator = v.union(
  v.literal("claude"),
  v.literal("codex"),
  v.literal("gemini"),
  v.literal("opencode")
);

// Create a new conversation
export const create = authMutation({
  args: {
    teamSlugOrId: v.string(),
    sessionId: v.string(),
    providerId: providerIdValidator,
    cwd: v.string(),
    isolationMode: v.optional(isolationModeValidator),
    namespaceId: v.optional(v.string()),
    sandboxInstanceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const identity = await ctx.auth.getUserIdentity();
    const userId = identity?.subject;
    const now = Date.now();

    const conversationId = await ctx.db.insert("conversations", {
      teamId,
      userId: userId ?? undefined,
      sessionId: args.sessionId,
      providerId: args.providerId,
      cwd: args.cwd,
      status: "active",
      isolationMode: args.isolationMode,
      namespaceId: args.namespaceId,
      sandboxInstanceId: args.sandboxInstanceId,
      createdAt: now,
      updatedAt: now,
    });

    // Generate JWT for this conversation
    const secret = env.CMUX_CONVERSATION_JWT_SECRET ?? env.CMUX_TASK_RUN_JWT_SECRET;
    const jwt = await new SignJWT({
      conversationId,
      teamId,
      userId,
    })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuedAt()
      .setExpirationTime("12h")
      .sign(new TextEncoder().encode(secret));

    return { conversationId, jwt };
  },
});

// Get a conversation by ID
export const getById = authQuery({
  args: {
    teamSlugOrId: v.string(),
    conversationId: v.id("conversations"),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation || conversation.teamId !== teamId) {
      return null;
    }
    return conversation;
  },
});

// Internal query to get conversation by ID (for JWT verification)
export const getByIdInternal = internalQuery({
  args: {
    conversationId: v.id("conversations"),
  },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.conversationId);
  },
});

// Get a conversation by session ID
export const getBySessionId = authQuery({
  args: {
    teamSlugOrId: v.string(),
    sessionId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const conversation = await ctx.db
      .query("conversations")
      .withIndex("by_session", (q) => q.eq("sessionId", args.sessionId))
      .first();
    if (!conversation || conversation.teamId !== teamId) {
      return null;
    }
    return conversation;
  },
});

// List conversations for a team
export const list = authQuery({
  args: {
    teamSlugOrId: v.string(),
    status: v.optional(statusValidator),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const limit = args.limit ?? 50;

    if (args.status) {
      return await ctx.db
        .query("conversations")
        .withIndex("by_team_status", (q) =>
          q.eq("teamId", teamId).eq("status", args.status!)
        )
        .order("desc")
        .take(limit);
    }

    return await ctx.db
      .query("conversations")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .order("desc")
      .take(limit);
  },
});

// List conversations by namespace
export const listByNamespace = authQuery({
  args: {
    teamSlugOrId: v.string(),
    namespaceId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const conversations = await ctx.db
      .query("conversations")
      .withIndex("by_namespace", (q) => q.eq("namespaceId", args.namespaceId))
      .collect();
    return conversations.filter((c) => c.teamId === teamId);
  },
});

// List conversations by sandbox instance
export const listBySandbox = authQuery({
  args: {
    teamSlugOrId: v.string(),
    sandboxInstanceId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const conversations = await ctx.db
      .query("conversations")
      .withIndex("by_sandbox", (q) =>
        q.eq("sandboxInstanceId", args.sandboxInstanceId)
      )
      .collect();
    return conversations.filter((c) => c.teamId === teamId);
  },
});

// Update conversation status
export const updateStatus = internalMutation({
  args: {
    conversationId: v.id("conversations"),
    status: statusValidator,
    stopReason: v.optional(stopReasonValidator),
  },
  handler: async (ctx, args) => {
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation) {
      throw new Error("Conversation not found");
    }

    await ctx.db.patch(args.conversationId, {
      status: args.status,
      stopReason: args.stopReason,
      updatedAt: Date.now(),
    });
  },
});

// Update conversation modes (from ACP session updates)
export const updateModes = internalMutation({
  args: {
    conversationId: v.id("conversations"),
    modes: v.object({
      currentModeId: v.string(),
      availableModes: v.array(
        v.object({
          id: v.string(),
          name: v.string(),
          description: v.optional(v.string()),
        })
      ),
    }),
  },
  handler: async (ctx, args) => {
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation) {
      throw new Error("Conversation not found");
    }

    await ctx.db.patch(args.conversationId, {
      modes: args.modes,
      updatedAt: Date.now(),
    });
  },
});

// Update agent info (from ACP initialization)
export const updateAgentInfo = internalMutation({
  args: {
    conversationId: v.id("conversations"),
    agentInfo: v.object({
      name: v.string(),
      version: v.string(),
      title: v.optional(v.string()),
    }),
  },
  handler: async (ctx, args) => {
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation) {
      throw new Error("Conversation not found");
    }

    await ctx.db.patch(args.conversationId, {
      agentInfo: args.agentInfo,
      updatedAt: Date.now(),
    });
  },
});

// Create a conversation without authentication (for internal use/testing)
export const createInternal = internalMutation({
  args: {
    teamId: v.id("teams"),
    sessionId: v.string(),
    providerId: providerIdValidator,
    cwd: v.string(),
    isolationMode: v.optional(isolationModeValidator),
    namespaceId: v.optional(v.string()),
    sandboxInstanceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();

    const conversationId = await ctx.db.insert("conversations", {
      teamId: args.teamId,
      sessionId: args.sessionId,
      providerId: args.providerId,
      cwd: args.cwd,
      status: "active",
      isolationMode: args.isolationMode,
      namespaceId: args.namespaceId,
      sandboxInstanceId: args.sandboxInstanceId,
      createdAt: now,
      updatedAt: now,
    });

    // Generate JWT for this conversation
    const secret = env.CMUX_CONVERSATION_JWT_SECRET ?? env.CMUX_TASK_RUN_JWT_SECRET;
    const jwt = await new SignJWT({
      conversationId,
      teamId: args.teamId,
    })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuedAt()
      .setExpirationTime("12h")
      .sign(new TextEncoder().encode(secret));

    return { conversationId, jwt };
  },
});

// Generate a new JWT for an existing conversation
export const generateJwt = internalMutation({
  args: {
    conversationId: v.id("conversations"),
  },
  handler: async (ctx, args) => {
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation) {
      throw new Error("Conversation not found");
    }

    const secret = env.CMUX_CONVERSATION_JWT_SECRET ?? env.CMUX_TASK_RUN_JWT_SECRET;
    const jwt = await new SignJWT({
      conversationId: args.conversationId,
      teamId: conversation.teamId,
      userId: conversation.userId,
    })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuedAt()
      .setExpirationTime("12h")
      .sign(new TextEncoder().encode(secret));

    return { jwt };
  },
});
