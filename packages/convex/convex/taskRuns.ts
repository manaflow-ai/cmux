import { v } from "convex/values";
import { SignJWT } from "jose";
import { env } from "../_shared/convex-env";
import { resolveTeamIdLoose } from "../_shared/team";
import type { Doc, Id } from "./_generated/dataModel";
import {
  internalMutation,
  internalQuery,
  type MutationCtx,
  type QueryCtx,
} from "./_generated/server";
import { authMutation, authQuery, taskIdWithFake } from "./users/utils";
import {
  aggregatePullRequestState,
  type StoredPullRequestInfo,
} from "@cmux/shared/pull-request-state";

function rewriteMorphUrl(url: string): string {
  // do not rewrite ports 39375 39376 39377 39378 39379 39380 39381
  if (
    url.includes("http.cloud.morph.so") &&
    (url.startsWith("https://port-39375-") ||
      url.startsWith("https://port-39376-") ||
      url.startsWith("https://port-39377-") ||
      url.startsWith("https://port-39378-") ||
      url.startsWith("https://port-39379-") ||
      url.startsWith("https://port-39380-") ||
      url.startsWith("https://port-39381-"))
  ) {
    return url;
  }

  // Transform morph URLs to cmux.app format
  // https://port-8101-morphvm-jrtutqa3.http.cloud.morph.so/handler/sign-in -> https://cmux-jrtutqa3-base-8101.cmux.app/handler/sign-in
  if (url.includes("http.cloud.morph.so")) {
    // Extract port and morphId from the URL
    const match = url.match(/port-(\d+)-morphvm-([^.]+)\.http\.cloud\.morph\.so/);
    if (match) {
      const [fullMatch, port, morphId] = match;
      const scope = "base";
      const result = url.replace(
        fullMatch,
        `cmux-${morphId}-${scope}-${port}.cmux.app`
      );
      return result;
    }
  }
  return url;
}

function normalizePullRequestRecords(
  records: readonly StoredPullRequestInfo[] | undefined,
): StoredPullRequestInfo[] | undefined {
  if (!records) {
    return undefined;
  }
  return records.map((record) => ({
    repoFullName: record.repoFullName.trim(),
    url: record.url,
    number: record.number,
    state: record.state,
    isDraft:
      record.isDraft !== undefined
        ? record.isDraft
        : record.state === "draft"
          ? true
          : undefined,
  }));
}

function deriveGeneratedBranchName(branch?: string | null): string | undefined {
  if (!branch) return undefined;
  const trimmed = branch.trim();
  if (!trimmed) return undefined;
  const idx = trimmed.lastIndexOf("-");
  if (idx <= 0) return trimmed;
  const candidate = trimmed.slice(0, idx);
  return candidate || trimmed;
}

type EnvironmentErrorPayload = {
  maintenanceError?: string;
  devError?: string;
};

const MAX_ENVIRONMENT_ERROR_MESSAGE_CHARS = 2500;

function normalizeEnvironmentErrorPayload(
  maintenanceError?: string,
  devError?: string,
): EnvironmentErrorPayload {
  const truncate = (msg?: string) => {
    if (!msg) return undefined;
    const trimmed = msg.trim();
    if (!trimmed) return undefined;
    return trimmed.length > MAX_ENVIRONMENT_ERROR_MESSAGE_CHARS
      ? `${trimmed.slice(0, MAX_ENVIRONMENT_ERROR_MESSAGE_CHARS)}…`
      : trimmed;
  };

  const normalizedMaintenance = truncate(maintenanceError);
  const normalizedDev = truncate(devError);

  const payload: EnvironmentErrorPayload = {};
  if (normalizedMaintenance) {
    payload.maintenanceError = normalizedMaintenance;
  }
  if (normalizedDev) {
    payload.devError = normalizedDev;
  }
  return payload;
}

type EnvironmentSummary = Pick<
  Doc<"environments">,
  "_id" | "name" | "selectedRepos"
>;

type TaskRunWithChildren = Doc<"taskRuns"> & {
  children: TaskRunWithChildren[];
  environment: EnvironmentSummary | null;
};

async function collectRunSubtreeIds(
  ctx: MutationCtx,
  rootRunId: Id<"taskRuns">,
  teamId: string,
  userId: string,
): Promise<Id<"taskRuns">[]> {
  const visited = new Set<Id<"taskRuns">>();
  const stack: Id<"taskRuns">[] = [rootRunId];

  while (stack.length > 0) {
    const current = stack.pop()!;
    if (visited.has(current)) {
      continue;
    }
    visited.add(current);

    const children = await ctx.db
      .query("taskRuns")
      .withIndex("by_parent", (q) => q.eq("parentRunId", current))
      .collect();

    for (const child of children) {
      if (child.teamId !== teamId || child.userId !== userId) {
        continue;
      }
      stack.push(child._id);
    }
  }

  return Array.from(visited);
}

