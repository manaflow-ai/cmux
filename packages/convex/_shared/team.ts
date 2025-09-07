import type { MutationCtx, QueryCtx } from "../convex/_generated/server";

export function isUuid(value: string): boolean {
  // RFC4122 variant UUID v1–v5
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(value);
}

type AnyCtx = QueryCtx | MutationCtx;

// Resolve a teamSlugOrId to a canonical team UUID string.
export async function getTeamId(
  ctx: AnyCtx,
  teamSlugOrId: string
): Promise<string> {
  const identity = await ctx.auth.getUserIdentity();
  const userId = identity?.subject;

  if (isUuid(teamSlugOrId)) {
    if (userId) {
      const membership = await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) =>
          q.eq("teamId", teamSlugOrId).eq("userId", userId)
        )
        .first();
      if (!membership) {
        throw new Error("Forbidden: Not a member of this team");
      }
    }
    return teamSlugOrId;
  }

  const team = await ctx.db
    .query("teams")
    .filter((q) => q.eq(q.field("slug"), teamSlugOrId))
    .first();

  // identity already fetched above
  if (team) {
    const teamId = team.teamId;
    if (userId) {
      const membership = await ctx.db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) =>
          q.eq("teamId", teamId).eq("userId", userId)
        )
        .first();
      if (!membership) {
        throw new Error("Forbidden: Not a member of this team");
      }
    }
    return team.teamId;
  }

  // If we get here, the value is not a UUID and no team was found by slug
  // Treat as invalid/not found
  throw new Error("Team not found or invalid identifier");
}
