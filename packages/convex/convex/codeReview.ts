import { ConvexError, v } from "convex/values";
import { getTeamId, resolveTeamIdLoose } from "../_shared/team";
import type { Doc } from "./_generated/dataModel";
import type { MutationCtx } from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";
import { mutation } from "./_generated/server";
import { internal } from "./_generated/api";

const GITHUB_HOST = "github.com";
type JobDoc = Doc<"automatedCodeReviewJobs">;

function serializeJob(job: JobDoc) {
  return {
    jobId: job._id,
    teamId: job.teamId ?? null,
    repoFullName: job.repoFullName,
    repoUrl: job.repoUrl,
    prNumber: job.prNumber,
    commitRef: job.commitRef,
    requestedByUserId: job.requestedByUserId,
    jobType: job.jobType ?? "pull_request",
    comparisonSlug: job.comparisonSlug ?? null,
    comparisonBaseOwner: job.comparisonBaseOwner ?? null,
    comparisonBaseRef: job.comparisonBaseRef ?? null,
    comparisonHeadOwner: job.comparisonHeadOwner ?? null,
    comparisonHeadRef: job.comparisonHeadRef ?? null,
    state: job.state,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    startedAt: job.startedAt ?? null,
    completedAt: job.completedAt ?? null,
    sandboxInstanceId: job.sandboxInstanceId ?? null,
    errorCode: job.errorCode ?? null,
    errorDetail: job.errorDetail ?? null,
    codeReviewOutput: job.codeReviewOutput ?? null,
  };
}

function parseGithubLink(link: string): {
  repoFullName: string;
  repoUrl: string;
} {
  try {
    const url = new URL(link);
    if (url.hostname !== GITHUB_HOST) {
      throw new ConvexError(`Unsupported GitHub host: ${url.hostname}`);
    }
    const segments = url.pathname.split("/").filter(Boolean);
    if (segments.length < 2) {
      throw new ConvexError(`Unable to parse GitHub repository from ${link}`);
    }
    const repoFullName = `${segments[0]}/${segments[1]}`;
    return {
      repoFullName,
      repoUrl: `https://${GITHUB_HOST}/${repoFullName}.git`,
    };
  } catch (error) {
    if (error instanceof ConvexError) {
      throw error;
    }
    throw new ConvexError(`Invalid GitHub URL: ${link}`);
  }
}

