import { v } from "convex/values";
import { mutation, query } from "./_generated/server.js";

export const appendChunk = mutation({
  args: {
    taskRunId: v.id("taskRuns"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.insert("taskRunLogChunks", {
      taskRunId: args.taskRunId,
      content: args.content,
    });
  },
});

export const appendChunkPublic = mutation({
  args: {
    taskRunId: v.id("taskRuns"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.insert("taskRunLogChunks", {
      taskRunId: args.taskRunId,
      content: args.content,
    });
  },
});

export const getChunks = query({
  args: {
    taskRunId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const chunks = await ctx.db
      .query("taskRunLogChunks")
      .withIndex("by_taskRun", (q) => q.eq("taskRunId", args.taskRunId))
      .collect();
    
    return chunks;
  },
});