async function fetchTaskRunsForTask(
  ctx: QueryCtx,
  teamId: string,
  userId: string,
  taskId: Id<"tasks">,
  includeArchived = true,
): Promise<TaskRunWithChildren[]> {
  const runs = await ctx.db
    .query("taskRuns")
    .withIndex("by_task", (q) => q.eq("taskId", taskId))
    .filter(
      (q) => q.eq(q.field("teamId"), teamId) && q.eq(q.field("userId"), userId),
    )
    .collect();

  const environmentSummaries = new Map<
    Id<"environments">,
    EnvironmentSummary
  >();
  const environmentIds = Array.from(
    new Set(
      runs
        .map((run) => run.environmentId)
        .filter((id): id is Id<"environments"> => id !== undefined),
    ),
  );

  if (environmentIds.length > 0) {
    const environmentDocs = await Promise.all(
      environmentIds.map((environmentId) => ctx.db.get(environmentId)),
    );

    for (const environment of environmentDocs) {
      if (!environment || environment.teamId !== teamId) continue;
      environmentSummaries.set(environment._id, {
        _id: environment._id,
        name: environment.name,
        selectedRepos: environment.selectedRepos,
      });
    }
  }

  const runMap = new Map<string, TaskRunWithChildren>();
  const rootRuns: TaskRunWithChildren[] = [];

  runs.forEach((run) => {
    if (!includeArchived && run.isArchived) {
      return;
    }
    const networking = run.networking?.map((item) => ({
      ...item,
      url: rewriteMorphUrl(item.url),
    }));

    runMap.set(run._id, {
      ...run,
      log: "",
      networking,
      children: [],
      environment: run.environmentId
        ? (environmentSummaries.get(run.environmentId) ?? null)
        : null,
    });
  });

  runs.forEach((run) => {
    if (!includeArchived && run.isArchived) {
      return;
    }
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

  const sortRuns = (items: TaskRunWithChildren[]) => {
    items.sort((a, b) => {
      // Sort crowned runs first, then by creation time
      if (a.isCrowned && !b.isCrowned) return -1;
      if (!a.isCrowned && b.isCrowned) return 1;
      return a.createdAt - b.createdAt;
    });
    items.forEach((item) => sortRuns(item.children));
  };
  sortRuns(rootRuns);

  return rootRuns;
}

// Create a new task run
export const create = authMutation({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
    parentRunId: v.optional(v.id("taskRuns")),
    prompt: v.string(),
    agentName: v.optional(v.string()),
    newBranch: v.optional(v.string()),
    environmentId: v.optional(v.id("environments")),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const now = Date.now();
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const task = await ctx.db.get(args.taskId);
    if (!task || task.teamId !== teamId || task.userId !== userId) {
      throw new Error("Task not found or unauthorized");
    }
    if (args.environmentId) {
      const environment = await ctx.db.get(args.environmentId);
      if (!environment || environment.teamId !== teamId) {
        throw new Error("Environment not found");
      }
    }
    const taskRunId = await ctx.db.insert("taskRuns", {
      taskId: args.taskId,
      parentRunId: args.parentRunId,
      prompt: args.prompt,
      agentName: args.agentName,
      newBranch: args.newBranch,
      status: "pending",
      createdAt: now,
      updatedAt: now,
      userId,
      teamId,
      environmentId: args.environmentId,
      isLocalWorkspace: task.isLocalWorkspace,
      isCloudWorkspace: task.isCloudWorkspace,
    });
    const generatedBranchName = deriveGeneratedBranchName(args.newBranch);
    if (
      generatedBranchName &&
      task.generatedBranchName !== generatedBranchName
    ) {
      await ctx.db.patch(args.taskId, {
        generatedBranchName,
      });
    }
    const jwt = await new SignJWT({
      taskRunId,
      teamId,
      userId,
    })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuedAt()
      .setExpirationTime("12h")
      .sign(new TextEncoder().encode(env.CMUX_TASK_RUN_JWT_SECRET));

    return { taskRunId, jwt };
  },
});

// Get all task runs for a task, organized in tree structure
export const getByTask = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskId: taskIdWithFake,
    includeArchived: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    if (typeof args.taskId === "string" && args.taskId.startsWith("fake-")) {
      return [];
    }

    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    return await fetchTaskRunsForTask(
      ctx,
      teamId,
      userId,
      args.taskId as Id<"tasks">,
      args.includeArchived ?? true,
    );
  },
});