async function hashSha256(value: string): Promise<string> {
  const encoder = new TextEncoder();
  const data = encoder.encode(value);
  const digest = await crypto.subtle.digest("SHA-256", data);
  const bytes = new Uint8Array(digest);
  return Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function ensureJobOwner(requesterId: string, job: JobDoc) {
  if (job.requestedByUserId !== requesterId) {
    throw new ConvexError("Forbidden");
  }
}

async function findExistingActiveJob(
  db: MutationCtx["db"],
  teamId: string | undefined,
  repoFullName: string,
  jobType: "pull_request" | "comparison",
  options: {
    prNumber?: number;
    comparisonSlug?: string;
  }
): Promise<JobDoc | null> {
  if (jobType === "comparison") {
    if (!options.comparisonSlug) {
      return null;
    }
    const job = await db
      .query("automatedCodeReviewJobs")
      .withIndex("by_team_repo_comparison_updated", (q) =>
        q
          .eq("teamId", teamId ?? undefined)
          .eq("repoFullName", repoFullName)
          .eq("comparisonSlug", options.comparisonSlug)
      )
      .order("desc")
      .filter((q) =>
        q.and(
          q.or(q.eq("state", "pending"), q.eq("state", "running")),
          q.eq("jobType", "comparison")
        )
      )
      .first();
    return job ?? null;
  }

  if (!options.prNumber) {
    return null;
  }

  const job = await db
    .query("automatedCodeReviewJobs")
    .withIndex("by_team_repo_pr_updated", (q) =>
      q
        .eq("teamId", teamId ?? undefined)
        .eq("repoFullName", repoFullName)
        .eq("prNumber", options.prNumber)
    )
    .order("desc")
    .filter((q) =>
      q.and(
        q.or(q.eq("state", "pending"), q.eq("state", "running")),
        q.or(
          q.eq("jobType", "pull_request"),
          q.eq(q.field("jobType"), undefined)
        )
      )
    )
    .first();
  return job ?? null;
}

async function schedulePauseMorphInstance(
  ctx: MutationCtx,
  sandboxInstanceId: string
): Promise<void> {
  await ctx.scheduler.runAfter(
    0,
    internal.codeReviewActions.pauseMorphInstance,
    {
      sandboxInstanceId,
    }
  );
}

export const reserveJob = authMutation({
  args: {
    teamSlugOrId: v.optional(v.string()),
    githubLink: v.string(),
    prNumber: v.optional(v.number()),
    commitRef: v.optional(v.string()),
    callbackTokenHash: v.string(),
    force: v.optional(v.boolean()),
    comparison: v.optional(
      v.object({
        slug: v.string(),
        baseOwner: v.string(),
        baseRef: v.string(),
        headOwner: v.string(),
        headRef: v.string(),
      })
    ),
  },
  handler: async (ctx, args) => {
    const { identity } = ctx;
    const { repoFullName, repoUrl } = parseGithubLink(args.githubLink);
    const repoOwner = repoFullName.split("/")[0] ?? "unknown-owner";
    const teamKey = args.teamSlugOrId ?? repoOwner;
    const jobType = args.comparison ? "comparison" : "pull_request";

    if (jobType === "pull_request" && typeof args.prNumber !== "number") {
      throw new ConvexError("prNumber is required for pull_request jobs");
    }
    if (jobType === "comparison" && !args.comparison) {
      throw new ConvexError("comparison metadata is required for comparison jobs");
    }

    let teamId: string;
    try {
      teamId = await getTeamId(ctx, teamKey);
    } catch (error) {
      console.warn(
        "[codeReview.reserveJob] Failed to resolve team, falling back",
        {
          teamSlugOrId: teamKey,
          error,
        }
      );
      teamId = await resolveTeamIdLoose(ctx, teamKey);
      console.info("[codeReview.reserveJob] Using loose team identifier", {
        teamSlugOrId: teamKey,
        resolvedTeamId: teamId,
      });
    }

    let existing = await findExistingActiveJob(ctx.db, teamId, repoFullName, jobType, {
      prNumber: args.prNumber ?? undefined,
      comparisonSlug: args.comparison?.slug,
    });
    if (existing && existing.jobType !== jobType) {
      await ctx.db.patch(existing._id, {
        jobType,
      });
      const refreshed = await ctx.db.get(existing._id);
      if (refreshed) {
        existing = refreshed;
      }
    }
    if (existing && !args.force) {
      if (
        jobType === "comparison" &&
        args.comparison &&
        existing.comparisonSlug &&
        existing.comparisonSlug !== args.comparison.slug
      ) {
        console.warn(
          "[codeReview.reserveJob] Comparison slug mismatch with existing job; proceeding with existing job",
          {
            jobId: existing._id,
            existingSlug: existing.comparisonSlug,
            requestedSlug: args.comparison.slug,
          }
        );
      }
      console.info("[codeReview.reserveJob] Reusing existing active job", {
        jobId: existing._id,
        repoFullName,
        prNumber: args.prNumber,
      });
      return {
        wasCreated: false as const,
        job: serializeJob(existing),
      };
    }

    if (existing && args.force) {
      ensureJobOwner(identity.subject, existing);
      const now = Date.now();
      await ctx.db.patch(existing._id, {
        state: "failed",
        errorCode: "force_rerun",
        errorDetail: "Superseded by a new automated code review run",
        updatedAt: now,
        completedAt: now,
        callbackTokenHash: undefined,
      });
      console.info("[codeReview.reserveJob] Forced rerun; superseding job", {
        jobId: existing._id,
        repoFullName,
        prNumber: args.prNumber,
      });
    }

    let commitRef: string;
    if (jobType === "pull_request") {
      const pullRequest = await ctx.db
        .query("pullRequests")
        .withIndex("by_team_repo_number", (q) =>
          q
            .eq("teamId", teamId)
            .eq("repoFullName", repoFullName)
            .eq("number", args.prNumber!)
        )
        .first();

      commitRef =
        args.commitRef ??
        pullRequest?.headSha ??
        pullRequest?.mergeCommitSha ??
        "unknown";
    } else {
      commitRef = args.commitRef ?? "unknown";
    }

    const now = Date.now();
    const jobId = await ctx.db.insert("automatedCodeReviewJobs", {
      teamId,
      repoFullName,
      repoUrl,
      prNumber: jobType === "pull_request" ? args.prNumber : undefined,
      commitRef,
      requestedByUserId: identity.subject,
      jobType,
      comparisonSlug: args.comparison?.slug,
      comparisonBaseOwner: args.comparison?.baseOwner,
      comparisonBaseRef: args.comparison?.baseRef,
      comparisonHeadOwner: args.comparison?.headOwner,
      comparisonHeadRef: args.comparison?.headRef,
      state: "pending",
      createdAt: now,
      updatedAt: now,
      callbackTokenHash: args.callbackTokenHash,
      callbackTokenIssuedAt: now,
    });

    const job = await ctx.db.get(jobId);
    if (!job) {
      throw new ConvexError("Failed to create job");
    }
    console.info("[codeReview.reserveJob] Created new job", {
      jobId,
      teamId,
      repoFullName,
      prNumber: args.prNumber,
    });

    return {
      wasCreated: true as const,
      job: serializeJob(job),
    };
  },
});

export const markJobRunning = authMutation({
  args: {
    jobId: v.id("automatedCodeReviewJobs"),
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job) {
      throw new ConvexError("Job not found");
    }

    ensureJobOwner(ctx.identity.subject, job);
    if (job.state === "running") {
      return serializeJob(job);
    }
    if (job.state !== "pending") {
      throw new ConvexError(
        `Cannot mark job ${job._id} as running from state ${job.state}`
      );
    }

    const now = Date.now();
    await ctx.db.patch(job._id, {
      state: "running",
      startedAt: now,
      updatedAt: now,
    });

    const updated = await ctx.db.get(job._id);
    if (!updated) {
      throw new ConvexError("Failed to update job");
    }
    return serializeJob(updated);
  },
});

