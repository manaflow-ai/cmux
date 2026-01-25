import { v } from "convex/values";
import { internalQuery, query } from "./_generated/server";
import { resolveTeamIdLoose } from "../_shared/team";

export const findTaskRunsForPr = internalQuery({
  args: {
    teamId: v.string(),
    repoFullName: v.string(),
    prNumber: v.number(),
  },
  handler: async (ctx, { teamId, repoFullName, prNumber }) => {
    // Limit scan to recent runs to avoid loading entire history for large teams
    const recentRuns = await ctx.db
      .query("taskRuns")
      .withIndex("by_team_user", (q) => q.eq("teamId", teamId))
      .order("desc")
      .take(300);

    const matchingRuns = recentRuns.filter((run) => {
      if (!run.pullRequests || run.pullRequests.length === 0) {
        return false;
      }

      return run.pullRequests.some(
        (pr) =>
          pr.repoFullName === repoFullName &&
          pr.number === prNumber,
      );
    });

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

    // Get URLs for all videos
    const videosWithUrls = screenshotSet.videos
      ? await Promise.all(
          screenshotSet.videos.map(async (video) => {
            const url = await ctx.storage.getUrl(video.storageId);
            return {
              ...video,
              url: url ?? undefined,
            };
          }),
        )
      : undefined;

    return {
      ...screenshotSet,
      images: imagesWithUrls,
      videos: videosWithUrls,
    };
  },
});

/**
 * List screenshot sets for a pull request.
 * Finds task runs linked to the PR via taskRunPullRequests junction table,
 * then returns their associated screenshot sets.
 */
export const listScreenshotSetsForPr = query({
  args: {
    teamSlugOrId: v.string(),
    repoFullName: v.string(),
    prNumber: v.number(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const maxSets = Math.min(args.limit ?? 10, 10);

    // Find task run links for this PR using the junction table
    const prLinks = await ctx.db
      .query("taskRunPullRequests")
      .withIndex("by_pr", (q) =>
        q
          .eq("teamId", teamId)
          .eq("repoFullName", args.repoFullName)
          .eq("prNumber", args.prNumber)
      )
      .order("desc")
      .take(50);

    if (prLinks.length === 0) {
      return [];
    }

    // Get unique run IDs
    const runIds = [...new Set(prLinks.map((link) => link.taskRunId))];

    // Fetch runs to get their latestScreenshotSetId
    const runs = await Promise.all(runIds.map((id) => ctx.db.get(id)));
    const validRuns = runs.filter(
      (run): run is NonNullable<typeof run> =>
        run !== null && run.latestScreenshotSetId !== undefined
    );

    if (validRuns.length === 0) {
      return [];
    }

    // Get unique screenshot set IDs from the runs
    const screenshotSetIds = [
      ...new Set(
        validRuns
          .map((run) => run.latestScreenshotSetId)
          .filter((id): id is NonNullable<typeof id> => id !== undefined)
      ),
    ];

    // Fetch the screenshot sets
    const screenshotSets = await Promise.all(
      screenshotSetIds.slice(0, maxSets).map(async (setId) => {
        const set = await ctx.db.get(setId);
        if (!set) {
          return null;
        }

        // Get URLs for all images
        const imagesWithUrls = await Promise.all(
          set.images.map(async (image) => {
            const url = await ctx.storage.getUrl(image.storageId);
            return {
              ...image,
              url: url ?? undefined,
            };
          })
        );

        return {
          ...set,
          images: imagesWithUrls,
        };
      })
    );

    // Filter out nulls and sort by capturedAt descending
    return screenshotSets
      .filter((set): set is NonNullable<typeof set> => set !== null)
      .sort((a, b) => b.capturedAt - a.capturedAt);
  },
});
