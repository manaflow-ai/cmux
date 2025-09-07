import { v } from "convex/values";
import { getTeamId } from "../_shared/team";
import { internalMutation } from "./_generated/server";
import { authMutation, authQuery } from "./users/utils";

export const getReposByOrg = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const repos = await ctx.db
      .query("repos")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .collect();

    // Group by organization
    const reposByOrg = repos.reduce(
      (acc, repo) => {
        if (!acc[repo.org]) {
          acc[repo.org] = [];
        }
        acc[repo.org].push(repo);
        return acc;
      },
      {} as Record<string, typeof repos>
    );

    return reposByOrg;
  },
});

export const getBranches = authQuery({
  args: { teamSlugOrId: v.string(), repo: v.string() },
  handler: async (ctx, { teamSlugOrId, repo }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);
    const branches = await ctx.db
      .query("branches")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .filter((q) => q.eq(q.field("repo"), repo))
      .collect();
    // Single-pass deterministic sort:
    // 1) Pin common branches first: main, dev, master, develop
    // 2) Most recent activity desc (undefined last)
    // 3) Creation time desc
    // 4) Name asc (stable, deterministic tie-breaker)
    const pinnedOrder = new Map<
      string,
      number
    >([
      ["main", 0],
      ["dev", 1],
      ["master", 2],
      ["develop", 3],
    ]);
    branches.sort((a, b) => {
      const pa = pinnedOrder.get(a.name) ?? Number.POSITIVE_INFINITY;
      const pb = pinnedOrder.get(b.name) ?? Number.POSITIVE_INFINITY;
      if (pa !== pb) return pa - pb;

      const aAct = a.lastActivityAt ?? -Infinity;
      const bAct = b.lastActivityAt ?? -Infinity;
      if (aAct !== bAct) return bAct - aAct;

      if (a._creationTime !== b._creationTime)
        return b._creationTime - a._creationTime;

      return a.name.localeCompare(b.name);
    });
    return branches.map((b) => b.name);
  },
});

// Queries
export const getAllRepos = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, { teamSlugOrId }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);
    return await ctx.db
      .query("repos")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .collect();
  },
});

export const getBranchesByRepo = authQuery({
  args: { teamSlugOrId: v.string(), repo: v.string() },
  handler: async (ctx, { teamSlugOrId, repo }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);
    return await ctx.db
      .query("branches")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .filter((q) => q.eq(q.field("repo"), repo))
      .collect();
  },
});

// Provider connections for the current team (GitHub App installations mapped to this team)
export const listProviderConnections = authQuery({
  args: { teamSlugOrId: v.string() },
  handler: async (ctx, { teamSlugOrId }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);
    const rows = await ctx.db
      .query("providerConnections")
      .withIndex("by_team", (q) => q.eq("teamId", teamId))
      .collect();
    return rows.map((r) => ({
      installationId: r.installationId,
      accountLogin: r.accountLogin,
      accountType: r.accountType,
      type: r.type,
      isActive: r.isActive ?? true,
    }));
  },
});

// Unassigned provider connections (no teamId yet)
export const listUnassignedProviderConnections = authQuery({
  args: {},
  handler: async (ctx) => {
    // For now, return all active, unassigned connections.
    // In the future, restrict by current user's ownership or admin role.
    const all = await ctx.db.query("providerConnections").collect();
    const rows = all.filter((r) => !r.teamId && (r.isActive ?? true));
    return rows.map((r) => ({
      installationId: r.installationId,
      accountLogin: r.accountLogin,
      accountType: r.accountType,
      isActive: r.isActive ?? true,
    }));
  },
});

// Assign a provider connection (installation) to the given team
export const assignProviderConnectionToTeam = authMutation({
  args: { teamSlugOrId: v.string(), installationId: v.number() },
  handler: async (ctx, { teamSlugOrId, installationId }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);
    const now = Date.now();
    const row = await ctx.db
      .query("providerConnections")
      .withIndex("by_installationId", (q) =>
        q.eq("installationId", installationId)
      )
      .first();
    if (!row) throw new Error("Installation not found");
    await ctx.db.patch(row._id, {
      teamId,
      connectedByUserId: ctx.identity.subject,
      updatedAt: now,
      isActive: true,
    });
    return { ok: true as const };
  },
});

// Remove a provider connection from the team (deactivate and detach)
export const removeProviderConnection = authMutation({
  args: { teamSlugOrId: v.string(), installationId: v.number() },
  handler: async (ctx, { teamSlugOrId, installationId }) => {
    const teamId = await getTeamId(ctx, teamSlugOrId);
    const row = await ctx.db
      .query("providerConnections")
      .withIndex("by_installationId", (q) =>
        q.eq("installationId", installationId)
      )
      .first();
    if (!row || row.teamId !== teamId) throw new Error("Not found");
    await ctx.db.patch(row._id, {
      teamId: undefined,
      isActive: false,
      updatedAt: Date.now(),
    });
    return { ok: true as const };
  },
});

// Internal mutations
export const insertRepo = internalMutation({
  args: {
    fullName: v.string(),
    org: v.string(),
    name: v.string(),
    gitRemote: v.string(),
    provider: v.optional(v.string()),
    userId: v.string(),
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    // Persist only repo fields + derived teamId; exclude teamSlugOrId
    const { fullName, org, name, gitRemote, provider, userId } = args;
    return await ctx.db.insert("repos", {
      fullName,
      org,
      name,
      gitRemote,
      provider,
      userId,
      teamId,
    });
  },
});

