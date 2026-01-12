import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import type { Doc, Id } from "./_generated/dataModel";
import {
  internalMutation,
  internalQuery,
  type MutationCtx,
  type QueryCtx,
} from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

// Content block validator matching ACP ContentBlock types
const contentBlockValidator = v.object({
  type: v.union(
    v.literal("text"),
    v.literal("image"),
    v.literal("audio"),
    v.literal("resource_link"),
    v.literal("resource")
  ),
  // Text content
  text: v.optional(v.string()),
  // Image/Audio content (base64 encoded)
  data: v.optional(v.string()),
  mimeType: v.optional(v.string()),
  uri: v.optional(v.string()),
  // Resource content (embedded)
  resource: v.optional(
    v.object({
      uri: v.string(),
      text: v.optional(v.string()),
      blob: v.optional(v.string()),
      mimeType: v.optional(v.string()),
    })
  ),
  // Resource link properties
  name: v.optional(v.string()),
  description: v.optional(v.string()),
  size: v.optional(v.number()),
  title: v.optional(v.string()),
  // Annotations
  annotations: v.optional(
    v.object({
      audience: v.optional(v.array(v.string())),
      lastModified: v.optional(v.string()),
      priority: v.optional(v.number()),
    })
  ),
});

// Tool call validator
const toolCallValidator = v.object({
  id: v.string(),
  name: v.string(),
  arguments: v.string(),
  status: v.union(
    v.literal("pending"),
    v.literal("running"),
    v.literal("completed"),
    v.literal("failed")
  ),
  result: v.optional(v.string()),
});

const roleValidator = v.union(v.literal("user"), v.literal("assistant"));

// Create a new message (internal - called from ACP server)
export const create = internalMutation({
  args: {
    conversationId: v.id("conversations"),
    role: roleValidator,
    content: v.array(contentBlockValidator),
    toolCalls: v.optional(v.array(toolCallValidator)),
  },
  handler: async (ctx, args) => {
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation) {
      throw new Error("Conversation not found");
    }

    const messageId = await ctx.db.insert("conversationMessages", {
      conversationId: args.conversationId,
      role: args.role,
      content: args.content,
      toolCalls: args.toolCalls,
      createdAt: Date.now(),
    });

    // Update conversation's updatedAt
    await ctx.db.patch(args.conversationId, {
      updatedAt: Date.now(),
    });

    return messageId;
  },
});

// Update tool call status in a message
export const updateToolCall = internalMutation({
  args: {
    messageId: v.id("conversationMessages"),
    toolCallId: v.string(),
    status: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed")
    ),
    result: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const message = await ctx.db.get(args.messageId);
    if (!message) {
      throw new Error("Message not found");
    }

    if (!message.toolCalls) {
      throw new Error("Message has no tool calls");
    }

    const updatedToolCalls = message.toolCalls.map((tc) => {
      if (tc.id === args.toolCallId) {
        return {
          ...tc,
          status: args.status,
          result: args.result ?? tc.result,
        };
      }
      return tc;
    });

    await ctx.db.patch(args.messageId, {
      toolCalls: updatedToolCalls,
    });
  },
});

// Append content to an existing message (for streaming)
export const appendContent = internalMutation({
  args: {
    messageId: v.id("conversationMessages"),
    content: v.array(contentBlockValidator),
  },
  handler: async (ctx, args) => {
    const message = await ctx.db.get(args.messageId);
    if (!message) {
      throw new Error("Message not found");
    }

    await ctx.db.patch(args.messageId, {
      content: [...message.content, ...args.content],
    });

    // Update conversation's updatedAt
    await ctx.db.patch(message.conversationId, {
      updatedAt: Date.now(),
    });
  },
});

// Get messages for a conversation (internal)
export const listByConversationInternal = internalQuery({
  args: {
    conversationId: v.id("conversations"),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = args.limit ?? 100;
    return await ctx.db
      .query("conversationMessages")
      .withIndex("by_conversation", (q) =>
        q.eq("conversationId", args.conversationId)
      )
      .order("asc")
      .take(limit);
  },
});

// Get messages for a conversation (authenticated)
export const listByConversation = authQuery({
  args: {
    teamSlugOrId: v.string(),
    conversationId: v.id("conversations"),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);

    // Verify conversation belongs to team
    const conversation = await ctx.db.get(args.conversationId);
    if (!conversation || conversation.teamId !== teamId) {
      throw new Error("Conversation not found");
    }

    const limit = args.limit ?? 100;
    return await ctx.db
      .query("conversationMessages")
      .withIndex("by_conversation", (q) =>
        q.eq("conversationId", args.conversationId)
      )
      .order("asc")
      .take(limit);
  },
});

// Get latest message for a conversation
export const getLatest = internalQuery({
  args: {
    conversationId: v.id("conversations"),
  },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("conversationMessages")
      .withIndex("by_conversation", (q) =>
        q.eq("conversationId", args.conversationId)
      )
      .order("desc")
      .first();
  },
});

// Get message count for a conversation
export const count = internalQuery({
  args: {
    conversationId: v.id("conversations"),
  },
  handler: async (ctx, args) => {
    const messages = await ctx.db
      .query("conversationMessages")
      .withIndex("by_conversation", (q) =>
        q.eq("conversationId", args.conversationId)
      )
      .collect();
    return messages.length;
  },
});