export const failJob = authMutation({
  args: {
    jobId: v.id("automatedCodeReviewJobs"),
    errorCode: v.string(),
    errorDetail: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job) {
      throw new ConvexError("Job not found");
    }
    ensureJobOwner(ctx.identity.subject, job);

    if (job.state === "completed" || job.state === "failed") {
      return serializeJob(job);
    }

    const now = Date.now();
    await ctx.db.patch(job._id, {
      state: "failed",
      errorCode: args.errorCode,
      errorDetail: args.errorDetail,
      updatedAt: now,
      completedAt: now,
      callbackTokenHash: undefined,
    });

    const updated = await ctx.db.get(job._id);
    if (!updated) {
      throw new ConvexError("Failed to update job");
    }
    return serializeJob(updated);
  },
});

export const upsertFileOutputFromCallback = mutation({
  args: {
    jobId: v.id("automatedCodeReviewJobs"),
    callbackToken: v.string(),
    filePath: v.string(),
    codexReviewOutput: v.any(),
    sandboxInstanceId: v.optional(v.string()),
    commitRef: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job) {
      throw new ConvexError("Job not found");
    }

    if (!job.callbackTokenHash) {
      throw new ConvexError("Callback token already consumed");
    }

    const hashed = await hashSha256(args.callbackToken);
    if (hashed !== job.callbackTokenHash) {
      throw new ConvexError("Invalid callback token");
    }

    const now = Date.now();
    const commitRef = args.commitRef ?? job.commitRef;
    const sandboxInstanceId = args.sandboxInstanceId ?? job.sandboxInstanceId;
    if (!sandboxInstanceId) {
      throw new ConvexError("Missing sandbox instance id for file output");
    }

    const existing = await ctx.db
      .query("automatedCodeReviewFileOutputs")
      .withIndex("by_job_file", (q) =>
        q.eq("jobId", job._id).eq("filePath", args.filePath)
      )
      .first();

    if (existing) {
      await ctx.db.patch(existing._id, {
        codexReviewOutput: args.codexReviewOutput,
        commitRef,
        sandboxInstanceId,
        jobType: job.jobType,
        comparisonSlug: job.comparisonSlug,
        comparisonBaseOwner: job.comparisonBaseOwner,
        comparisonBaseRef: job.comparisonBaseRef,
        comparisonHeadOwner: job.comparisonHeadOwner,
        comparisonHeadRef: job.comparisonHeadRef,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("automatedCodeReviewFileOutputs", {
        jobId: job._id,
        teamId: job.teamId,
        repoFullName: job.repoFullName,
        prNumber: job.prNumber,
        commitRef,
        jobType: job.jobType,
        comparisonSlug: job.comparisonSlug,
        comparisonBaseOwner: job.comparisonBaseOwner,
        comparisonBaseRef: job.comparisonBaseRef,
        comparisonHeadOwner: job.comparisonHeadOwner,
        comparisonHeadRef: job.comparisonHeadRef,
        sandboxInstanceId,
        filePath: args.filePath,
        codexReviewOutput: args.codexReviewOutput,
        createdAt: now,
        updatedAt: now,
      });
    }

    await ctx.db.patch(job._id, {
      updatedAt: now,
      sandboxInstanceId,
    });

    return {
      success: true as const,
    };
  },
});

export const completeJobFromCallback = mutation({
  args: {
    jobId: v.id("automatedCodeReviewJobs"),
    callbackToken: v.string(),
    sandboxInstanceId: v.optional(v.string()),
    codeReviewOutput: v.record(v.string(), v.any()),
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job) {
      throw new ConvexError("Job not found");
    }

    if (!job.callbackTokenHash) {
      if (job.state === "completed") {
        return serializeJob(job);
      }
      throw new ConvexError("Callback token already consumed");
    }

    const hashed = await hashSha256(args.callbackToken);
    if (hashed !== job.callbackTokenHash) {
      throw new ConvexError("Invalid callback token");
    }

    const now = Date.now();
    const sandboxInstanceId = args.sandboxInstanceId ?? job.sandboxInstanceId;
    if (!sandboxInstanceId) {
      throw new ConvexError("Missing sandbox instance id for completion");
    }
    await ctx.db.patch(job._id, {
      state: "completed",
      updatedAt: now,
      completedAt: now,
      sandboxInstanceId,
      codeReviewOutput: args.codeReviewOutput,
      callbackTokenHash: undefined,
      errorCode: undefined,
      errorDetail: undefined,
    });

    await ctx.db.insert("automatedCodeReviewVersions", {
      jobId: job._id,
      teamId: job.teamId,
      requestedByUserId: job.requestedByUserId,
      repoFullName: job.repoFullName,
      repoUrl: job.repoUrl,
      prNumber: job.prNumber,
      commitRef: job.commitRef,
      jobType: job.jobType,
      comparisonSlug: job.comparisonSlug,
      comparisonBaseOwner: job.comparisonBaseOwner,
      comparisonBaseRef: job.comparisonBaseRef,
      comparisonHeadOwner: job.comparisonHeadOwner,
      comparisonHeadRef: job.comparisonHeadRef,
      sandboxInstanceId,
      codeReviewOutput: args.codeReviewOutput,
      createdAt: now,
    });

    const updated = await ctx.db.get(job._id);
    if (!updated) {
      throw new ConvexError("Failed to update job");
    }
    await schedulePauseMorphInstance(ctx, sandboxInstanceId);
    return serializeJob(updated);
  },
});

