import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import {
  internalMutation,
  internalQuery,
  type MutationCtx,
} from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";
import { aggregatePullRequestState, type RunPullRequestState, type StoredPullRequestInfo } from "@cmux/shared/pull-request-state";
import { internal } from "./_generated/api";

const SYSTEM_BRANCH_USER_ID = "__system__";

type WebhookUser = {
  login?: string;
  id?: number;
};

type WebhookRepo = {
  id?: number;
  pushed_at?: string;
};

type WebhookBranchRef = {
  ref?: string;
  sha?: string;
  repo?: WebhookRepo;
};

type WebhookPullRequest = {
  number?: number;
  id?: number;
  title?: string;
  state?: string;
  merged?: boolean;
  draft?: boolean;
  html_url?: string;
  merge_commit_sha?: string;
  created_at?: string;
  updated_at?: string;
  closed_at?: string;
  merged_at?: string;
  comments?: number;
  review_comments?: number;
  commits?: number;
  additions?: number;
  deletions?: number;
  changed_files?: number;
  user?: WebhookUser;
  base?: WebhookBranchRef;
  head?: WebhookBranchRef;
};

type PullRequestWebhookEnvelope = {
  pull_request?: WebhookPullRequest;
  number?: number;
};

async function upsertBranchMetadata(
  ctx: MutationCtx,
  {
    teamId,
    repoFullName,
    branchName,
    baseSha,
    mergeCommitSha,
    headSha,
    activityTimestamp,
  }: {
    teamId: string;
    repoFullName: string;
    branchName: string;
    baseSha?: string;
    mergeCommitSha?: string;
    headSha?: string;
    activityTimestamp?: number;
  }
) {
  if (!baseSha && !mergeCommitSha && !headSha) {
    return;
  }

  const repoDoc = await ctx.db
    .query("repos")
    .withIndex("by_team", (q) => q.eq("teamId", teamId))
    .filter((q) => q.eq(q.field("fullName"), repoFullName))
    .first();
  const repoId = repoDoc?._id;

  // Use .take(2) for low OCC cost while enabling duplicate cleanup
  // Happy path (0-1 records): same cost as .first()
  // Duplicate path (2 records): cleanup only when needed
  const existingBranches = await ctx.db
    .query("branches")
    .withIndex("by_repo", (q) => q.eq("repo", repoFullName))
    .filter((q) => q.eq(q.field("teamId"), teamId))
    .filter((q) => q.eq(q.field("name"), branchName))
    .filter((q) => q.eq(q.field("userId"), SYSTEM_BRANCH_USER_ID))
    .take(2);

  const timestamp = activityTimestamp ?? Date.now();

  // Find the newest record by lastActivityAt (handles duplicates correctly)
  let systemBranch = existingBranches[0];
  if (existingBranches.length > 1) {
    for (const branch of existingBranches) {
      if ((branch.lastActivityAt ?? 0) > (systemBranch?.lastActivityAt ?? 0)) {
        systemBranch = branch;
      }
    }
  }

  const action = systemBranch ? "update" : "insert";

  console.log("[occ-debug:branches]", {
    branchName,
    repoFullName,
    teamId,
    action,
    repoDocFound: !!repoDoc,
  });

  if (systemBranch) {
    // Lazy cleanup: delete duplicates first (keep the newest) - must run even for stale updates
    if (existingBranches.length > 1) {
      console.warn("[occ-debug:branches] cleaning-duplicates", { branchName, count: existingBranches.length });
      for (const dup of existingBranches) {
        if (dup._id !== systemBranch._id) {
          await ctx.db.delete(dup._id);
        }
      }
    }

    // Skip stale updates - if existing branch has newer activity, don't overwrite
    if (
      typeof systemBranch.lastActivityAt === "number" &&
      timestamp <= systemBranch.lastActivityAt
    ) {
      console.log("[occ-debug:branches] skipped-stale", {
        branchName,
        existingLastActivityAt: systemBranch.lastActivityAt,
        newTimestamp: timestamp,
      });
      return;
    }

    // Build patch with only changed fields (no-op check)
    const patch: Record<string, unknown> = {};
    if (repoId && systemBranch.repoId !== repoId) {
      patch.repoId = repoId;
    }
    if (baseSha && systemBranch.lastKnownBaseSha !== baseSha) {
      patch.lastKnownBaseSha = baseSha;
    }
    if (mergeCommitSha && systemBranch.lastKnownMergeCommitSha !== mergeCommitSha) {
      patch.lastKnownMergeCommitSha = mergeCommitSha;
    }
    if (headSha && systemBranch.lastCommitSha !== headSha) {
      patch.lastCommitSha = headSha;
    }
    patch.lastActivityAt = timestamp;

    if (Object.keys(patch).length > 1 || patch.lastActivityAt !== systemBranch.lastActivityAt) {
      await ctx.db.patch(systemBranch._id, patch);
    } else {
      console.log("[occ-debug:branches] skipped-noop", { branchName });
    }
  } else {
    await ctx.db.insert("branches", {
      repo: repoFullName,
      repoId,
      name: branchName,
      userId: SYSTEM_BRANCH_USER_ID,
      teamId,
      lastKnownBaseSha: baseSha,
      lastKnownMergeCommitSha: mergeCommitSha,
      lastCommitSha: headSha,
      lastActivityAt: timestamp,
    });
  }
}

