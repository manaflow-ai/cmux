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
    headCommitRef: job.headCommitRef ?? job.commitRef,
    baseCommitRef: job.baseCommitRef ?? null,
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

function isSameCommitContext(
  job: JobDoc,
  requestedHead: string,
  requestedBase: string | null
): boolean {
  const jobHead = job.headCommitRef ?? job.commitRef ?? null;
  if (!jobHead || jobHead !== requestedHead) {
    return false;
  }
  if (requestedBase === null) {
    return true;
  }
  return job.baseCommitRef === requestedBase;
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
    headCommitRef?: string;
    baseCommitRef?: string;
  }
): Promise<JobDoc | null> {
  const requestedHeadCommitRef = options.headCommitRef ?? null;
  const requestedBaseCommitRef = options.baseCommitRef ?? null;

  if (jobType === "comparison") {
    if (!options.comparisonSlug) {
      return null;
    }
    const candidates = await db
      .query("automatedCodeReviewJobs")
      .withIndex("by_team_repo_comparison_updated", (q) =>
        q
          .eq("teamId", teamId ?? undefined)
          .eq("repoFullName", repoFullName)
          .eq("comparisonSlug", options.comparisonSlug)
      )
      .order("desc")
      .take(20);

    for (const job of candidates) {
      const normalizedJobType = job.jobType ?? "pull_request";
      if (normalizedJobType !== "comparison") {
        continue;
      }
      if (job.state !== "pending" && job.state !== "running") {
        continue;
      }
      const jobHead = job.headCommitRef ?? job.commitRef ?? null;
      const jobBase = job.baseCommitRef ?? null;
      if (
        requestedHeadCommitRef &&
        jobHead &&
        jobHead !== requestedHeadCommitRef
      ) {
        continue;
      }
      if (
        requestedBaseCommitRef &&
        jobBase &&
        jobBase !== requestedBaseCommitRef
      ) {
        continue;
      }
      if (requestedHeadCommitRef && !jobHead) {
        continue;
      }
      if (requestedBaseCommitRef && !jobBase) {
        continue;
      }
      return job;
    }
    return null;
  }

  if (!options.prNumber) {
    return null;
  }

  const candidates = await db
    .query("automatedCodeReviewJobs")
    .withIndex("by_team_repo_pr_updated", (q) =>
      q
        .eq("teamId", teamId ?? undefined)
        .eq("repoFullName", repoFullName)
        .eq("prNumber", options.prNumber)
    )
    .order("desc")
    .take(20);

  for (const job of candidates) {
    const normalizedJobType = job.jobType ?? "pull_request";
    if (normalizedJobType !== "pull_request") {
      continue;
    }
    if (job.state !== "pending" && job.state !== "running") {
      continue;
    }
    const jobHead = job.headCommitRef ?? job.commitRef ?? null;
    const jobBase = job.baseCommitRef ?? null;
    if (
      requestedHeadCommitRef &&
      jobHead &&
      jobHead !== requestedHeadCommitRef
    ) {
      continue;
    }
    if (
      requestedBaseCommitRef &&
      jobBase &&
      jobBase !== requestedBaseCommitRef
    ) {
      continue;
    }
    if (requestedHeadCommitRef && !jobHead) {
      continue;
    }
    if (requestedBaseCommitRef && !jobBase) {
      continue;
    }
    return job;
  }
  return null;
}

async function findLatestCompletedJob(
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
    const completed = await db
      .query("automatedCodeReviewJobs")
      .withIndex("by_team_repo_comparison_updated", (q) =>
        q
          .eq("teamId", teamId ?? undefined)
          .eq("repoFullName", repoFullName)
          .eq("comparisonSlug", options.comparisonSlug)
      )
      .order("desc")
      .filter((q) => q.eq("state", "completed"))
      .first();
    return completed ?? null;
  }

  if (!options.prNumber) {
    return null;
  }

  const completed = await db
    .query("automatedCodeReviewJobs")
    .withIndex("by_team_repo_pr_updated", (q) =>
      q
        .eq("teamId", teamId ?? undefined)
        .eq("repoFullName", repoFullName)
        .eq("prNumber", options.prNumber)
    )
    .order("desc")
    .filter((q) => q.eq("state", "completed"))
    .first();
  return completed ?? null;
}