export const failJobFromCallback = mutation({
  args: {
    jobId: v.id("automatedCodeReviewJobs"),
    callbackToken: v.string(),
    sandboxInstanceId: v.optional(v.string()),
    errorCode: v.optional(v.string()),
    errorDetail: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const job = await ctx.db.get(args.jobId);
    if (!job) {
      throw new ConvexError("Job not found");
    }

    if (!job.callbackTokenHash) {
      if (job.state === "failed") {
        return serializeJob(job);
      }
      throw new ConvexError("Callback token already consumed");
    }

    const hashed = await hashSha256(args.callbackToken);
    if (hashed !== job.callbackTokenHash) {
      throw new ConvexError("Invalid callback token");
    }

    const now = Date.now();
    const sandboxInstanceId = args.sandboxInstanceId ?? job.sandboxInstanceId;
    if (!sandboxInstanceId) {
      throw new ConvexError("Missing sandbox instance id for failure");
    }
    await ctx.db.patch(job._id, {
      state: "failed",
      updatedAt: now,
      completedAt: now,
      sandboxInstanceId,
      errorCode: args.errorCode ?? "callback_failed",
      errorDetail: args.errorDetail,
      callbackTokenHash: undefined,
    });

    const updated = await ctx.db.get(job._id);
    if (!updated) {
      throw new ConvexError("Failed to update job");
    }
    await schedulePauseMorphInstance(ctx, sandboxInstanceId);
    return serializeJob(updated);
  },
});