async function upsertCore(
  ctx: MutationCtx,
  {
    teamId,
    installationId,
    repoFullName,
    number,
    record,
  }: {
    teamId: string;
    installationId: number;
    repoFullName: string;
    number: number;
    record: {
      providerPrId?: number;
      repositoryId?: number;
      title: string;
      state: "open" | "closed";
      merged?: boolean;
      draft?: boolean;
      authorLogin?: string;
      authorId?: number;
      htmlUrl?: string;
      baseRef?: string;
      headRef?: string;
      baseSha?: string;
      headSha?: string;
      mergeCommitSha?: string;
      createdAt?: number;
      updatedAt?: number;
      closedAt?: number;
      mergedAt?: number;
      commentsCount?: number;
      reviewCommentsCount?: number;
      commitsCount?: number;
      additions?: number;
      deletions?: number;
      changedFiles?: number;
    };
  }
) {
  // Use .take(2) for low OCC cost while enabling duplicate cleanup
  // Happy path (0-1 records): same cost as .first()
  // Duplicate path (2 records): cleanup only when needed
  const existingRecords = await ctx.db
    .query("pullRequests")
    .withIndex("by_team_repo_number", (q) =>
      q.eq("teamId", teamId).eq("repoFullName", repoFullName).eq("number", number)
    )
    .take(2);

  // Find the newest record by updatedAt (handles duplicates correctly)
  let existing = existingRecords[0];
  if (existingRecords.length > 1) {
    for (const record of existingRecords) {
      if ((record.updatedAt ?? 0) > (existing?.updatedAt ?? 0)) {
        existing = record;
      }
    }
  }

  const action = existing ? "update" : "insert";
  console.log("[occ-debug:pull_requests]", {
    prNumber: number,
    repoFullName,
    teamId,
    action,
    state: record.state,
    merged: record.merged,
    baseRef: record.baseRef,
    headRef: record.headRef,
  });

  if (existing) {
    const existingUpdatedAt = existing.updatedAt;
    const incomingUpdatedAt = record.updatedAt;
    const isStale =
      typeof existingUpdatedAt === "number" &&
      typeof incomingUpdatedAt === "number" &&
      existingUpdatedAt >= incomingUpdatedAt;

    if (isStale) {
      console.log("[occ-debug:pull_requests] skipped-stale", {
        prNumber: number,
        existingUpdatedAt,
        incomingUpdatedAt,
      });
    } else {
      // Skip no-op updates - only patch if something actually changed
      const needsUpdate =
        existing.title !== record.title ||
        existing.state !== record.state ||
        existing.merged !== record.merged ||
        existing.draft !== record.draft ||
        existing.updatedAt !== record.updatedAt ||
        existing.closedAt !== record.closedAt ||
        existing.mergedAt !== record.mergedAt ||
        existing.headSha !== record.headSha ||
        existing.baseSha !== record.baseSha ||
        existing.mergeCommitSha !== record.mergeCommitSha;

      if (needsUpdate) {
        await ctx.db.patch(existing._id, {
          ...record,
          installationId,
          repoFullName,
          number,
          provider: "github",
          teamId,
        });
      } else {
        console.log("[occ-debug:pull_requests] skipped-noop", { prNumber: number });
      }
    }

    // Lazy cleanup: delete duplicates only when they exist (keep the newest)
    if (existingRecords.length > 1) {
      console.warn("[occ-debug:pull_requests] cleaning-duplicates", {
        prNumber: number,
        count: existingRecords.length,
      });
      for (const dup of existingRecords) {
        if (dup._id !== existing._id) {
          await ctx.db.delete(dup._id);
        }
      }
    }
    return existing._id;
  }
  const id = await ctx.db.insert("pullRequests", {
    provider: "github",
    teamId,
    installationId,
    repoFullName,
    number,
    ...record,
  });
  return id;
}

