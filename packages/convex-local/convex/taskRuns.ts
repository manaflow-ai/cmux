import { v } from "convex/values";
import type { Doc } from "./_generated/dataModel";
import {
  internalMutation,
  internalQuery,
  mutation,
  query,
} from "./_generated/server";

// Create a new task run
export const create = mutation({
  args: {
    taskId: v.id("tasks"),
    parentRunId: v.optional(v.id("taskRuns")),
    prompt: v.string(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const taskRunId = await ctx.db.insert("taskRuns", {
      taskId: args.taskId,
      parentRunId: args.parentRunId,
      prompt: args.prompt,
      status: "pending",
      log: "",
      createdAt: now,
      updatedAt: now,
    });
    return taskRunId;
  },
});

// Get all task runs for a task, organized in tree structure
export const getByTask = query({
  args: { taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    const runs = await ctx.db
      .query("taskRuns")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .collect();

    // Build tree structure
    type TaskRunWithChildren = Doc<"taskRuns"> & {
      children: TaskRunWithChildren[];
    };
    const runMap = new Map<string, TaskRunWithChildren>();
    const rootRuns: TaskRunWithChildren[] = [];

    // First pass: create map with children arrays
    runs.forEach((run) => {
      runMap.set(run._id, { ...run, children: [] });
    });

    // Second pass: build tree
    runs.forEach((run) => {
      const runWithChildren = runMap.get(run._id)!;
      if (run.parentRunId) {
        const parent = runMap.get(run.parentRunId);
        if (parent) {
          parent.children.push(runWithChildren);
        }
      } else {
        rootRuns.push(runWithChildren);
      }
    });

    // Sort by creation date
    const sortRuns = (runs: TaskRunWithChildren[]) => {
      runs.sort((a, b) => a.createdAt - b.createdAt);
      runs.forEach((run) => sortRuns(run.children));
    };
    sortRuns(rootRuns);

    return rootRuns;
  },
});

// Update task run status
export const updateStatus = internalMutation({
  args: {
    id: v.id("taskRuns"),
    status: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed")
    ),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const updates: {
      status: typeof args.status;
      updatedAt: number;
      completedAt?: number;
      exitCode?: number;
    } = {
      status: args.status,
      updatedAt: now,
    };

    if (args.status === "completed" || args.status === "failed") {
      updates.completedAt = now;
      if (args.exitCode !== undefined) {
        updates.exitCode = args.exitCode;
      }
    }

    await ctx.db.patch(args.id, updates);
  },
});

// Append to task run log
export const appendLog = internalMutation({
  args: {
    id: v.id("taskRuns"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run) {
      throw new Error("Task run not found");
    }

    console.log(
      `[appendLog] Adding ${args.content.length} chars to task run ${args.id}`
    );

    await ctx.db.patch(args.id, {
      log: run.log + args.content,
      updatedAt: Date.now(),
    });
  },
});

// Update task run summary
export const updateSummary = mutation({
  args: {
    id: v.id("taskRuns"),
    summary: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      summary: args.summary,
      updatedAt: Date.now(),
    });
  },
});

// Get a single task run
export const get = query({
  args: { id: v.id("taskRuns") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

// Subscribe to task run updates
export const subscribe = query({
  args: { id: v.id("taskRuns") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

// Internal mutation to update exit code
export const updateExitCode = internalMutation({
  args: {
    id: v.id("taskRuns"),
    exitCode: v.number(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      exitCode: args.exitCode,
      updatedAt: Date.now(),
    });
  },
});

// Update worktree path for a task run
export const updateWorktreePath = mutation({
  args: {
    id: v.id("taskRuns"),
    worktreePath: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      worktreePath: args.worktreePath,
      updatedAt: Date.now(),
    });
  },
});

// Internal query to get a task run by ID
export const getById = internalQuery({
  args: { id: v.id("taskRuns") },
  handler: async (ctx, args) => {
    return await ctx.db.get(args.id);
  },
});

export const updateStatusPublic = mutation({
  args: {
    id: v.id("taskRuns"),
    status: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed")
    ),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const updates: {
      status: typeof args.status;
      updatedAt: number;
      completedAt?: number;
      exitCode?: number;
    } = {
      status: args.status,
      updatedAt: now,
    };

    if (args.status === "completed" || args.status === "failed") {
      updates.completedAt = now;
      if (args.exitCode !== undefined) {
        updates.exitCode = args.exitCode;
      }
    }

    await ctx.db.patch(args.id, updates);
  },
});

export const appendLogPublic = mutation({
  args: {
    id: v.id("taskRuns"),
    content: v.string(),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run) {
      throw new Error("Task run not found");
    }

    console.log(
      `[appendLog] Adding ${args.content.length} chars to task run ${args.id}`
    );

    await ctx.db.patch(args.id, {
      log: run.log + args.content,
      updatedAt: Date.now(),
    });
  },
});

// Update VSCode instance information
export const updateVSCodeInstance = mutation({
  args: {
    id: v.id("taskRuns"),
    vscode: v.object({
      provider: v.union(
        v.literal("docker"),
        v.literal("morph"),
        v.literal("daytona"),
        v.literal("other")
      ),
      containerName: v.optional(v.string()),
      status: v.union(
        v.literal("starting"),
        v.literal("running"),
        v.literal("stopped")
      ),
      ports: v.optional(
        v.object({
          vscode: v.string(),
          worker: v.string(),
          extension: v.optional(v.string()),
        })
      ),
      url: v.optional(v.string()),
      workspaceUrl: v.optional(v.string()),
      startedAt: v.optional(v.number()),
      stoppedAt: v.optional(v.number()),
    }),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      vscode: args.vscode,
      updatedAt: Date.now(),
    });
  },
});

