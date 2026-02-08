import { v } from "convex/values";
import { getTeamId, resolveTeamIdLoose } from "../_shared/team";
import { normalizeSlug, validateSlug } from "../_shared/teamSlug";
import { internalQuery } from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, { teamSlugOrId }) => {
    // Loose resolution to avoid blocking reads when membership rows lag
    const teamId = await resolveTeamIdLoose(ctx, teamSlugOrId);
    const team = await ctx.db
      .query("teams")
      .withIndex("by_teamId", (q) => q.eq("teamId", teamId))
      .first();
    if (!team) return null;
    return {
      uuid: team.teamId,
      slug: team.slug ?? null,
      displayName: team.displayName ?? null,
      name: team.name ?? null,
    };
  },
});

export const listTeamMemberships = authQuery({
  args: {},
  handler: async (ctx) => {
    const memberships = await ctx.db
      .query("teamMemberships")
      .withIndex("by_user", (q) => q.eq("userId", ctx.identity.subject))
      .collect();
    const teams = await Promise.all(
      memberships.map((m) =>
        ctx.db
          .query("teams")
          .withIndex("by_teamId", (q) => q.eq("teamId", m.teamId))
          .first()
      )
    );
    return memberships.map((m, i) => ({
      ...m,
      team: teams[i]!,
    }));
  },
});

export const setSlug = authMutation({
  args: { teamSlugOrId: v.string(), slug: v.string() },
  handler: async (ctx, { teamSlugOrId, slug }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);
    const normalized = normalizeSlug(slug);
    validateSlug(normalized);

    // Ensure uniqueness
    const existingWithSlug = await ctx.db
      .query("teams")
      .withIndex("by_slug", (q) => q.eq("slug", normalized))
      .first();
    if (existingWithSlug && existingWithSlug.teamId !== teamId) {
      throw new Error("Slug is already taken");
    }

    const now = Date.now();
    const team = await ctx.db
      .query("teams")
      .withIndex("by_teamId", (q) => q.eq("teamId", teamId))
      .first();
    if (team) {
      await ctx.db.patch(team._id, { slug: normalized, updatedAt: now });
    } else {
      await ctx.db.insert("teams", {
        teamId,
        slug: normalized,
        createdAt: now,
        updatedAt: now,
      });
    }

    return { slug: normalized };
  },
});

export const setName = authMutation({
  args: { teamSlugOrId: v.string(), name: v.string() },
  handler: async (ctx, { teamSlugOrId, name }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);
    const trimmed = name.trim();
    if (trimmed.length < 1 || trimmed.length > 32) {
      throw new Error("Name must be 1–32 characters long");
    }
    const now = Date.now();
    const team = await ctx.db
      .query("teams")
      .withIndex("by_teamId", (q) => q.eq("teamId", teamId))
      .first();
    if (team) {
      await ctx.db.patch(team._id, { name: trimmed, updatedAt: now });
    } else {
      await ctx.db.insert("teams", {
        teamId,
        name: trimmed,
        createdAt: now,
        updatedAt: now,
      });
    }
    return { name: trimmed };
  },
});

// Internal helper to verify team membership (used by actions that need access control)
export const checkTeamMembership = internalQuery({
  args: { teamId: v.string(), userId: v.string() },
  handler: async (ctx, { teamId, userId }) => {
    const membership = await ctx.db
      .query("teamMemberships")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .first();
    return { isMember: !!membership };
  },
});

// Internal helper to fetch a team by ID (used by HTTP handlers for redirects)
export const getByTeamIdInternal = internalQuery({
  args: { teamId: v.string() },
  handler: async (ctx, { teamId }) => {
    const team = await ctx.db
      .query("teams")
      .withIndex("by_teamId", (q) => q.eq("teamId", teamId))
      .first();
    if (!team) return null;
    return {
      uuid: team.teamId,
      slug: team.slug ?? null,
      displayName: team.displayName ?? null,
      name: team.name ?? null,
    } as const;
  },
});

// Internal helper to fetch team memberships by userId (used by HTTP handlers)
export const getMembershipsByUserIdInternal = internalQuery({
  args: { userId: v.string() },
  handler: async (ctx, { userId }) => {
    const memberships = await ctx.db
      .query("teamMemberships")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .collect();
    return memberships.map(m => ({
      teamId: m.teamId,
      userId: m.userId,
      role: m.role,
    }));
  },
});