export const upsertPullRequestInternal = internalMutation({
  args: {
    teamId: v.string(),
    installationId: v.number(),
    repoFullName: v.string(),
    number: v.number(),
    record: v.object({
      providerPrId: v.optional(v.number()),
      repositoryId: v.optional(v.number()),
      title: v.string(),
      state: v.union(v.literal("open"), v.literal("closed")),
      merged: v.optional(v.boolean()),
      draft: v.optional(v.boolean()),
      authorLogin: v.optional(v.string()),
      authorId: v.optional(v.number()),
      htmlUrl: v.optional(v.string()),
      baseRef: v.optional(v.string()),
      headRef: v.optional(v.string()),
      baseSha: v.optional(v.string()),
      headSha: v.optional(v.string()),
      mergeCommitSha: v.optional(v.string()),
      createdAt: v.optional(v.number()),
      updatedAt: v.optional(v.number()),
      closedAt: v.optional(v.number()),
      mergedAt: v.optional(v.number()),
      commentsCount: v.optional(v.number()),
      reviewCommentsCount: v.optional(v.number()),
      commitsCount: v.optional(v.number()),
      additions: v.optional(v.number()),
      deletions: v.optional(v.number()),
      changedFiles: v.optional(v.number()),
    }),
  },
  handler: async (ctx, { teamId, installationId, repoFullName, number, record }) =>
    upsertCore(ctx, { teamId, installationId, repoFullName, number, record }),
});

export const listPullRequests = authQuery({
  args: {
    teamSlugOrId: v.string(),
    state: v.optional(v.union(v.literal("open"), v.literal("closed"), v.literal("all"))),
    search: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, { teamSlugOrId, state, search, limit }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);

    const useState = state ?? "open";
    const cursor = ctx.db
      .query("pullRequests")
      .withIndex(
        useState === "all" ? "by_team" : "by_team_state",
        (q) =>
          useState === "all"
            ? q.eq("teamId", teamId)
            : q.eq("teamId", teamId).eq("state", useState)
      )
      .order("desc");

    const rows = await cursor.collect();
    const q = (search ?? "").trim().toLowerCase();
    const filtered = !q
      ? rows
      : rows.filter((r) => {
          return (
            r.title.toLowerCase().includes(q) ||
            (r.authorLogin ?? "").toLowerCase().includes(q) ||
            r.repoFullName.toLowerCase().includes(q)
          );
        });
    const limited = typeof limit === "number" ? filtered.slice(0, Math.max(1, limit)) : filtered;
    return limited;
  },
});

export const getPullRequest = authQuery({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    number: v.number(),
  },
  handler: async (ctx, { teamSlugOrId, repoFullName, number }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);

    const pr = await ctx.db
      .query("pullRequests")
      .withIndex("by_team_repo_number", (q) =>
        q.eq("teamId", teamId).eq("repoFullName", repoFullName).eq("number", number)
      )
      .first();

    return pr ?? null;
  },
});

