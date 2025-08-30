import { v } from "convex/values";
import { getTeamId, resolveTeamIdLoose } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";
import { internalQuery } from "./_generated/server";

function normalizeSlug(input: string): string {
  const s = input.trim().toLowerCase();
  return s;
}

function validateSlug(slug: string): void {
  const s = normalizeSlug(slug);
  // 3-48 chars, lowercase letters, numbers, and hyphens. Must start/end with alphanumeric.
  if (s.length < 3 || s.length > 48) {
    throw new Error("Slug must be 3–48 characters long");
  }
  if (!/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(s)) {
    throw new Error(
      "Slug can contain lowercase letters, numbers, and hyphens, and must start/end with a letter or number"
    );
  }
}

export const get = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, { teamSlugOrId }) => {
    // Loose resolution to avoid blocking reads when membership rows lag
    const teamId = await resolveTeamIdLoose(ctx, teamSlugOrId);
    const team = await ctx.db
      .query("teams")
      .withIndex("by_uuid", (q) => q.eq("uuid", teamId))
      .first();
    if (!team) return null;
    return {
      uuid: team.uuid,
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
          .withIndex("by_uuid", (q) => q.eq("uuid", m.teamId))
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
    if (existingWithSlug && existingWithSlug.uuid !== teamId) {
      throw new Error("Slug is already taken");
    }

    const now = Date.now();
    const team = await ctx.db
      .query("teams")
      .withIndex("by_uuid", (q) => q.eq("uuid", teamId))
      .first();
    if (team) {
      await ctx.db.patch(team._id, { slug: normalized, updatedAt: now });
    } else {
      await ctx.db.insert("teams", {
        uuid: teamId,
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
      .withIndex("by_uuid", (q) => q.eq("uuid", teamId))
      .first();
    if (team) {
      await ctx.db.patch(team._id, { name: trimmed, updatedAt: now });
    } else {
      await ctx.db.insert("teams", {
        uuid: teamId,
        name: trimmed,
        createdAt: now,
        updatedAt: now,
      });
    }
    return { name: trimmed };
  },
});

// Internal helper to fetch a team by UUID (used by HTTP handlers for redirects)
export const getByUuidInternal = internalQuery({
  args: { uuid: v.string() },
  handler: async (ctx, { uuid }) => {
    const team = await ctx.db
      .query("teams")
      .withIndex("by_uuid", (q) => q.eq("uuid", uuid))
      .first();
    if (!team) return null;
    return { uuid: team.uuid, slug: team.slug ?? null } as const;
  },
});