const SYSTEM_BRANCH_USER_ID = "__system__";

async function fetchBranchMetadataForRepo(
  ctx: QueryCtx,
  teamId: string,
  userId: string,
  repo: string,
): Promise<Doc<"branches">[]> {
  const rows = await ctx.db
    .query("branches")
    .withIndex("by_repo", (q) => q.eq("repo", repo))
    .filter((q) => q.eq(q.field("teamId"), teamId))
    .collect();

  const relevant = rows.filter(
    (row) => row.userId === userId || row.userId === SYSTEM_BRANCH_USER_ID,
  );

  const byName = new Map<string, Doc<"branches">>();
  for (const row of relevant) {
    const existing = byName.get(row.name);
    if (!existing) {
      byName.set(row.name, row);
      continue;
    }

    const currentHasKnown = Boolean(
      row.lastKnownBaseSha || row.lastKnownMergeCommitSha,
    );
    const existingHasKnown = Boolean(
      existing.lastKnownBaseSha || existing.lastKnownMergeCommitSha,
    );

    if (currentHasKnown && !existingHasKnown) {
      byName.set(row.name, row);
      continue;
    }

    if (!currentHasKnown && existingHasKnown) {
      continue;
    }

    const currentActivity = row.lastActivityAt ?? -Infinity;
    const existingActivity = existing.lastActivityAt ?? -Infinity;
    if (currentActivity > existingActivity) {
      byName.set(row.name, row);
    }
  }

  return Array.from(byName.values());
}

// Update task run status
export const updateStatus = internalMutation({
  args: {
    id: v.id("taskRuns"),
    status: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed"),
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

export const getRunDiffContext = authQuery({
  args: {
    teamSlugOrId: v.string(),
    taskId: v.id("tasks"),
    runId: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const [taskDoc, taskRuns] = await Promise.all([
      ctx.db.get(args.taskId),
      fetchTaskRunsForTask(ctx, teamId, userId, args.taskId, true),
    ]);

    if (!taskDoc || taskDoc.teamId !== teamId || taskDoc.userId !== userId) {
      return {
        task: null,
        taskRuns,
        branchMetadataByRepo: {} as Record<string, Doc<"branches">[]>,
        screenshotSets: [],
      };
    }

    let taskWithImages = taskDoc;
    if (taskDoc.images && taskDoc.images.length > 0) {
      const imagesWithUrls = await Promise.all(
        taskDoc.images.map(async (image) => {
          const url = await ctx.storage.getUrl(image.storageId);
          return {
            ...image,
            url,
          };
        }),
      );
      taskWithImages = {
        ...taskDoc,
        images: imagesWithUrls,
      };
    }

    const trimmedProjectFullName = taskDoc.projectFullName?.trim();
    const branchMetadataByRepo: Record<string, Doc<"branches">[]> = {};

    if (trimmedProjectFullName) {
      try {
        const metadata = await fetchBranchMetadataForRepo(
          ctx,
          teamId,
          userId,
          trimmedProjectFullName,
        );
        if (metadata.length > 0) {
          branchMetadataByRepo[trimmedProjectFullName] = metadata;
        }
      } catch {
        // swallow errors – branch metadata is optional for diff prefetching
      }
    }

    const screenshotSets = await (async () => {
      const runDoc = await ctx.db.get(args.runId);
      // Prevent leaking screenshots for runs outside the authenticated task/team
      if (
        !runDoc ||
        runDoc.teamId !== teamId ||
        runDoc.taskId !== args.taskId
      ) {
        return [];
      }

      const screenshotSetDocs = await ctx.db
        .query("taskRunScreenshotSets")
        .withIndex("by_run_capturedAt", (q) => q.eq("runId", args.runId))
        .collect();

      screenshotSetDocs.sort((a, b) => b.capturedAt - a.capturedAt);

      const trimmedScreenshotSets = screenshotSetDocs.slice(0, 20);

      return Promise.all(
        trimmedScreenshotSets.map(async (set) => {
          const imagesWithUrls = await Promise.all(
            set.images.map(async (image) => {
              const url = await ctx.storage.getUrl(image.storageId);
              return {
                ...image,
                url: url ?? undefined,
              };
            }),
          );
          return {
            ...set,
            images: imagesWithUrls,
          };
        }),
      );
    })();

    return {
      task: taskWithImages,
      taskRuns,
      branchMetadataByRepo,
      screenshotSets,
    };
  },
});

// Update task run summary
export const updateSummary = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    summary: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
    await ctx.db.patch(args.id, {
      summary: args.summary,
      updatedAt: Date.now(),
    });
  },
});