export const upsertRepo = authMutation({
  args: {
    teamSlugOrId: v.string(),
    fullName: v.string(),
    org: v.string(),
    name: v.string(),
    gitRemote: v.string(),
    provider: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const now = Date.now();
    // Check if repo already exists
    const existing = await ctx.db
      .query("repos")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .filter((q) => q.eq(q.field("gitRemote"), args.gitRemote))
      .first();

    if (existing) {
      // Update existing repo
      return await ctx.db.patch(existing._id, {
        fullName: args.fullName,
        org: args.org,
        name: args.name,
        gitRemote: args.gitRemote,
        provider: args.provider,
        lastSyncedAt: now,
      });
    } else {
      // Insert new repo
      return await ctx.db.insert("repos", {
        fullName: args.fullName,
        org: args.org,
        name: args.name,
        gitRemote: args.gitRemote,
        provider: args.provider || "github",
        userId,
        teamId,
        lastSyncedAt: now,
      });
    }
  },
});

export const deleteRepo = internalMutation({
  args: { id: v.id("repos") },
  handler: async (ctx, { id }) => {
    await ctx.db.delete(id);
  },
});

export const insertBranch = internalMutation({
  args: {
    repo: v.string(),
    name: v.string(),
    userId: v.string(),
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    const teamId = await getTeamId(ctx, args.teamSlugOrId);
    const { repo, name, userId } = args;
    return await ctx.db.insert("branches", { repo, name, userId, teamId });
  },
});

export const deleteBranch = internalMutation({
  args: { id: v.id("branches") },
  handler: async (ctx, { id }) => {
    await ctx.db.delete(id);
  },
});

// Bulk mutations
export const bulkInsertRepos = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repos: v.array(
      v.object({
        fullName: v.string(),
        org: v.string(),
        name: v.string(),
        gitRemote: v.string(),
        provider: v.optional(v.string()),
      })
    ),
  },
  handler: async (ctx, { teamSlugOrId, repos }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);
    // Get existing repos to check for duplicates
    const existingRepos = await ctx.db
      .query("repos")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .collect();
    const existingRepoNames = new Set(existingRepos.map((r) => r.fullName));

    // Only insert repos that don't already exist
    const newRepos = repos.filter(
      (repo) => !existingRepoNames.has(repo.fullName)
    );

    const now = Date.now();
    const insertedIds = await Promise.all(
      newRepos.map((repo) =>
        ctx.db.insert("repos", {
          ...repo,
          provider: repo.provider || "github",
          userId,
          teamId,
          lastSyncedAt: now,
        })
      )
    );
    return insertedIds;
  },
});

export const bulkInsertBranches = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repo: v.string(),
    branches: v.array(v.string()),
  },
  handler: async (ctx, { teamSlugOrId, repo, branches }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);
    // Get existing branches for this repo
    const existingBranches = await ctx.db
      .query("branches")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .filter((q) => q.eq(q.field("repo"), repo))
      .collect();
    const existingBranchNames = new Set(existingBranches.map((b) => b.name));

    // Only insert branches that don't already exist
    const newBranches = branches.filter(
      (name) => !existingBranchNames.has(name)
    );

    const insertedIds = await Promise.all(
      newBranches.map((name) =>
        ctx.db.insert("branches", { repo, name, userId, teamId })
      )
    );
    return insertedIds;
  },
});

// Upsert branches with activity metadata (name, lastActivityAt, lastCommitSha)
export const bulkUpsertBranchesWithActivity = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repo: v.string(),
    branches: v.array(
      v.object({
        name: v.string(),
        lastActivityAt: v.optional(v.number()),
        lastCommitSha: v.optional(v.string()),
      })
    ),
  },
  handler: async (ctx, { teamSlugOrId, repo, branches }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);

    const existing = await ctx.db
      .query("branches")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .filter((q) => q.eq(q.field("repo"), repo))
      .collect();
    const byName = new Map(existing.map((b) => [b.name, b] as const));

    const now = Date.now();
    const ops = branches.map(async (b) => {
      const row = byName.get(b.name);
      if (row) {
        // Patch only if values changed to reduce writes
        const patch: Record<string, unknown> = {};
        if (
          typeof b.lastActivityAt === "number" &&
          b.lastActivityAt !== row.lastActivityAt
        ) {
          patch.lastActivityAt = b.lastActivityAt;
        }
        if (b.lastCommitSha && b.lastCommitSha !== row.lastCommitSha) {
          patch.lastCommitSha = b.lastCommitSha;
        }
        if (Object.keys(patch).length > 0) {
          await ctx.db.patch(row._id, patch);
        }
        return row._id;
      }
      return await ctx.db.insert("branches", {
        repo,
        name: b.name,
        userId,
        teamId,
        lastCommitSha: b.lastCommitSha,
        lastActivityAt: b.lastActivityAt ?? now,
      });
    });

    const ids = await Promise.all(ops);
    return ids;
  },
});

// Full replacement mutations (use with caution)
export const replaceAllRepos = authMutation({
  args: {
    teamSlugOrId: v.string(),
    repos: v.array(
      v.object({
        fullName: v.string(),
        org: v.string(),
        name: v.string(),
        gitRemote: v.string(),
        provider: v.optional(v.string()),
      })
    ),
  },
  handler: async (ctx, { teamSlugOrId, repos }) => {
    const userId = ctx.identity.subject;
    const teamId = await getTeamId(ctx, teamSlugOrId);
    // Delete all existing repos
    const existingRepos = await ctx.db
      .query("repos")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId)
      )
      .collect();
    await Promise.all(existingRepos.map((repo) => ctx.db.delete(repo._id)));

    // Insert all new repos
    const now = Date.now();
    const insertedIds = await Promise.all(
      repos.map((repo) =>
        ctx.db.insert("repos", { ...repo, userId, teamId, lastSyncedAt: now })
      )
    );
    return insertedIds;
  },
});
