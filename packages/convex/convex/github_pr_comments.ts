"use node";
import { v } from "convex/values";
import { fetchInstallationAccessToken } from "../_shared/githubApp";
import { internal } from "./_generated/api";
import {
  internalAction,
  internalQuery,
  type ActionCtx,
} from "./_generated/server";

export const addPrReaction = internalAction({
  args: {
    installationId: v.number(),
    repoFullName: v.string(),
    prNumber: v.number(),
    content: v.literal("eyes"),
  },
  handler: async (
    _ctx,
    { installationId, repoFullName, prNumber, content },
  ) => {
    try {
      const accessToken = await fetchInstallationAccessToken(installationId);
      if (!accessToken) {
        console.error(
          "[github_pr_comments] Failed to get access token for installation",
          { installationId },
        );
        return { ok: false, error: "Failed to get access token" };
      }

      const response = await fetch(
        `https://api.github.com/repos/${repoFullName}/issues/${prNumber}/reactions`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            Accept: "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "cmux-github-bot",
          },
          body: JSON.stringify({ content }),
        },
      );

      if (!response.ok) {
        const errorText = await response.text();
        console.error(
          "[github_pr_comments] Failed to add reaction",
          {
            installationId,
            repoFullName,
            prNumber,
            status: response.status,
            error: errorText,
          },
        );
        return {
          ok: false,
          error: `GitHub API error: ${response.status}`,
        };
      }

      const data = await response.json();
      console.log("[github_pr_comments] Successfully added reaction", {
        installationId,
        repoFullName,
        prNumber,
        reactionId: data.id,
      });

      return { ok: true as const, reactionId: data.id };
    } catch (error) {
      console.error(
        "[github_pr_comments] Unexpected error adding reaction",
        {
          installationId,
          repoFullName,
          prNumber,
          error,
        },
      );
      return {
        ok: false as const,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  },
});