// Get a single task run
export const get = authQuery({
  args: { teamSlugOrId: v.string(), id: v.id("taskRuns") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      return null;
    }
    // Rewrite morph URLs in networking field
    if (doc.networking) {
      return {
        ...doc,
        networking: doc.networking.map((item) => ({
          ...item,
          url: rewriteMorphUrl(item.url),
        })),
      };
    }
    return doc;
  },
});

// Subscribe to task run updates
export const subscribe = authQuery({
  args: { teamSlugOrId: v.string(), id: v.id("taskRuns") },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      return null;
    }
    // Rewrite morph URLs in networking field
    if (doc.networking) {
      return {
        ...doc,
        networking: doc.networking.map((item) => ({
          ...item,
          url: rewriteMorphUrl(item.url),
        })),
      };
    }
    return doc;
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

export const updateScreenshotMetadata = internalMutation({
  args: {
    id: v.id("taskRuns"),
    storageId: v.id("_storage"),
    mimeType: v.optional(v.string()),
    fileName: v.optional(v.string()),
    commitSha: v.optional(v.string()),
    screenshotSetId: v.optional(v.id("taskRunScreenshotSets")),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      screenshotStorageId: args.storageId,
      screenshotCapturedAt: Date.now(),
      screenshotMimeType: args.mimeType,
      screenshotFileName: args.fileName,
      screenshotCommitSha: args.commitSha,
      latestScreenshotSetId: args.screenshotSetId,
      updatedAt: Date.now(),
    });
  },
});

export const clearScreenshotMetadata = internalMutation({
  args: { id: v.id("taskRuns") },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.id, {
      screenshotStorageId: undefined,
      screenshotCapturedAt: undefined,
      screenshotMimeType: undefined,
      screenshotFileName: undefined,
      screenshotCommitSha: undefined,
      latestScreenshotSetId: undefined,
      updatedAt: Date.now(),
    });
  },
});

// Update worktree path for a task run
export const updateWorktreePath = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    worktreePath: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
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

export const updateStatusPublic = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    status: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed"),
    ),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const now = Date.now();
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
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

// Update VSCode instance information
export const updateVSCodeInstance = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    vscode: v.object({
      provider: v.union(
        v.literal("docker"),
        v.literal("morph"),
        v.literal("daytona"),
        v.literal("other"),
      ),
      containerName: v.optional(v.string()),
      status: v.union(
        v.literal("starting"),
        v.literal("running"),
        v.literal("stopped"),
      ),
      ports: v.optional(
        v.object({
          vscode: v.string(),
          worker: v.string(),
          extension: v.optional(v.string()),
          proxy: v.optional(v.string()),
          vnc: v.optional(v.string()),
        }),
      ),
      url: v.optional(v.string()),
      workspaceUrl: v.optional(v.string()),
      startedAt: v.optional(v.number()),
      stoppedAt: v.optional(v.number()),
    }),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
    await ctx.db.patch(args.id, {
      vscode: args.vscode,
      updatedAt: Date.now(),
    });
  },
});

// Update VSCode instance status
export const updateVSCodeStatus = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    status: v.union(
      v.literal("starting"),
      v.literal("running"),
      v.literal("stopped"),
    ),
    stoppedAt: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const run = await ctx.db.get(args.id);
    if (!run) {
      throw new Error("Task run not found");
    }
    if (run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Unauthorized");
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
export const updateVSCodePorts = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    ports: v.object({
      vscode: v.string(),
      worker: v.string(),
      extension: v.optional(v.string()),
      proxy: v.optional(v.string()),
      vnc: v.optional(v.string()),
    }),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const run = await ctx.db.get(args.id);
    if (!run) {
      throw new Error("Task run not found");
    }
    if (run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Unauthorized");
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
export const getByContainerName = authQuery({
  args: { teamSlugOrId: v.string(), containerName: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const run =
      (await ctx.db
        .query("taskRuns")
        .withIndex("by_vscode_container_name", (q) =>
          q.eq("vscode.containerName", args.containerName),
        )
        .filter((q) => q.eq(q.field("teamId"), teamId))
        .filter((q) => q.eq(q.field("userId"), userId))
        .first()) ?? null;

    if (!run) {
      return null;
    }

    if (run.networking) {
      return {
        ...run,
        networking: run.networking.map((item) => ({
          ...item,
          url: rewriteMorphUrl(item.url),
        })),
      };
    }

    return run;
  },
});

// Complete a task run
export const complete = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
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
export const fail = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    errorMessage: v.string(),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.id);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
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

export const addCustomPreview = authMutation({
  args: {
    teamSlugOrId: v.string(),
    runId: v.id("taskRuns"),
    url: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.runId);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }

    const newPreview = {
      url: args.url,
      createdAt: Date.now(),
    };

    const customPreviews = doc.customPreviews || [];
    const index = customPreviews.length;
    
    await ctx.db.patch(args.runId, {
      customPreviews: [...customPreviews, newPreview],
      updatedAt: Date.now(),
    });

    return index;
  },
});

