import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

const IS_LIVE_CONVEX_DEPLOYMENT = true;

function fixUrl(url: string) {
  if (IS_LIVE_CONVEX_DEPLOYMENT) {
    return url;
  }
  // only local convex deployments live on port 9777
  const urlObj = new URL(url);
  urlObj.port = "9777";
  return urlObj.toString();
}

// Generate an upload URL for the client to upload files
export const generateUploadUrl = authMutation({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    // Enforce membership to the team context
    await getTeamId(ctx, args.teamSlugOrId);
    const url = await ctx.storage.generateUploadUrl();
    return fixUrl(url);
  },
});

// Get a file's URL from its storage ID
export const getUrl = authQuery({
  args: { teamSlugOrId: v.string(), storageId: v.id("_storage") },
  handler: async (ctx, args) => {
    await getTeamId(ctx, args.teamSlugOrId);
    const url = await ctx.storage.getUrl(args.storageId);
    if (!url) {
      throw new Error(`Failed to get URL for storage ID: ${args.storageId}`);
    }
    return fixUrl(url);
  },
});

// Get multiple file URLs
export const getUrls = authQuery({
  args: { teamSlugOrId: v.string(), storageIds: v.array(v.id("_storage")) },
  handler: async (ctx, args) => {
    await getTeamId(ctx, args.teamSlugOrId);
    const urls = await Promise.all(
      args.storageIds.map(async (id) => {
        const url = await ctx.storage.getUrl(id);
        if (!url) {
          throw new Error(`Failed to get URL for storage ID: ${id}`);
        }
        return {
          storageId: id,
          url: fixUrl(url),
        };
      })
    );
    return urls;
  },
});