// Helper to look up a provider connection for a repository owner
export const getConnectionForOwnerInternal = internalQuery({
  args: { owner: v.string() },
  handler: async (ctx, { owner }) => {
    // If the same owner has multiple installations, this returns one arbitrarily.
    const row = await ctx.db
      .query("providerConnections")
      .filter((q) => q.eq(q.field("accountLogin"), owner))
      .first();
    return row ?? null;
  },
});

export const upsertFromWebhookPayload = internalMutation({
  args: {
    installationId: v.number(),
    repoFullName: v.string(),
    teamId: v.string(),
    payload: v.any(),
  },
  handler: async (ctx, { installationId, repoFullName, teamId, payload }) => {
    try {
      const envelope = (payload ?? {}) as PullRequestWebhookEnvelope;
      const pr = envelope.pull_request ?? {};
      const number = Number(pr.number ?? envelope.number ?? 0);
      if (!number) return { ok: false as const };
      const mapStr = (value: unknown) =>
        typeof value === "string" ? value : undefined;
      const mapNum = (value: unknown) =>
        typeof value === "number" ? value : undefined;
      const ts = (s: unknown) => {
        if (typeof s !== "string") return undefined;
        const n = Date.parse(s);
        return Number.isFinite(n) ? n : undefined;
      };
      const baseRef = mapStr(pr.base?.ref);
      const headRef = mapStr(pr.head?.ref);
      const baseSha = mapStr(pr.base?.sha);
      const headSha = mapStr(pr.head?.sha);
      const mergeCommitSha = mapStr(pr.merge_commit_sha);
      const baseActivityTs =
        ts(pr.base?.repo?.pushed_at) ??
        ts(pr.merged_at) ??
        ts(pr.updated_at) ??
        Date.now();

      await upsertCore(ctx, {
        teamId,
        installationId,
        repoFullName,
        number,
        record: {
          providerPrId: mapNum(pr.id),
          repositoryId: mapNum(pr.base?.repo?.id),
          title: mapStr(pr.title) ?? "",
          state: mapStr(pr.state) === "closed" ? "closed" : "open",
          merged: Boolean(pr.merged),
          draft: Boolean(pr.draft),
          authorLogin: mapStr(pr.user?.login),
          authorId: mapNum(pr.user?.id),
          htmlUrl: mapStr(pr.html_url),
          baseRef,
          headRef,
          baseSha,
          headSha,
          mergeCommitSha,
          createdAt: ts(pr.created_at),
          updatedAt: ts(pr.updated_at),
          closedAt: ts(pr.closed_at),
          mergedAt: ts(pr.merged_at),
          commentsCount: mapNum(pr.comments),
          reviewCommentsCount: mapNum(pr.review_comments),
          commitsCount: mapNum(pr.commits),
          additions: mapNum(pr.additions),
          deletions: mapNum(pr.deletions),
          changedFiles: mapNum(pr.changed_files),
        },
      });

      if (baseRef && (baseSha || mergeCommitSha)) {
        await upsertBranchMetadata(ctx, {
          teamId,
          repoFullName,
          branchName: baseRef,
          baseSha,
          mergeCommitSha,
          activityTimestamp: baseActivityTs,
        });
      }
      if (headRef && headSha) {
        await upsertBranchMetadata(ctx, {
          teamId,
          repoFullName,
          branchName: headRef,
          headSha,
          activityTimestamp: ts(pr.updated_at) ?? Date.now(),
        });
      }

      // Update task merge status for all taskRuns that reference this PR
      await ctx.scheduler.runAfter(0, internal.github_prs.updateTaskMergeStatusForPr, {
        teamId,
        repoFullName,
        number,
      });

      return { ok: true as const };
    } catch (_e) {
      return { ok: false as const };
    }
  },
});

