/**
 * Sync mutations for upserting data from other Convex deployments.
 * Used by scripts/sync-convex-dev.ts
 */

import { v } from "convex/values";
import { internalMutation } from "./_generated/server";
import type { GenericDatabaseWriter } from "convex/server";
import type { DataModel } from "./_generated/dataModel";

// Table names that support syncing
type SyncableTable =
  | "repos"
  | "teams"
  | "users"
  | "teamPermissions"
  | "teamMemberships"
  | "environments"
  | "environmentSnapshotVersions"
  | "pullRequests"
  | "providerConnections"
  | "previewConfigs";

// Index names for each table's unique key lookup
const TABLE_INDEXES: Record<SyncableTable, string> = {
  repos: "by_team_fullName",
  teams: "by_teamId",
  users: "by_userId",
  teamPermissions: "by_team_user_perm",
  teamMemberships: "by_team_user",
  environments: "by_team",
  environmentSnapshotVersions: "by_team_snapshot",
  pullRequests: "by_team_repo_number",
  providerConnections: "by_installationId",
  previewConfigs: "by_team_repo",
};

async function findExisting(
  db: GenericDatabaseWriter<DataModel>,
  tableName: SyncableTable,
  record: Record<string, unknown>,
) {

  // Build the query based on the unique key fields
  switch (tableName) {
    case "repos": {
      return await db
        .query("repos")
        .withIndex("by_team_fullName", (q) =>
          q
            .eq("teamId", record.teamId as string)
            .eq("fullName", record.fullName as string),
        )
        .first();
    }
    case "teams": {
      return await db
        .query("teams")
        .withIndex("by_teamId", (q) => q.eq("teamId", record.teamId as string))
        .first();
    }
    case "users": {
      return await db
        .query("users")
        .withIndex("by_userId", (q) => q.eq("userId", record.userId as string))
        .first();
    }
    case "teamPermissions": {
      return await db
        .query("teamPermissions")
        .withIndex("by_team_user_perm", (q) =>
          q
            .eq("teamId", record.teamId as string)
            .eq("userId", record.userId as string)
            .eq("permissionId", record.permissionId as string),
        )
        .first();
    }
    case "teamMemberships": {
      return await db
        .query("teamMemberships")
        .withIndex("by_team_user", (q) =>
          q
            .eq("teamId", record.teamId as string)
            .eq("userId", record.userId as string),
        )
        .first();
    }
    case "environments": {
      // environments doesn't have a unique index by teamId+name, so we query and filter
      const envs = await db
        .query("environments")
        .withIndex("by_team", (q) => q.eq("teamId", record.teamId as string))
        .collect();
      return envs.find((e) => e.name === record.name) ?? null;
    }
    case "environmentSnapshotVersions": {
      return await db
        .query("environmentSnapshotVersions")
        .withIndex("by_team_snapshot", (q) =>
          q
            .eq("teamId", record.teamId as string)
            .eq("morphSnapshotId", record.morphSnapshotId as string),
        )
        .first();
    }
    case "pullRequests": {
      return await db
        .query("pullRequests")
        .withIndex("by_team_repo_number", (q) =>
          q
            .eq("teamId", record.teamId as string)
            .eq("repoFullName", record.repoFullName as string)
            .eq("number", record.number as number),
        )
        .first();
    }
    case "providerConnections": {
      return await db
        .query("providerConnections")
        .withIndex("by_installationId", (q) =>
          q.eq("installationId", record.installationId as number),
        )
        .first();
    }
    case "previewConfigs": {
      return await db
        .query("previewConfigs")
        .withIndex("by_team_repo", (q) =>
          q
            .eq("teamId", record.teamId as string)
            .eq("repoFullName", record.repoFullName as string),
        )
        .first();
    }
    default:
      return null;
  }
}

export const upsertBatch = internalMutation({
  args: {
    tableName: v.string(),
    records: v.array(v.any()),
    uniqueKey: v.array(v.string()),
  },
  returns: v.object({
    inserted: v.number(),
    updated: v.number(),
  }),
  handler: async (ctx, args) => {
    const { tableName, records } = args;

    // Validate table name
    if (!(tableName in TABLE_INDEXES)) {
      throw new Error(`Unsupported table for sync: ${tableName}`);
    }

    const table = tableName as SyncableTable;
    let inserted = 0;
    let updated = 0;

    for (const record of records) {
      const existing = await findExisting(ctx.db, table, record);

      // Remove any fields that shouldn't be synced
      const cleanRecord = { ...record };

      // Special handling for environmentSnapshotVersions:
      // Look up the environment by teamId + environmentName and use that ID
      if (table === "environmentSnapshotVersions") {
        if ("environmentName" in cleanRecord) {
          const envName = cleanRecord.environmentName as string;
          const teamId = cleanRecord.teamId as string;
          delete cleanRecord.environmentName; // Remove the lookup field
          delete cleanRecord.environmentId; // Remove the source ID

          // Find the environment in destination by teamId + name
          const envs = await ctx.db
            .query("environments")
            .withIndex("by_team", (q) => q.eq("teamId", teamId))
            .collect();
          const destEnv = envs.find((e) => e.name === envName);

          if (destEnv) {
            cleanRecord.environmentId = destEnv._id;
          } else {
            // Skip this record if we can't find the matching environment
            continue;
          }
        } else {
          // No environmentName provided, skip this record
          continue;
        }
      } else {
        // Remove ID references that might not exist in destination
        // These are Convex IDs that are deployment-specific
        if ("environmentId" in cleanRecord) {
          delete cleanRecord.environmentId;
        }
      }

      if ("connectionId" in cleanRecord) {
        delete cleanRecord.connectionId;
      }

      if (existing) {
        // Update existing record
        await ctx.db.patch(existing._id, cleanRecord);
        updated++;
      } else {
        // Insert new record
        await ctx.db.insert(table, cleanRecord as never);
        inserted++;
      }
    }

    return { inserted, updated };
  },
});