export const listFileOutputsForPr = authQuery({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    prNumber: v.number(),
    commitRef: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const limit = Math.min(args.limit ?? 200, 500);

    let query = ctx.db
      .query("automatedCodeReviewFileOutputs")
      .withIndex("by_team_repo_pr_commit", (q) =>
        q
          .eq("teamId", teamId)
          .eq("repoFullName", args.repoFullName)
          .eq("prNumber", args.prNumber)
      )
      .order("desc");

    if (args.commitRef) {
      query = query.filter((q) => q.eq(q.field("commitRef"), args.commitRef));
    }

    const outputs = await query.take(limit);

    return outputs.map((output) => ({
      id: output._id,
      jobId: output.jobId,
      teamId: output.teamId,
      repoFullName: output.repoFullName,
      prNumber: output.prNumber,
      commitRef: output.commitRef,
      sandboxInstanceId: output.sandboxInstanceId ?? null,
      filePath: output.filePath,
      codexReviewOutput: output.codexReviewOutput,
      createdAt: output.createdAt,
      updatedAt: output.updatedAt,
    }));
  },
});

export const listFileOutputsForComparison = authQuery({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    comparisonSlug: v.string(),
    commitRef: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const limit = Math.min(args.limit ?? 200, 500);

    let query = ctx.db
      .query("automatedCodeReviewFileOutputs")
      .withIndex("by_team_repo_comparison_commit", (q) =>
        q
          .eq("teamId", teamId)
          .eq("repoFullName", args.repoFullName)
          .eq("comparisonSlug", args.comparisonSlug)
      )
      .order("desc");

    if (args.commitRef) {
      query = query.filter((q) => q.eq(q.field("commitRef"), args.commitRef));
    }

    const outputs = await query.take(limit);

    return outputs.map((output) => ({
      id: output._id,
      jobId: output.jobId,
      teamId: output.teamId,
      repoFullName: output.repoFullName,
      prNumber: output.prNumber ?? null,
      commitRef: output.commitRef,
      sandboxInstanceId: output.sandboxInstanceId ?? null,
      filePath: output.filePath,
      codexReviewOutput: output.codexReviewOutput,
      createdAt: output.createdAt,
      updatedAt: output.updatedAt,
    }));
  },
});