export const removeCustomPreview = authMutation({
  args: {
    teamSlugOrId: v.string(),
    runId: v.id("taskRuns"),
    index: v.number(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.runId);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }

    const customPreviews = doc.customPreviews || [];
    const updated = customPreviews.filter((_, i) => i !== args.index);

    await ctx.db.patch(args.runId, {
      customPreviews: updated,
      updatedAt: Date.now(),
    });
  },
});

export const updateCustomPreviewUrl = authMutation({
  args: {
    teamSlugOrId: v.string(),
    runId: v.id("taskRuns"),
    index: v.number(),
    url: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const doc = await ctx.db.get(args.runId);
    if (!doc || doc.teamId !== teamId || doc.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }

    const customPreviews = doc.customPreviews || [];
    if (args.index < 0 || args.index >= customPreviews.length) {
      throw new Error("Invalid preview index");
    }

    const updated = customPreviews.map((preview, i) =>
      i === args.index
        ? { ...preview, url: args.url }
        : preview
    );

    await ctx.db.patch(args.runId, {
      customPreviews: updated,
      updatedAt: Date.now(),
    });
  },
});

export const listByTaskInternal = internalQuery({
  args: { taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    const runs = await ctx.db
      .query("taskRuns")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .collect();
    return runs;
  },
});

export const listByTaskAndTeamInternal = internalQuery({
  args: { taskId: v.id("tasks"), teamId: v.string(), userId: v.string() },
  handler: async (ctx, args) => {
    const runs = await ctx.db
      .query("taskRuns")
      .withIndex("by_task", (q) => q.eq("taskId", args.taskId))
      .filter(
        (q) =>
          q.eq(q.field("teamId"), args.teamId) &&
          q.eq(q.field("userId"), args.userId),
      )
      .collect();
    return runs;
  },
});

export const workerComplete = internalMutation({
  args: {
    taskRunId: v.id("taskRuns"),
    exitCode: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.taskRunId);
    if (!run) {
      throw new Error("Task run not found");
    }

    const now = Date.now();

    await ctx.db.patch(args.taskRunId, {
      status: "completed",
      exitCode: args.exitCode ?? 0,
      completedAt: now,
      updatedAt: now,
    });

    return run;
  },
});

// Get all active VSCode instances
export const getActiveVSCodeInstances = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const runs = await ctx.db
      .query("taskRuns")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .collect();
    return runs
      .filter(
        (run) =>
          run.vscode &&
          (run.vscode.status === "starting" || run.vscode.status === "running"),
      )
      .map((run) => {
        if (run.networking) {
          return {
            ...run,
            networking: run.networking.map((item) => ({
              ...item,
              url: rewriteMorphUrl(item.url),
            })),
          };
        }
        return run;
      });
  },
});