// Update VSCode instance status
export const updateVSCodeStatus = mutation({
  args: {
    id: v.id("taskRuns"),
    status: v.union(
      v.literal("starting"),
      v.literal("running"),
      v.literal("stopped")
    ),
    stoppedAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run) {
      throw new Error("Task run not found");
    }

    const vscode = run.vscode || {
      provider: "docker" as const,
      status: "starting" as const,
    };

    await ctx.db.patch(args.id, {
      vscode: {
        ...vscode,
        status: args.status,
        ...(args.stoppedAt ? { stoppedAt: args.stoppedAt } : {}),
      },
      updatedAt: Date.now(),
    });
  },
});

// Update VSCode instance ports
export const updateVSCodePorts = mutation({
  args: {
    id: v.id("taskRuns"),
    ports: v.object({
      vscode: v.string(),
      worker: v.string(),
      extension: v.optional(v.string()),
    }),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run) {
      throw new Error("Task run not found");
    }

    const vscode = run.vscode || {
      provider: "docker" as const,
      status: "starting" as const,
    };

    await ctx.db.patch(args.id, {
      vscode: {
        ...vscode,
        ports: args.ports,
      },
      updatedAt: Date.now(),
    });
  },
});

// Get task run by VSCode container name
export const getByContainerName = query({
  args: { containerName: v.string() },
  handler: async (ctx, args) => {
    const runs = await ctx.db
      .query("taskRuns")
      .withIndex("by_vscode_container_name", (q) =>
        q.eq("vscode.containerName", args.containerName)
      )
      .collect();
    return runs.find((run) => run.vscode?.containerName === args.containerName);
  },
});

// Complete a task run
export const complete = mutation({
  args: {
    id: v.id("taskRuns"),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    await ctx.db.patch(args.id, {
      status: "completed",
      exitCode: args.exitCode ?? 0,
      completedAt: now,
      updatedAt: now,
    });
  },
});

// Mark a task run as failed with an error message
export const fail = mutation({
  args: {
    id: v.id("taskRuns"),
    errorMessage: v.string(),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    await ctx.db.patch(args.id, {
      status: "failed",
      errorMessage: args.errorMessage,
      exitCode: args.exitCode ?? 1,
      completedAt: now,
      updatedAt: now,
    });
  },
});

// Get all active VSCode instances
export const getActiveVSCodeInstances = query({
  handler: async (ctx) => {
    const runs = await ctx.db
      .query("taskRuns")
      .withIndex("by_vscode_status", (q) => q.eq("vscode.status", "running"))
      .collect();
    return runs.filter(
      (run) =>
        run.vscode &&
        (run.vscode.status === "starting" || run.vscode.status === "running")
    );
  },
});

// Update last accessed time for a container
export const updateLastAccessed = mutation({
  args: {
    id: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run || !run.vscode) {
      throw new Error("Task run or VSCode instance not found");
    }

    await ctx.db.patch(args.id, {
      vscode: {
        ...run.vscode,
        lastAccessedAt: Date.now(),
      },
      updatedAt: Date.now(),
    });
  },
});

// Toggle keep alive status for a container
export const toggleKeepAlive = mutation({
  args: {
    id: v.id("taskRuns"),
    keepAlive: v.boolean(),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run || !run.vscode) {
      throw new Error("Task run or VSCode instance not found");
    }

    await ctx.db.patch(args.id, {
      vscode: {
        ...run.vscode,
        keepAlive: args.keepAlive,
        scheduledStopAt: args.keepAlive
          ? undefined
          : run.vscode.scheduledStopAt,
      },
      updatedAt: Date.now(),
    });
  },
});