// Internal mutation to update task merge status when a PR webhook arrives
export const updateTaskMergeStatusForPr = internalMutation({
  args: {
    teamId: v.string(),
    repoFullName: v.string(),
    number: v.number(),
  },
  handler: async (ctx, { teamId, repoFullName, number }) => {
    // Find all taskRuns that have this PR in their pullRequests array
    const allRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_team_user", (q) => q.eq("teamId", teamId))
      .collect();

    const affectedRuns = allRuns.filter((run) => {
      if (!run.pullRequests || run.pullRequests.length === 0) {
        return false;
      }
      return run.pullRequests.some(
        (pr) => pr.repoFullName === repoFullName && pr.number === number
      );
    });

    if (affectedRuns.length === 0) {
      return { updated: 0 };
    }

    // Get the updated PR data
    const prDoc = await ctx.db
      .query("pullRequests")
      .withIndex("by_team_repo_number", (q) =>
        q.eq("teamId", teamId).eq("repoFullName", repoFullName).eq("number", number)
      )
      .first();

    if (!prDoc) {
      return { updated: 0 };
    }

    // Determine the PR state
    const prState: RunPullRequestState = prDoc.merged
      ? "merged"
      : prDoc.draft
        ? "draft"
        : prDoc.state === "closed"
          ? "closed"
          : prDoc.state === "open"
            ? "open"
            : "unknown";

    // Update each affected taskRun and its task
    let updatedCount = 0;
    for (const run of affectedRuns) {
      // Update the PR state in the taskRun's pullRequests array
      const updatedPullRequests: StoredPullRequestInfo[] = (run.pullRequests ?? []).map((pr): StoredPullRequestInfo => {
        if (pr.repoFullName === repoFullName && pr.number === number) {
          return {
            repoFullName: pr.repoFullName,
            state: prState,
            isDraft: prDoc.draft ?? pr.isDraft,
            url: prDoc.htmlUrl ?? pr.url,
            number: pr.number,
          };
        }
        return pr as StoredPullRequestInfo;
      });

      // Recalculate the aggregate state
      const aggregate = aggregatePullRequestState(updatedPullRequests);

      // Update the taskRun
      await ctx.db.patch(run._id, {
        pullRequests: updatedPullRequests,
        pullRequestState: aggregate.state,
        pullRequestIsDraft: aggregate.isDraft,
        pullRequestUrl: aggregate.url,
        pullRequestNumber: aggregate.number,
      });

      // Update the task's merge status
      const task = await ctx.db.get(run.taskId);
      if (task && task.teamId === teamId) {
        await ctx.db.patch(run.taskId, {
          mergeStatus: aggregate.mergeStatus,
          updatedAt: Date.now(),
        });
        updatedCount++;
      }
    }

    return { updated: updatedCount };
  },
});

export const upsertFromServer = authMutation({
  args: {
    teamSlugOrId: v.string(),
    installationId: v.number(),
    repoFullName: v.string(),
    number: v.number(),
    record: v.object({
      providerPrId: v.optional(v.number()),
      repositoryId: v.optional(v.number()),
      title: v.string(),
      state: v.union(v.literal("open"), v.literal("closed")),
      merged: v.optional(v.boolean()),
      draft: v.optional(v.boolean()),
      authorLogin: v.optional(v.string()),
      authorId: v.optional(v.number()),
      htmlUrl: v.optional(v.string()),
      baseRef: v.optional(v.string()),
      headRef: v.optional(v.string()),
      baseSha: v.optional(v.string()),
      headSha: v.optional(v.string()),
      mergeCommitSha: v.optional(v.string()),
      createdAt: v.optional(v.number()),
      updatedAt: v.optional(v.number()),
      closedAt: v.optional(v.number()),
      mergedAt: v.optional(v.number()),
      commentsCount: v.optional(v.number()),
      reviewCommentsCount: v.optional(v.number()),
      commitsCount: v.optional(v.number()),
      additions: v.optional(v.number()),
      deletions: v.optional(v.number()),
      changedFiles: v.optional(v.number()),
    }),
  },
  handler: async (ctx, { teamSlugOrId, installationId, repoFullName, number, record }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);
    return await upsertCore(ctx, { teamId, installationId, repoFullName, number, record });
  },
});