// Update last accessed time for a container
export const updateLastAccessed = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const run = await ctx.db.get(args.id);
    if (!run || !run.vscode) {
      throw new Error("Task run or VSCode instance not found");
    }
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Unauthorized");
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
export const toggleKeepAlive = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    keepAlive: v.boolean(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const run = await ctx.db.get(args.id);
    if (!run || !run.vscode) {
      throw new Error("Task run or VSCode instance not found");
    }
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Unauthorized");
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

export const updateVSCodeMetadataInternal = internalMutation({
  args: {
    taskRunId: v.id("taskRuns"),
    vscode: v.optional(
      v.object({
        provider: v.optional(
          v.union(
            v.literal("docker"),
            v.literal("morph"),
            v.literal("daytona"),
            v.literal("other"),
          ),
        ),
        containerName: v.optional(v.string()),
        status: v.optional(
          v.union(v.literal("starting"), v.literal("running"), v.literal("stopped")),
        ),
        ports: v.optional(
          v.object({
            vscode: v.string(),
            worker: v.string(),
            extension: v.optional(v.string()),
            proxy: v.optional(v.string()),
            vnc: v.optional(v.string()),
          }),
        ),
        url: v.optional(v.string()),
        workspaceUrl: v.optional(v.string()),
        startedAt: v.optional(v.number()),
        stoppedAt: v.optional(v.number()),
        lastAccessedAt: v.optional(v.number()),
        keepAlive: v.optional(v.boolean()),
        scheduledStopAt: v.optional(v.number()),
      }),
    ),
    networking: v.optional(
      v.array(
        v.object({
          status: v.union(
            v.literal("starting"),
            v.literal("running"),
            v.literal("stopped"),
          ),
          port: v.number(),
          url: v.string(),
        }),
      ),
    ),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.taskRunId);
    if (!run) {
      throw new Error("Task run not found");
    }

    const patch: Partial<Doc<"taskRuns">> = {
      updatedAt: Date.now(),
    };

    if (args.vscode) {
      const existing = run.vscode;
      const ensureField = <T>(value: T | undefined, existingValue: T | undefined, field: string): T => {
        if (value !== undefined) {
          return value;
        }
        if (existingValue !== undefined) {
          return existingValue;
        }
        throw new Error(`Missing required VSCode field: ${field}`);
      };

      const provider = ensureField(args.vscode.provider, existing?.provider, "provider");
      const status = ensureField(args.vscode.status, existing?.status, "status");

      patch.vscode = {
        ...existing,
        ...args.vscode,
        provider,
        status,
      };
    }

    if (args.networking !== undefined) {
      patch.networking = args.networking;
    }

    await ctx.db.patch(args.taskRunId, patch);
  },
});

export const updateScheduledStopInternal = internalMutation({
  args: {
    taskRunId: v.id("taskRuns"),
    scheduledStopAt: v.number(),
  },
  handler: async (ctx, args) => {
    const run = await ctx.db.get(args.taskRunId);
    if (!run || !run.vscode) {
      return;
    }

    await ctx.db.patch(args.taskRunId, {
      vscode: {
        ...run.vscode,
        scheduledStopAt: args.scheduledStopAt,
      },
      updatedAt: Date.now(),
    });
  },
});

// Update pull request URL for a task run
export const updatePullRequestUrl = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    pullRequestUrl: v.string(),
    isDraft: v.optional(v.boolean()),
    state: v.optional(
      v.union(
        v.literal("none"),
        v.literal("draft"),
        v.literal("open"),
        v.literal("merged"),
        v.literal("closed"),
        v.literal("unknown"),
      ),
    ),
    number: v.optional(v.number()),
    pullRequests: v.optional(
      v.array(
        v.object({
          repoFullName: v.string(),
          url: v.optional(v.string()),
          number: v.optional(v.number()),
          state: v.union(
            v.literal("none"),
            v.literal("draft"),
            v.literal("open"),
            v.literal("merged"),
            v.literal("closed"),
            v.literal("unknown"),
          ),
          isDraft: v.optional(v.boolean()),
        }),
      ),
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const run = await ctx.db.get(args.id);
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (!run || run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
    const updates: Partial<Doc<"taskRuns">> = {
      pullRequestUrl: args.pullRequestUrl,
      updatedAt: Date.now(),
    };
    if (args.isDraft !== undefined) {
      updates.pullRequestIsDraft = args.isDraft;
    }
    if (args.state) {
      updates.pullRequestState = args.state;
    }
    if (args.number !== undefined) {
      updates.pullRequestNumber = args.number;
    }
    const normalizedPullRequests = normalizePullRequestRecords(
      args.pullRequests,
    );
    if (normalizedPullRequests) {
      updates.pullRequests = normalizedPullRequests;
      const aggregate = aggregatePullRequestState(normalizedPullRequests);
      updates.pullRequestState = aggregate.state;
      updates.pullRequestIsDraft = aggregate.isDraft;
      updates.pullRequestUrl =
        aggregate.url !== undefined ? aggregate.url : updates.pullRequestUrl;
      updates.pullRequestNumber =
        aggregate.number !== undefined
          ? aggregate.number
          : updates.pullRequestNumber;
    }
    await ctx.db.patch(args.id, updates);
  },
});

