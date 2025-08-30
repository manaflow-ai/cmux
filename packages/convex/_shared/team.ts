import type { MutationCtx, QueryCtx } from "../convex/_generated/server";

export function isUuid(value: string): boolean {
  // RFC4122 variant UUID v1–v5
  const uuidRegex =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  return uuidRegex.test(value);
}

type AnyCtx = QueryCtx | MutationCtx;

// Resolve a teamSlugOrId to a canonical team UUID string.
// Falls back to the input if no team is found (for backwards compatibility).
export async function getTeamId(
  ctx: AnyCtx,
  teamSlugOrId: string
): Promise<string> {
  if (isUuid(teamSlugOrId)) return teamSlugOrId;

  const team = await ctx.db
    .query("teams")
    .filter((q) => q.eq(q.field("slug"), teamSlugOrId))
    .first();

  const identity = await ctx.auth.getUserIdentity();
  const userId = identity?.subject;
  if (team) {
    const teamId = team.uuid;
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
    return team.uuid;
  }

  // Back-compat: allow legacy string teamIds (e.g., "default").
  // When identity is available, ensure membership if such a team exists in memberships.
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

// Resolve a teamSlugOrId to a team UUID without enforcing membership.
// Use this when the caller already scopes by userId and does not need
// team membership guarantees (e.g., per-user comments).
export async function resolveTeamIdLoose(
  ctx: AnyCtx,
  teamSlugOrId: string
): Promise<string> {
  if (isUuid(teamSlugOrId)) return teamSlugOrId;

  const team = await ctx.db
    .query("teams")
    .filter((q) => q.eq(q.field("slug"), teamSlugOrId))
    .first();
  if (team) return team.uuid;

  // Back-compat: allow legacy string teamIds (e.g., "default").
  return teamSlugOrId;
}