async function findComparisonJobByCommit(
  db: MutationCtx["db"],
  repoFullName: string,
  comparisonSlug: string,
  commitRef: string,
  teamId: string | undefined,
  baseCommitRef?: string
): Promise<JobDoc | null> {
  const candidates = await db
    .query("automatedCodeReviewJobs")
    .withIndex("by_repo_comparison_commit", (q) =>
      q
        .eq("repoFullName", repoFullName)
        .eq("comparisonSlug", comparisonSlug)
        .eq("commitRef", commitRef)
    )
    .order("desc")
    .take(10);

  if (candidates.length === 0) {
    return null;
  }

  const normalizedTeamId = teamId ?? null;
  for (const job of candidates) {
    if ((job.teamId ?? null) !== normalizedTeamId) {
      continue;
    }
    const jobBase = job.baseCommitRef ?? null;
    if (baseCommitRef && jobBase && jobBase !== baseCommitRef) {
      continue;
    }
    if (baseCommitRef && !jobBase) {
      continue;
    }
    return job;
  }
  return null;
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
    headCommitRef: v.optional(v.string()),
    baseCommitRef: v.optional(v.string()),
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
    console.info("[codeReview.reserveJob] Resolved team context", {
      requestedTeamKey: teamKey,
      resolvedTeamId: teamId,
      repoFullName,
      jobType,
    });

    let pullRequestDoc: Doc<"pullRequests"> | null = null;
    let headCommitRef =
      args.headCommitRef ?? args.commitRef ?? null;
    let baseCommitRef = args.baseCommitRef ?? null;

    if (jobType === "pull_request") {
      pullRequestDoc = await ctx.db
        .query("pullRequests")
        .withIndex("by_team_repo_number", (q) =>
          q
            .eq("teamId", teamId)
            .eq("repoFullName", repoFullName)
            .eq("number", args.prNumber!)
        )
        .first();

      if (!headCommitRef) {
        headCommitRef =
          pullRequestDoc?.headSha ??
          pullRequestDoc?.mergeCommitSha ??
          null;
      }
      if (!baseCommitRef) {
        baseCommitRef = pullRequestDoc?.baseSha ?? null;
      }
      if (!headCommitRef) {
        throw new ConvexError("headCommitRef is required for pull_request jobs");
      }
      if (!baseCommitRef) {
        throw new ConvexError("baseCommitRef is required for pull_request jobs");
      }
    } else {
      if (!headCommitRef) {
        headCommitRef = args.commitRef ?? null;
      }
      if (!headCommitRef) {
        throw new ConvexError("headCommitRef is required for comparison jobs");
      }
      if (!baseCommitRef) {
        baseCommitRef = args.baseCommitRef ?? null;
      }
      if (!baseCommitRef) {
        throw new ConvexError("baseCommitRef is required for comparison jobs");
      }
    }

    const commitRef = headCommitRef;

    console.info("[codeReview.reserveJob] Commit context", {
      jobType,
      prNumber: args.prNumber ?? null,
      comparisonSlug: args.comparison?.slug ?? null,
      headCommitRef,
      baseCommitRef,
    });

    console.info("[codeReview.reserveJob] Looking for active job", {
      teamId,
      repoFullName,
      jobType,
      prNumber: args.prNumber ?? null,
      comparisonSlug: args.comparison?.slug ?? null,
    });
    let existing = await findExistingActiveJob(ctx.db, teamId, repoFullName, jobType, {
      prNumber: args.prNumber ?? undefined,
      comparisonSlug: args.comparison?.slug,
      headCommitRef,
      baseCommitRef,
    });
    if (existing) {
      console.info("[codeReview.reserveJob] Active job candidate found", {
        jobId: existing._id,
        state: existing.state,
        jobType: existing.jobType ?? "pull_request",
        commitRef: existing.commitRef,
        headCommitRef: existing.headCommitRef ?? existing.commitRef,
        baseCommitRef: existing.baseCommitRef ?? null,
        teamId: existing.teamId ?? null,
        repoFullName: existing.repoFullName,
        prNumber: existing.prNumber ?? null,
        comparisonSlug: existing.comparisonSlug ?? null,
      });
    } else {
      console.info("[codeReview.reserveJob] No active job candidate found", {
        teamId,
        repoFullName,
        jobType,
        prNumber: args.prNumber ?? null,
        comparisonSlug: args.comparison?.slug ?? null,
        expectedHeadCommitRef: headCommitRef,
        expectedBaseCommitRef: baseCommitRef,
      });
      if (jobType === "pull_request" && args.prNumber !== undefined) {
        const debugJobs = await ctx.db
          .query("automatedCodeReviewJobs")
          .withIndex("by_team_repo_pr_updated", (q) =>
            q
              .eq("teamId", teamId ?? undefined)
              .eq("repoFullName", repoFullName)
              .eq("prNumber", args.prNumber!)
          )
          .order("desc")
          .collect();
        console.info("[codeReview.reserveJob] Active job scan snapshot", {
          jobCount: debugJobs.length,
          jobs: debugJobs.slice(0, 5).map((job) => ({
            jobId: job._id,
            state: job.state,
            teamId: job.teamId ?? null,
            repoFullName: job.repoFullName,
            prNumber: job.prNumber ?? null,
            commitRef: job.commitRef,
            headCommitRef: job.headCommitRef ?? job.commitRef,
            baseCommitRef: job.baseCommitRef ?? null,
            jobType: job.jobType ?? "pull_request",
            updatedAt: job.updatedAt,
          })),
        });
      }
    }
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

    if (jobType === "comparison" && args.comparison && !args.force) {
      const matchingComparisonJob = await findComparisonJobByCommit(
        ctx.db,
        repoFullName,
        args.comparison.slug,
        commitRef,
        teamId,
        baseCommitRef
      );

      if (matchingComparisonJob) {
        if (
          matchingComparisonJob.state === "completed" ||
          matchingComparisonJob.state === "pending" ||
          matchingComparisonJob.state === "running"
        ) {
          console.info("[codeReview.reserveJob] Reusing comparison job by commit", {
            jobId: matchingComparisonJob._id,
            repoFullName,
            comparisonSlug: args.comparison.slug,
            commitRef,
            baseCommitRef,
            state: matchingComparisonJob.state,
          });
          return {
            wasCreated: false as const,
            job: serializeJob(matchingComparisonJob),
          };
        }
      }
    }

    if (jobType === "pull_request") {
      const latestCompleted = await findLatestCompletedJob(
        ctx.db,
        teamId,
        repoFullName,
        jobType,
        {
          prNumber: args.prNumber ?? undefined,
        }
      );

      if (!latestCompleted) {
        console.info("[codeReview.reserveJob] No completed job found", {
          repoFullName,
          jobType,
          prNumber: args.prNumber ?? null,
          comparisonSlug: null,
        });
      }

      if (
        latestCompleted &&
        isSameCommitContext(latestCompleted, commitRef, baseCommitRef) &&
        !args.force
      ) {
        console.info("[codeReview.reserveJob] Skipping job; commit unchanged", {
          repoFullName,
          jobType,
          prNumber: args.prNumber ?? null,
          comparisonSlug: null,
          commitRef,
          baseCommitRef,
        });
        return {
          wasCreated: false as const,
          job: serializeJob(latestCompleted),
        };
      }
      if (latestCompleted) {
        console.info("[codeReview.reserveJob] Latest completed job found", {
          repoFullName,
          jobType,
          prNumber: args.prNumber ?? null,
          comparisonSlug: null,
          latestCommitRef: latestCompleted.commitRef,
          requestedCommitRef: commitRef,
          latestBaseCommitRef: latestCompleted.baseCommitRef ?? null,
          requestedBaseCommitRef: baseCommitRef,
          matches: isSameCommitContext(
            latestCompleted,
            commitRef,
            baseCommitRef
          ),
        });
      }
    } else if (jobType === "comparison" && args.comparison && !args.force) {
      const latestCompleted = await findLatestCompletedJob(
        ctx.db,
        teamId,
        repoFullName,
        jobType,
        {
          comparisonSlug: args.comparison.slug,
        }
      );

      if (!latestCompleted) {
        console.info("[codeReview.reserveJob] No completed job found", {
          repoFullName,
          jobType,
          comparisonSlug: args.comparison.slug,
          prNumber: null,
        });
      } else if (
        isSameCommitContext(latestCompleted, commitRef, baseCommitRef)
      ) {
        console.info("[codeReview.reserveJob] Reusing latest completed comparison job", {
          jobId: latestCompleted._id,
          repoFullName,
          comparisonSlug: args.comparison.slug,
          commitRef,
          baseCommitRef,
        });
        return {
          wasCreated: false as const,
          job: serializeJob(latestCompleted),
        };
      } else {
        console.info("[codeReview.reserveJob] Latest completed comparison differs", {
          jobId: latestCompleted._id,
          repoFullName,
          comparisonSlug: args.comparison.slug,
          latestCommitRef: latestCompleted.commitRef,
          requestedCommitRef: commitRef,
          latestBaseCommitRef: latestCompleted.baseCommitRef ?? null,
          requestedBaseCommitRef: baseCommitRef,
        });
      }
    }

    const now = Date.now();
    const jobId = await ctx.db.insert("automatedCodeReviewJobs", {
      teamId,
      repoFullName,
      repoUrl,
      prNumber: jobType === "pull_request" ? args.prNumber : undefined,
      commitRef,
      headCommitRef: commitRef,
      baseCommitRef,
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
    tooltipLanguage: v.optional(v.string()),
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
        headCommitRef: job.headCommitRef ?? job.commitRef,
        baseCommitRef: job.baseCommitRef,
        sandboxInstanceId,
        jobType: job.jobType,
        comparisonSlug: job.comparisonSlug,
        comparisonBaseOwner: job.comparisonBaseOwner,
        comparisonBaseRef: job.comparisonBaseRef,
        comparisonHeadOwner: job.comparisonHeadOwner,
        comparisonHeadRef: job.comparisonHeadRef,
        tooltipLanguage: args.tooltipLanguage,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("automatedCodeReviewFileOutputs", {
        jobId: job._id,
        teamId: job.teamId,
        repoFullName: job.repoFullName,
        prNumber: job.prNumber,
        commitRef,
        headCommitRef: job.headCommitRef ?? job.commitRef,
        baseCommitRef: job.baseCommitRef,
        jobType: job.jobType,
        comparisonSlug: job.comparisonSlug,
        comparisonBaseOwner: job.comparisonBaseOwner,
        comparisonBaseRef: job.comparisonBaseRef,
        comparisonHeadOwner: job.comparisonHeadOwner,
        comparisonHeadRef: job.comparisonHeadRef,
        sandboxInstanceId,
        filePath: args.filePath,
        codexReviewOutput: args.codexReviewOutput,
        tooltipLanguage: args.tooltipLanguage,
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
      headCommitRef: job.headCommitRef ?? job.commitRef,
      baseCommitRef: job.baseCommitRef,
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
    baseCommitRef: v.optional(v.string()),
    tooltipLanguage: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    // Use resolveTeamIdLoose to allow public repo access for non-members
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const limit = Math.min(args.limit ?? 200, 500);

    // Use language-specific index when language is provided
    const query = args.tooltipLanguage
      ? ctx.db
          .query("automatedCodeReviewFileOutputs")
          .withIndex("by_team_repo_pr_lang", (q) =>
            q
              .eq("teamId", teamId)
              .eq("repoFullName", args.repoFullName)
              .eq("prNumber", args.prNumber)
              .eq("tooltipLanguage", args.tooltipLanguage)
          )
          .order("desc")
      : ctx.db
          .query("automatedCodeReviewFileOutputs")
          .withIndex("by_team_repo_pr_commit", (q) =>
            q
              .eq("teamId", teamId)
              .eq("repoFullName", args.repoFullName)
              .eq("prNumber", args.prNumber)
          )
          .order("desc");

    let filteredQuery = query;
    if (args.commitRef) {
      filteredQuery = filteredQuery.filter((q) =>
        q.eq(q.field("commitRef"), args.commitRef)
      );
    }
    if (args.baseCommitRef) {
      filteredQuery = filteredQuery.filter((q) =>
        q.eq(q.field("baseCommitRef"), args.baseCommitRef)
      );
    }

    const outputs = await filteredQuery.take(limit);

    return outputs.map((output) => ({
      id: output._id,
      jobId: output.jobId,
      teamId: output.teamId,
      repoFullName: output.repoFullName,
      prNumber: output.prNumber,
      commitRef: output.commitRef,
      headCommitRef: output.headCommitRef ?? output.commitRef,
      baseCommitRef: output.baseCommitRef ?? null,
      sandboxInstanceId: output.sandboxInstanceId ?? null,
      filePath: output.filePath,
      codexReviewOutput: output.codexReviewOutput,
      tooltipLanguage: output.tooltipLanguage ?? null,
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
    baseCommitRef: v.optional(v.string()),
    tooltipLanguage: v.optional(v.string()),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    // Use resolveTeamIdLoose to allow public repo access for non-members
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const limit = Math.min(args.limit ?? 200, 500);

    // Use language-specific index when language is provided
    const query = args.tooltipLanguage
      ? ctx.db
          .query("automatedCodeReviewFileOutputs")
          .withIndex("by_team_repo_comparison_lang", (q) =>
            q
              .eq("teamId", teamId)
              .eq("repoFullName", args.repoFullName)
              .eq("comparisonSlug", args.comparisonSlug)
              .eq("tooltipLanguage", args.tooltipLanguage)
          )
          .order("desc")
      : ctx.db
          .query("automatedCodeReviewFileOutputs")
          .withIndex("by_team_repo_comparison_commit", (q) =>
            q
              .eq("teamId", teamId)
              .eq("repoFullName", args.repoFullName)
              .eq("comparisonSlug", args.comparisonSlug)
          )
          .order("desc");

    let filteredQuery = query;
    if (args.commitRef) {
      filteredQuery = filteredQuery.filter((q) =>
        q.eq(q.field("commitRef"), args.commitRef)
      );
    }
    if (args.baseCommitRef) {
      filteredQuery = filteredQuery.filter((q) =>
        q.eq(q.field("baseCommitRef"), args.baseCommitRef)
      );
    }

    const outputs = await filteredQuery.take(limit);

    return outputs.map((output) => ({
      id: output._id,
      jobId: output.jobId,
      teamId: output.teamId,
      repoFullName: output.repoFullName,
      prNumber: output.prNumber ?? null,
      commitRef: output.commitRef,
      headCommitRef: output.headCommitRef ?? output.commitRef,
      baseCommitRef: output.baseCommitRef ?? null,
      sandboxInstanceId: output.sandboxInstanceId ?? null,
      filePath: output.filePath,
      codexReviewOutput: output.codexReviewOutput,
      tooltipLanguage: output.tooltipLanguage ?? null,
      createdAt: output.createdAt,
      updatedAt: output.updatedAt,
    }));
  },
});

/**
 * Save streamed review output for a file without requiring a job.
 * Used by the frontend to cache streaming API results for language-specific tooltips.
 */
export const saveStreamedReviewOutput = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    // For PR reviews
    prNumber: v.optional(v.number()),
    // For comparison reviews
    comparisonSlug: v.optional(v.string()),
    filePath: v.string(),
    codexReviewOutput: v.any(),
    tooltipLanguage: v.string(),
    commitRef: v.string(),
    baseCommitRef: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const now = Date.now();
    const jobType = args.comparisonSlug ? "comparison" : "pull_request";

    // Find existing record by team + repo + (pr or comparison) + language + file
    let existing = null;
    if (args.prNumber !== undefined) {
      // Query for PR-based outputs
      const candidates = await ctx.db
        .query("automatedCodeReviewFileOutputs")
        .withIndex("by_team_repo_pr_lang", (q) =>
          q
            .eq("teamId", teamId)
            .eq("repoFullName", args.repoFullName)
            .eq("prNumber", args.prNumber)
            .eq("tooltipLanguage", args.tooltipLanguage)
        )
        .filter((q) => q.eq(q.field("filePath"), args.filePath))
        .first();
      existing = candidates;
    } else if (args.comparisonSlug) {
      // Query for comparison-based outputs
      const candidates = await ctx.db
        .query("automatedCodeReviewFileOutputs")
        .withIndex("by_team_repo_comparison_lang", (q) =>
          q
            .eq("teamId", teamId)
            .eq("repoFullName", args.repoFullName)
            .eq("comparisonSlug", args.comparisonSlug)
            .eq("tooltipLanguage", args.tooltipLanguage)
        )
        .filter((q) => q.eq(q.field("filePath"), args.filePath))
        .first();
      existing = candidates;
    }

    if (existing) {
      // Update existing record
      await ctx.db.patch(existing._id, {
        codexReviewOutput: args.codexReviewOutput,
        commitRef: args.commitRef,
        baseCommitRef: args.baseCommitRef,
        tooltipLanguage: args.tooltipLanguage,
        updatedAt: now,
      });
      return { success: true as const, updated: true as const };
    }

    // Insert new record (no jobId since this is from streaming)
    await ctx.db.insert("automatedCodeReviewFileOutputs", {
      // No jobId - this is streamed without a job
      teamId,
      repoFullName: args.repoFullName,
      prNumber: args.prNumber,
      comparisonSlug: args.comparisonSlug,
      jobType,
      filePath: args.filePath,
      codexReviewOutput: args.codexReviewOutput,
      tooltipLanguage: args.tooltipLanguage,
      commitRef: args.commitRef,
      headCommitRef: args.commitRef,
      baseCommitRef: args.baseCommitRef,
      // Use a placeholder for streaming results
      sandboxInstanceId: "streaming-api",
      createdAt: now,
      updatedAt: now,
    });

    return { success: true as const, updated: false as const };
  },
});