export const updatePullRequestState = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    state: v.union(
      v.literal("none"),
      v.literal("draft"),
      v.literal("open"),
      v.literal("merged"),
      v.literal("closed"),
      v.literal("unknown"),
    ),
    isDraft: v.optional(v.boolean()),
    number: v.optional(v.number()),
    url: v.optional(v.string()),
    pullRequests: v.optional(
      v.array(
        v.object({
          repoFullName: v.string(),
          url: v.optional(v.string()),
          number: v.optional(v.number()),
          state: v.union(
            v.literal("none"),
            v.literal("draft"),
            v.literal("open"),
            v.literal("merged"),
            v.literal("closed"),
            v.literal("unknown"),
          ),
          isDraft: v.optional(v.boolean()),
        }),
      ),
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const run = await ctx.db.get(args.id);
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (!run || run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
    const updates: Partial<Doc<"taskRuns">> = {
      pullRequestState: args.state,
      updatedAt: Date.now(),
    };
    if (args.isDraft !== undefined) {
      updates.pullRequestIsDraft = args.isDraft;
    }
    if (args.number !== undefined) {
      updates.pullRequestNumber = args.number;
    }
    if (args.url !== undefined) {
      updates.pullRequestUrl = args.url;
    }
    const normalizedPullRequests = normalizePullRequestRecords(
      args.pullRequests,
    );
    if (normalizedPullRequests) {
      updates.pullRequests = normalizedPullRequests;
      const aggregate = aggregatePullRequestState(normalizedPullRequests);
      updates.pullRequestState = aggregate.state;
      updates.pullRequestIsDraft = aggregate.isDraft;
      updates.pullRequestUrl =
        aggregate.url !== undefined ? aggregate.url : updates.pullRequestUrl;
      updates.pullRequestNumber =
        aggregate.number !== undefined
          ? aggregate.number
          : updates.pullRequestNumber;
    }
    await ctx.db.patch(args.id, updates);
  },
});

// Update networking information for a task run
export const updateNetworking = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    networking: v.array(
      v.object({
        status: v.union(
          v.literal("starting"),
          v.literal("running"),
          v.literal("stopped"),
        ),
        port: v.number(),
        url: v.string(),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const run = await ctx.db.get(args.id);
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    if (!run || run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
    await ctx.db.patch(args.id, {
      networking: args.networking,
      updatedAt: Date.now(),
    });
  },
});

async function performUpdateEnvironmentError(
  ctx: MutationCtx,
  args: {
    id: Id<"taskRuns">;
    teamId: string;
    userId: string;
    maintenanceError?: string;
    devError?: string;
  },
) {
  const run = await ctx.db.get(args.id);

  if (!run) {
    throw new Error("Task run not found");
  }

  if (run.teamId !== args.teamId || run.userId !== args.userId) {
    throw new Error("Task run mismatch for provided credentials");
  }

  const environmentError = normalizeEnvironmentErrorPayload(
    args.maintenanceError,
    args.devError,
  );

  await ctx.db.patch(args.id, {
    environmentError,
    updatedAt: Date.now(),
  });
}

export const updateEnvironmentErrorFromWorker = internalMutation({
  args: {
    id: v.id("taskRuns"),
    teamId: v.string(),
    userId: v.string(),
    maintenanceError: v.optional(v.string()),
    devError: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    await performUpdateEnvironmentError(ctx, args);
  },
});

export const updateEnvironmentError = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    maintenanceError: v.optional(v.string()),
    devError: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    await performUpdateEnvironmentError(ctx, {
      id: args.id,
      teamId,
      userId,
      maintenanceError: args.maintenanceError,
      devError: args.devError,
    });
  },
});

export const archive = authMutation({
  args: {
    teamSlugOrId: v.string(),
    id: v.id("taskRuns"),
    archive: v.boolean(),
    includeChildren: v.optional(v.boolean()),
    taskId: v.optional(v.id("tasks")),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const run = await ctx.db.get(args.id);
    if (!run || run.teamId !== teamId || run.userId !== userId) {
      throw new Error("Task run not found or unauthorized");
    }
    if (args.taskId && run.taskId !== args.taskId) {
      throw new Error("Task run does not belong to provided task");
    }

    const targetIds = args.includeChildren
      ? await collectRunSubtreeIds(ctx, args.id, teamId, userId)
      : [args.id];

    await Promise.all(
      targetIds.map((runId) =>
        ctx.db.patch(runId, {
          isArchived: args.archive,
          updatedAt: Date.now(),
        }),
      ),
    );
  },
});

