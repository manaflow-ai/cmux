import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

export const createComment = authMutation({
  args: {
    teamSlugOrId: v.string(),
    url: v.string(),
    page: v.string(),
    pageTitle: v.string(),
    nodeId: v.string(),
    x: v.number(),
    y: v.number(),
    content: v.string(),
    profileImageUrl: v.optional(v.string()),
    userAgent: v.string(),
    screenWidth: v.number(),
    screenHeight: v.number(),
    devicePixelRatio: v.number(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const commentId = await ctx.db.insert("comments", {
      url: args.url,
      page: args.page,
      pageTitle: args.pageTitle,
      nodeId: args.nodeId,
      x: args.x,
      y: args.y,
      content: args.content,
      userId,
      teamId,
      profileImageUrl: args.profileImageUrl,
      userAgent: args.userAgent,
      screenWidth: args.screenWidth,
      screenHeight: args.screenHeight,
      devicePixelRatio: args.devicePixelRatio,
      resolved: false,
      archived: false,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
    return commentId;
  },
});

export const listComments = authQuery({
  args: {
    teamSlugOrId: v.string(),
    url: v.string(),
    page: v.optional(v.string()),
    resolved: v.optional(v.boolean()),
    includeArchived: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const comments = await ctx.db
      .query("comments")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .collect();

    const filtered = comments.filter((comment) => {
      if (comment.url !== args.url) return false;
      if (args.page !== undefined && comment.page !== args.page) return false;
      if (args.resolved !== undefined && comment.resolved !== args.resolved)
        return false;
      if (!args.includeArchived && comment.archived === true) return false;
      return true;
    });

    return filtered;
  },
});

export const resolveComment = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("comments"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const comment = await ctx.db.get(args.commentId);
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (!comment || comment.teamId !== teamId || comment.userId !== userId) {
      throw new Error("Comment not found or unauthorized");
    }
    await ctx.db.patch(args.commentId, {
      resolved: true,
      updatedAt: Date.now(),
    });
  },
});

export const archiveComment = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("comments"),
    archived: v.boolean(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const comment = await ctx.db.get(args.commentId);
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (!comment || comment.teamId !== teamId || comment.userId !== userId) {
      throw new Error("Comment not found or unauthorized");
    }
    await ctx.db.patch(args.commentId, {
      archived: args.archived,
      updatedAt: Date.now(),
    });
  },
});

export const addReply = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("comments"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const comment = await ctx.db.get(args.commentId);
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (!comment || comment.teamId !== teamId || comment.userId !== userId) {
      throw new Error("Comment not found or unauthorized");
    }
    const replyId = await ctx.db.insert("commentReplies", {
      commentId: args.commentId,
      userId,
      teamId,
      content: args.content,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    });
    return replyId;
  },
});

export const getReplies = authQuery({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("comments"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const replies = await ctx.db
      .query("commentReplies")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .filter((q) => q.eq(q.field("commentId"), args.commentId))
      .collect();
    return replies;
  },
});