// Update scheduled stop time for a container
export const updateScheduledStop = mutation({
  args: {
    id: v.id("taskRuns"),
    scheduledStopAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.id);
    if (!run || !run.vscode) {
      throw new Error("Task run or VSCode instance not found");
    }

    await ctx.db.patch(args.id, {
      vscode: {
        ...run.vscode,
        scheduledStopAt: args.scheduledStopAt,
      },
      updatedAt: Date.now(),
    });
  },
});

// Update pull request URL for a task run
export const updatePullRequestUrl = mutation({
  args: {
    id: v.id("taskRuns"),
    pullRequestUrl: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      pullRequestUrl: args.pullRequestUrl,
      updatedAt: Date.now(),
    });
  },
});

// Get containers that should be stopped based on TTL and settings
export const getContainersToStop = query({
  handler: async (ctx) => {
    const settings = await ctx.db.query("containerSettings").first();
    const autoCleanupEnabled = settings?.autoCleanupEnabled ?? true;
    const minContainersToKeep = settings?.minContainersToKeep ?? 0;

    if (!autoCleanupEnabled) {
      return [];
    }

    const now = Date.now();
    const activeRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_vscode_status", (q) => q.eq("vscode.status", "running"))
      .collect();

    const runningContainers = activeRuns.filter(
      (run) =>
        run.vscode && run.vscode.status === "running" && !run.vscode.keepAlive // Don't stop containers marked as keep alive
    );

    // Sort containers by creation time (newest first) to identify which to keep
    const sortedContainers = [...runningContainers].sort((a, b) => 
      (b.createdAt || 0) - (a.createdAt || 0)
    );
    
    // Get IDs of the most recent N containers to keep
    const containersToKeepIds = new Set(
      sortedContainers.slice(0, minContainersToKeep).map(c => c._id)
    );

    // Filter containers that have exceeded their scheduled stop time AND are not in the keep set
    const containersToStop = runningContainers.filter(
      (run) => 
        run.vscode!.scheduledStopAt && 
        run.vscode!.scheduledStopAt <= now &&
        !containersToKeepIds.has(run._id)
    );

    return containersToStop;
  },
});

// Get running containers sorted by priority for cleanup
export const getRunningContainersByCleanupPriority = query({
  handler: async (ctx) => {
    const settings = await ctx.db.query("containerSettings").first();
    const minContainersToKeep = settings?.minContainersToKeep ?? 0;
    
    const activeRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_vscode_status", (q) => q.eq("vscode.status", "running"))
      .collect();

    const runningContainers = activeRuns.filter(
      (run) =>
        run.vscode && run.vscode.status === "running" && !run.vscode.keepAlive // Don't include keep-alive containers in cleanup consideration
    );

    // Sort all containers by creation time to identify which to keep
    const sortedByCreation = [...runningContainers].sort((a, b) => 
      (b.createdAt || 0) - (a.createdAt || 0)
    );
    
    // Get IDs of the most recent N containers to keep
    const containersToKeepIds = new Set(
      sortedByCreation.slice(0, minContainersToKeep).map(c => c._id)
    );

    // Filter out containers that should be kept
    const eligibleForCleanup = runningContainers.filter(
      c => !containersToKeepIds.has(c._id)
    );

    // Categorize eligible containers
    const now = Date.now();
    const activeContainers: typeof eligibleForCleanup = [];
    const reviewContainers: typeof eligibleForCleanup = [];

    for (const container of eligibleForCleanup) {
      // If task is still running or was recently completed (within 5 minutes)
      if (
        container.status === "running" ||
        container.status === "pending" ||
        (container.completedAt && now - container.completedAt < 5 * 60 * 1000)
      ) {
        activeContainers.push(container);
      } else {
        reviewContainers.push(container);
      }
    }

    // Sort review containers by scheduled stop time (earliest first)
    reviewContainers.sort((a, b) => {
      const aTime = a.vscode!.scheduledStopAt || Infinity;
      const bTime = b.vscode!.scheduledStopAt || Infinity;
      return aTime - bTime;
    });

    // Return containers in cleanup priority order:
    // 1. Review period containers (oldest scheduled first)
    // 2. Active containers (only if absolutely necessary)
    return {
      total: runningContainers.length,
      reviewContainers,
      activeContainers,
      prioritizedForCleanup: [...reviewContainers, ...activeContainers],
      protectedCount: containersToKeepIds.size,
    };
  },
});