// Get containers that should be stopped based on TTL and settings
export const getContainersToStop = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("containerSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .first();
    const autoCleanupEnabled = settings?.autoCleanupEnabled ?? true;
    const minContainersToKeep = settings?.minContainersToKeep ?? 0;

    if (!autoCleanupEnabled) {
      return [];
    }

    const now = Date.now();
    const activeRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .collect();

    const runningContainers = activeRuns.filter(
      (run) =>
        run.vscode && run.vscode.status === "running" && !run.vscode.keepAlive, // Don't stop containers marked as keep alive
    );

    // Sort containers by creation time (newest first) to identify which to keep
    const sortedContainers = [...runningContainers].sort(
      (a, b) => (b.createdAt || 0) - (a.createdAt || 0),
    );

    // Get IDs of the most recent N containers to keep
    const containersToKeepIds = new Set(
      sortedContainers.slice(0, minContainersToKeep).map((c) => c._id),
    );

    // Filter containers that have exceeded their scheduled stop time AND are not in the keep set
    const containersToStop = runningContainers
      .filter(
        (run) =>
          run.vscode!.scheduledStopAt &&
          run.vscode!.scheduledStopAt <= now &&
          !containersToKeepIds.has(run._id),
      )
      .map((run) => {
        if (run.networking) {
          return {
            ...run,
            networking: run.networking.map((item) => ({
              ...item,
              url: rewriteMorphUrl(item.url),
            })),
          };
        }
        return run;
      });

    return containersToStop;
  },
});

// Get running containers sorted by priority for cleanup
export const getRunningContainersByCleanupPriority = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const settings = await ctx.db
      .query("containerSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .first();
    const minContainersToKeep = settings?.minContainersToKeep ?? 0;

    const activeRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .collect();

    const runningContainers = activeRuns.filter(
      (run) =>
        run.vscode && run.vscode.status === "running" && !run.vscode.keepAlive, // Don't include keep-alive containers in cleanup consideration
    );

    // Sort all containers by creation time to identify which to keep
    const sortedByCreation = [...runningContainers].sort(
      (a, b) => (b.createdAt || 0) - (a.createdAt || 0),
    );

    // Get IDs of the most recent N containers to keep
    const containersToKeepIds = new Set(
      sortedByCreation.slice(0, minContainersToKeep).map((c) => c._id),
    );

    // Filter out containers that should be kept
    const eligibleForCleanup = runningContainers.filter(
      (c) => !containersToKeepIds.has(c._id),
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

    // Helper to rewrite networking URLs
    const rewriteContainerNetworking = <
      T extends (typeof eligibleForCleanup)[number],
    >(
      container: T,
    ): T => {
      if (container.networking) {
        return {
          ...container,
          networking: container.networking.map((item) => ({
            ...item,
            url: rewriteMorphUrl(item.url),
          })),
        };
      }
      return container;
    };

    // Rewrite networking URLs in all containers
    const reviewContainersWithRewrittenUrls = reviewContainers.map(
      rewriteContainerNetworking,
    );
    const activeContainersWithRewrittenUrls = activeContainers.map(
      rewriteContainerNetworking,
    );

    // Return containers in cleanup priority order:
    // 1. Review period containers (oldest scheduled first)
    // 2. Active containers (only if absolutely necessary)
    return {
      total: runningContainers.length,
      reviewContainers: reviewContainersWithRewrittenUrls,
      activeContainers: activeContainersWithRewrittenUrls,
      prioritizedForCleanup: [
        ...reviewContainersWithRewrittenUrls,
        ...activeContainersWithRewrittenUrls,
      ],
      protectedCount: containersToKeepIds.size,
    };
  },
});

export const createForPreview = internalMutation({
  args: {
    taskId: v.id("tasks"),
    teamId: v.string(),
    userId: v.string(),
    prUrl: v.string(),
    environmentId: v.optional(v.id("environments")),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const task = await ctx.db.get(args.taskId);
    if (!task) {
      throw new Error("Task not found");
    }

    const taskRunId = await ctx.db.insert("taskRuns", {
      taskId: args.taskId,
      parentRunId: undefined,
      prompt: `Capture UI screenshots for ${args.prUrl}`,
      agentName: "screenshot-collector",
      newBranch: undefined,
      status: "pending",
      createdAt: now,
      updatedAt: now,
      userId: args.userId,
      teamId: args.teamId,
      environmentId: args.environmentId,
      isLocalWorkspace: task.isLocalWorkspace,
      isCloudWorkspace: task.isCloudWorkspace,
      isPreviewJob: true,
    });

    const jwt = await new SignJWT({
      taskRunId,
      teamId: args.teamId,
      userId: args.userId,
    })
      .setProtectedHeader({ alg: "HS256" })
      .setIssuedAt()
      .setExpirationTime("12h")
      .sign(new TextEncoder().encode(env.CMUX_TASK_RUN_JWT_SECRET));

    return { taskRunId, jwt };
  },
});