export const addPrComment = internalAction({
  args: {
    installationId: v.number(),
    repoFullName: v.string(),
    prNumber: v.number(),
    body: v.string(),
  },
  handler: async (
    _ctx,
    { installationId, repoFullName, prNumber, body },
  ) => {
    try {
      const accessToken = await fetchInstallationAccessToken(installationId);
      if (!accessToken) {
        console.error(
          "[github_pr_comments] Failed to get access token for installation",
          { installationId },
        );
        return { ok: false, error: "Failed to get access token" };
      }

      const response = await fetch(
        `https://api.github.com/repos/${repoFullName}/issues/${prNumber}/comments`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${accessToken}`,
            Accept: "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "cmux-github-bot",
          },
          body: JSON.stringify({ body }),
        },
      );

      if (!response.ok) {
        const errorText = await response.text();
        console.error(
          "[github_pr_comments] Failed to add comment",
          {
            installationId,
            repoFullName,
            prNumber,
            status: response.status,
            error: errorText,
          },
        );
        return {
          ok: false,
          error: `GitHub API error: ${response.status}`,
        };
      }

      const data = await response.json();
      console.log("[github_pr_comments] Successfully added comment", {
        installationId,
        repoFullName,
        prNumber,
        commentId: data.id,
      });

      return { ok: true as const, commentId: data.id };
    } catch (error) {
      console.error(
        "[github_pr_comments] Unexpected error adding comment",
        {
          installationId,
          repoFullName,
          prNumber,
          error,
        },
      );
      return {
        ok: false as const,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  },
});

export const findTaskRunsForPr = internalQuery({
  args: {
    teamId: v.string(),
    repoFullName: v.string(),
    prNumber: v.number(),
  },
  handler: async (ctx, { teamId, repoFullName, prNumber }) => {
    // Find task runs that have this PR
    const allRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_team_user", (q) => q.eq("teamId", teamId))
      .collect();

    const matchingRuns = allRuns.filter((run) => {
      if (!run.pullRequests || run.pullRequests.length === 0) {
        return false;
      }
      return run.pullRequests.some(
        (pr) =>
          pr.repoFullName === repoFullName &&
          pr.number === prNumber,
      );
    });

    // Sort by creation time, most recent first
    matchingRuns.sort((a, b) => b.createdAt - a.createdAt);

    return matchingRuns.slice(0, 5); // Return up to 5 most recent runs
  },
});

export const getScreenshotSet = internalQuery({
  args: {
    screenshotSetId: v.id("taskRunScreenshotSets"),
  },
  handler: async (ctx, { screenshotSetId }) => {
    const screenshotSet = await ctx.db.get(screenshotSetId);
    if (!screenshotSet) {
      return null;
    }

    // Get URLs for all screenshots
    const imagesWithUrls = await Promise.all(
      screenshotSet.images.map(async (image) => {
        const url = await ctx.storage.getUrl(image.storageId);
        return {
          ...image,
          url: url ?? undefined,
        };
      }),
    );

    return {
      ...screenshotSet,
      images: imagesWithUrls,
    };
  },
});

async function getScreenshotsForPr(
  ctx: ActionCtx,
  {
    teamId,
    repoFullName,
    prNumber,
  }: {
    teamId: string;
    repoFullName: string;
    prNumber: number;
  },
): Promise<Array<{ url: string; fileName?: string }>> {
  try {
    // Find task runs that have this PR
    const taskRuns = await ctx.runQuery(
      internal.github_pr_comments.findTaskRunsForPr,
      {
        teamId,
        repoFullName,
        prNumber,
      },
    );

    if (taskRuns.length === 0) {
      return [];
    }

    // Get screenshots from the latest task run
    const screenshots: Array<{ url: string; fileName?: string }> = [];
    for (const run of taskRuns) {
      if (run.latestScreenshotSetId) {
        const screenshotSet = await ctx.runQuery(
          internal.github_pr_comments.getScreenshotSet,
          {
            screenshotSetId: run.latestScreenshotSetId,
          },
        );
        if (screenshotSet && screenshotSet.status === "completed") {
          for (const image of screenshotSet.images) {
            if (image.url) {
              screenshots.push({
                url: image.url,
                fileName: image.fileName,
              });
            }
          }
        }
      }
    }

    return screenshots;
  } catch (error) {
    console.error(
      "[github_pr_comments] Error fetching screenshots for PR",
      {
        teamId,
        repoFullName,
        prNumber,
        error,
      },
    );
    return [];
  }
}

function formatScreenshotComment(
  screenshots: Array<{ url: string; fileName?: string }>,
): string {
  if (screenshots.length === 0) {
    return "";
  }

  let markdown = "## Screenshots\n\n";
  markdown +=
    "Here are the screenshots from the latest run:\n\n";

  for (const screenshot of screenshots) {
    const title = screenshot.fileName || "Screenshot";
    markdown += `### ${title}\n\n`;
    markdown += `![${title}](${screenshot.url})\n\n`;
  }

  return markdown;
}

export const addScreenshotCommentToPr = internalAction({
  args: {
    installationId: v.number(),
    repoFullName: v.string(),
    prNumber: v.number(),
    teamId: v.string(),
  },
  handler: async (
    ctx,
    { installationId, repoFullName, prNumber, teamId },
  ): Promise<
    | { ok: true; commentId?: number; skipped?: boolean; reason?: string }
    | { ok: false; error: string }
  > => {
    try {
      const screenshots = await getScreenshotsForPr(ctx, {
        teamId,
        repoFullName,
        prNumber,
      });

      if (screenshots.length === 0) {
        console.log(
          "[github_pr_comments] No screenshots found for PR",
          {
            installationId,
            repoFullName,
            prNumber,
          },
        );
        return { ok: true as const, skipped: true, reason: "No screenshots found" };
      }

      const body = formatScreenshotComment(screenshots);

      const result = await ctx.runAction(internal.github_pr_comments.addPrComment, {
        installationId,
        repoFullName,
        prNumber,
        body,
      });

      if (result.ok) {
        return { ok: true as const, commentId: result.commentId };
      }
      return { ok: false as const, error: result.error };
    } catch (error) {
      console.error(
        "[github_pr_comments] Unexpected error adding screenshot comment",
        {
          installationId,
          repoFullName,
          prNumber,
          teamId,
          error,
        },
      );
      return {
        ok: false as const,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  },
});
