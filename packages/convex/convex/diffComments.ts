import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

// Create a new diff comment
export const create = authMutation({
  args: {
    teamSlugOrId: v.string(),
    taskRunId: v.id("taskRuns"),
    filePath: v.string(),
    lineNumber: v.number(),
    side: v.union(v.literal("left"), v.literal("right")),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    // Verify the task run exists and belongs to this team/user
    const taskRun = await ctx.db.get(args.taskRunId);
    if (!taskRun || taskRun.teamId !== teamId) {
      throw new Error("Task run not found or unauthorized");
    }

    const now = Date.now();
    const commentId = await ctx.db.insert("diffComments", {
      taskRunId: args.taskRunId,
      filePath: args.filePath,
      lineNumber: args.lineNumber,
      side: args.side,
      content: args.content,
      resolved: false,
      userId,
      teamId,
      createdAt: now,
      updatedAt: now,
    });

    return commentId;
  },
});

// List all comments for a task run
export const listByTaskRun = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    // Verify the task run exists and belongs to this team
    const taskRun = await ctx.db.get(args.taskRunId);
    if (!taskRun || taskRun.teamId !== teamId) {
      throw new Error("Task run not found or unauthorized");
    }

    const comments = await ctx.db
      .query("diffComments")
      .withIndex("by_taskRun", (q) => q.eq("taskRunId", args.taskRunId))
      .collect();

    // Fetch user info for each comment
    const userIds = [...new Set(comments.map((c) => c.userId))];
    const users = await Promise.all(
      userIds.map(async (uid) => {
        const user = await ctx.db
          .query("users")
          .withIndex("by_userId", (q) => q.eq("userId", uid))
          .first();
        return user ? { id: uid, displayName: user.displayName, profileImageUrl: user.profileImageUrl } : null;
      })
    );
    const userMap = new Map(users.filter(Boolean).map((u) => [u!.id, u]));

    // Fetch replies for each comment
    const commentsWithReplies = await Promise.all(
      comments.map(async (comment) => {
        const replies = await ctx.db
          .query("diffCommentReplies")
          .withIndex("by_comment", (q) => q.eq("commentId", comment._id))
          .collect();

        // Fetch user info for replies
        const replyUserIds = [...new Set(replies.map((r) => r.userId))];
        for (const uid of replyUserIds) {
          if (!userMap.has(uid)) {
            const user = await ctx.db
              .query("users")
              .withIndex("by_userId", (q) => q.eq("userId", uid))
              .first();
            if (user) {
              userMap.set(uid, { id: uid, displayName: user.displayName, profileImageUrl: user.profileImageUrl });
            }
          }
        }

        return {
          ...comment,
          user: userMap.get(comment.userId) ?? null,
          replies: replies.map((reply) => ({
            ...reply,
            user: userMap.get(reply.userId) ?? null,
          })),
        };
      })
    );

    return commentsWithReplies.sort((a, b) => a.createdAt - b.createdAt);
  },
});

// List comments for a specific file in a task run
export const listByFile = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskRunId: v.id("taskRuns"),
    filePath: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const taskRun = await ctx.db.get(args.taskRunId);
    if (!taskRun || taskRun.teamId !== teamId) {
      throw new Error("Task run not found or unauthorized");
    }

    const comments = await ctx.db
      .query("diffComments")
      .withIndex("by_taskRun_file", (q) =>
        q.eq("taskRunId", args.taskRunId).eq("filePath", args.filePath)
      )
      .collect();

    return comments.sort((a, b) => a.createdAt - b.createdAt);
  },
});

// Update a comment
export const update = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("diffComments"),
    content: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const comment = await ctx.db.get(args.commentId);
    if (!comment || comment.teamId !== teamId || comment.userId !== userId) {
      throw new Error("Comment not found or unauthorized");
    }

    await ctx.db.patch(args.commentId, {
      ...(args.content !== undefined && { content: args.content }),
      updatedAt: Date.now(),
    });
  },
});

// Delete a comment (and its replies)
export const remove = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("diffComments"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const comment = await ctx.db.get(args.commentId);
    if (!comment || comment.teamId !== teamId || comment.userId !== userId) {
      throw new Error("Comment not found or unauthorized");
    }

    // Delete all replies first
    const replies = await ctx.db
      .query("diffCommentReplies")
      .withIndex("by_comment", (q) => q.eq("commentId", args.commentId))
      .collect();

    for (const reply of replies) {
      await ctx.db.delete(reply._id);
    }

    // Delete the comment
    await ctx.db.delete(args.commentId);
  },
});

// Resolve/unresolve a comment thread
export const setResolved = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("diffComments"),
    resolved: v.boolean(),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const comment = await ctx.db.get(args.commentId);
    if (!comment || comment.teamId !== teamId) {
      throw new Error("Comment not found or unauthorized");
    }

    await ctx.db.patch(args.commentId, {
      resolved: args.resolved,
      updatedAt: Date.now(),
    });
  },
});

// Add a reply to a comment
export const addReply = authMutation({
  args: {
    teamSlugOrId: v.string(),
    commentId: v.id("diffComments"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const comment = await ctx.db.get(args.commentId);
    if (!comment || comment.teamId !== teamId) {
      throw new Error("Comment not found or unauthorized");
    }

    const now = Date.now();
    const replyId = await ctx.db.insert("diffCommentReplies", {
      commentId: args.commentId,
      content: args.content,
      userId,
      teamId,
      createdAt: now,
      updatedAt: now,
    });

    return replyId;
  },
});

// Update a reply
export const updateReply = authMutation({
  args: {
    teamSlugOrId: v.string(),
    replyId: v.id("diffCommentReplies"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const reply = await ctx.db.get(args.replyId);
    if (!reply || reply.teamId !== teamId || reply.userId !== userId) {
      throw new Error("Reply not found or unauthorized");
    }

    await ctx.db.patch(args.replyId, {
      content: args.content,
      updatedAt: Date.now(),
    });
  },
});

// Delete a reply
export const removeReply = authMutation({
  args: {
    teamSlugOrId: v.string(),
    replyId: v.id("diffCommentReplies"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const reply = await ctx.db.get(args.replyId);
    if (!reply || reply.teamId !== teamId || reply.userId !== userId) {
      throw new Error("Reply not found or unauthorized");
    }

    await ctx.db.delete(args.replyId);
  },
});

// Get comment count per file for a task run
export const getFileCommentCounts = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const taskRun = await ctx.db.get(args.taskRunId);
    if (!taskRun || taskRun.teamId !== teamId) {
      throw new Error("Task run not found or unauthorized");
    }

    const comments = await ctx.db
      .query("diffComments")
      .withIndex("by_taskRun", (q) => q.eq("taskRunId", args.taskRunId))
      .collect();

    const counts: Record<string, { total: number; unresolved: number }> = {};
    for (const comment of comments) {
      if (!counts[comment.filePath]) {
        counts[comment.filePath] = { total: 0, unresolved: 0 };
      }
      counts[comment.filePath].total += 1;
      if (!comment.resolved) {
        counts[comment.filePath].unresolved += 1;
      }
    }

    return counts;
  },
});
