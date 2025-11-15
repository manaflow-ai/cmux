import { v } from "convex/values";
import { internalQuery } from "./_generated/server";

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
