#!/usr/bin/env bun
/**
 * Sync Convex Dev Script
 *
 * Syncs specific tables from one Convex deployment to another.
 * Uses the internal sync mutation to do proper upserts based on unique keys.
 *
 * Usage:
 *   bun run scripts/sync-convex-dev.ts
 *   bun run scripts/sync-convex-dev.ts --source famous-camel-162 --dest polite-canary-804
 *   bun run scripts/sync-convex-dev.ts --tables repos,teams,users
 *
 * Options:
 *   --source <name>    Source deployment name (default: famous-camel-162, production)
 *   --dest <name>      Destination deployment name (default: polite-canary-804, dev)
 *   --tables <list>    Comma-separated list of tables to sync (default: all supported tables)
 *   --dry-run          Show what would be synced without actually syncing
 *   --help, -h         Show this help message
 */

import { spawnSync } from "node:child_process";
import * as path from "node:path";
import process from "node:process";
import "dotenv/config";

// Default deployments
const DEFAULT_SOURCE = "famous-camel-162"; // Production
const DEFAULT_DEST = "polite-canary-804"; // Dev

// Tables to sync by default with their unique key fields
const TABLE_CONFIG: Record<string, { uniqueKey: string[] }> = {
  repos: { uniqueKey: ["teamId", "fullName"] },
  teams: { uniqueKey: ["teamId"] },
  users: { uniqueKey: ["userId"] },
  teamPermissions: { uniqueKey: ["teamId", "userId", "permissionId"] },
  teamMemberships: { uniqueKey: ["teamId", "userId"] },
  environments: { uniqueKey: ["teamId", "name"] },
  environmentSnapshotVersions: { uniqueKey: ["teamId", "morphSnapshotId"] },
  pullRequests: { uniqueKey: ["teamId", "repoFullName", "number"] },
  providerConnections: { uniqueKey: ["installationId"] },
  previewConfigs: { uniqueKey: ["teamId", "repoFullName"] },
};

const DEFAULT_TABLES = Object.keys(TABLE_CONFIG);

interface Options {
  source: string;
  dest: string;
  tables: string[];
  dryRun: boolean;
  batchSize: number;
}

function parseArgs(args: string[]): Options {
  let source = DEFAULT_SOURCE;
  let dest = DEFAULT_DEST;
  let tables = DEFAULT_TABLES;
  let dryRun = false;
  let batchSize = 100;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--source") {
      source = args[++i] ?? DEFAULT_SOURCE;
    } else if (arg?.startsWith("--source=")) {
      source = arg.slice(9);
    } else if (arg === "--dest") {
      dest = args[++i] ?? DEFAULT_DEST;
    } else if (arg?.startsWith("--dest=")) {
      dest = arg.slice(7);
    } else if (arg === "--tables") {
      tables = (args[++i] ?? "").split(",").filter(Boolean);
    } else if (arg?.startsWith("--tables=")) {
      tables = arg.slice(9).split(",").filter(Boolean);
    } else if (arg === "--batch-size") {
      batchSize = parseInt(args[++i] ?? "100", 10);
    } else if (arg?.startsWith("--batch-size=")) {
      batchSize = parseInt(arg.slice(13), 10);
    } else if (arg === "--dry-run") {
      dryRun = true;
    } else if (arg === "--help" || arg === "-h") {
      printUsage();
      process.exit(0);
    } else {
      console.error(`Unknown argument: ${arg}`);
      printUsage();
      process.exit(1);
    }
  }

  return { source, dest, tables, dryRun, batchSize };
}

function printUsage(): void {
  console.log(`
Usage: bun run scripts/sync-convex-dev.ts [options]

Syncs specific tables from one Convex deployment to another using upserts.
No data is deleted - only inserted or updated based on unique keys.

Options:
  --source <name>    Source deployment name (default: ${DEFAULT_SOURCE})
  --dest <name>      Destination deployment name (default: ${DEFAULT_DEST})
  --tables <list>    Comma-separated list of tables to sync
                     Default: ${DEFAULT_TABLES.join(",")}
  --batch-size <n>   Number of records to upsert per batch (default: 100)
  --dry-run          Show what would be synced without actually syncing
  --help, -h         Show this help message

Examples:
  # Sync all default tables from production to dev
  bun run scripts/sync-convex-dev.ts

  # Sync only specific tables
  bun run scripts/sync-convex-dev.ts --tables repos,teams,users

  # Sync to a different destination
  bun run scripts/sync-convex-dev.ts --dest my-dev-deployment

  # Preview what would be synced
  bun run scripts/sync-convex-dev.ts --dry-run
`);
}

function runConvexCommand(
  args: string[],
  options?: { cwd?: string; deployKey?: string },
): { success: boolean; stdout: string; stderr: string } {
  const env = { ...process.env };
  if (options?.deployKey) {
    env.CONVEX_DEPLOY_KEY = options.deployKey;
  }

  const result = spawnSync("bunx", ["convex", ...args], {
    encoding: "utf-8",
    cwd: options?.cwd ?? path.join(process.cwd(), "packages/convex"),
    stdio: ["pipe", "pipe", "pipe"],
    maxBuffer: 100 * 1024 * 1024, // 100MB buffer for large tables
    env,
  });

  return {
    success: result.status === 0,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
  };
}

// Get deploy key for a deployment
function getDeployKey(deploymentName: string): string | undefined {
  // Map deployment names to environment variable names
  const keyMap: Record<string, string> = {
    "famous-camel-162": "CONVEX_DEPLOY_KEY_FAMOUS_CAMEL",
    "polite-canary-804": "CONVEX_DEPLOY_KEY", // Default dev key
  };

  const envVarName = keyMap[deploymentName];
  if (envVarName) {
    return process.env[envVarName];
  }
  return undefined;
}

interface TableRecord {
  _id: string;
  _creationTime: number;
  [key: string]: unknown;
}

async function exportTable(
  deploymentName: string,
  tableName: string,
): Promise<{ success: boolean; records: TableRecord[]; error?: string }> {
  const deployKey = getDeployKey(deploymentName);

  // Use convex data command to export table data as JSONL
  const result = runConvexCommand(
    [
      "data",
      tableName,
      "--deployment-name",
      deploymentName,
      "--format",
      "jsonl",
      "--limit",
      "8000", // Convex has a limit on query results
      "--order",
      "asc", // Get oldest first for consistent ordering
    ],
    { deployKey },
  );

  if (!result.success) {
    return {
      success: false,
      records: [],
      error: result.stderr || "Failed to export table",
    };
  }

  // Parse the JSONL output
  const lines = result.stdout.trim().split("\n").filter(Boolean);
  const records: TableRecord[] = [];

  for (const line of lines) {
    try {
      const record = JSON.parse(line) as TableRecord;
      records.push(record);
    } catch {
      // Skip invalid lines
    }
  }

  return {
    success: true,
    records,
  };
}

async function upsertBatch(
  deploymentName: string,
  tableName: string,
  records: TableRecord[],
  uniqueKey: string[],
): Promise<{ success: boolean; inserted: number; updated: number; error?: string }> {
  const deployKey = getDeployKey(deploymentName);

  // Prepare records for upsert (remove _id and _creationTime)
  const cleanedRecords = records.map((record) => {
    const { _id, _creationTime, ...rest } = record;
    return rest;
  });

  // Call the sync mutation
  const args = JSON.stringify({
    tableName,
    records: cleanedRecords,
    uniqueKey,
  });

  const result = runConvexCommand(
    [
      "run",
      "sync:upsertBatch",
      args,
      "--deployment-name",
      deploymentName,
    ],
    { deployKey },
  );

  if (!result.success) {
    return {
      success: false,
      inserted: 0,
      updated: 0,
      error: result.stderr || "Failed to upsert batch",
    };
  }

  // Parse the result
  try {
    const output = JSON.parse(result.stdout.trim());
    return {
      success: true,
      inserted: output.inserted ?? 0,
      updated: output.updated ?? 0,
    };
  } catch {
    return {
      success: true,
      inserted: 0,
      updated: records.length, // Assume all updated if can't parse
    };
  }
}

// Cache for environment lookups (environmentId -> {teamId, name})
let environmentCache: Map<string, { teamId: string; name: string }> | null = null;

async function buildEnvironmentCache(source: string): Promise<Map<string, { teamId: string; name: string }>> {
  if (environmentCache) {
    return environmentCache;
  }

  const exportResult = await exportTable(source, "environments");
  if (!exportResult.success) {
    throw new Error(`Failed to export environments: ${exportResult.error}`);
  }

  environmentCache = new Map();
  for (const env of exportResult.records) {
    environmentCache.set(env._id, {
      teamId: env.teamId as string,
      name: env.name as string,
    });
  }

  return environmentCache;
}

async function syncTable(
  source: string,
  dest: string,
  tableName: string,
  batchSize: number,
  dryRun: boolean,
): Promise<{ success: boolean; exported: number; inserted: number; updated: number; error?: string }> {
  const config = TABLE_CONFIG[tableName];
  if (!config) {
    return {
      success: false,
      exported: 0,
      inserted: 0,
      updated: 0,
      error: `Unknown table: ${tableName}. Add it to TABLE_CONFIG.`,
    };
  }

  // Export from source
  const exportResult = await exportTable(source, tableName);
  if (!exportResult.success) {
    return {
      success: false,
      exported: 0,
      inserted: 0,
      updated: 0,
      error: exportResult.error,
    };
  }

  let { records } = exportResult;

  // Special handling for environmentSnapshotVersions:
  // Replace environmentId with environmentName so the destination can look it up
  if (tableName === "environmentSnapshotVersions") {
    try {
      const envCache = await buildEnvironmentCache(source);
      records = records.map((record) => {
        const envId = record.environmentId as string;
        const env = envCache.get(envId);
        if (env) {
          return {
            ...record,
            environmentName: env.name, // Add environment name for lookup
          };
        }
        return record;
      });
    } catch (err) {
      return {
        success: false,
        exported: 0,
        inserted: 0,
        updated: 0,
        error: `Failed to build environment cache: ${err}`,
      };
    }
  }

  if (dryRun) {
    return {
      success: true,
      exported: records.length,
      inserted: 0,
      updated: 0,
    };
  }

  // Upsert in batches
  let totalInserted = 0;
  let totalUpdated = 0;

  for (let i = 0; i < records.length; i += batchSize) {
    const batch = records.slice(i, i + batchSize);
    const result = await upsertBatch(dest, tableName, batch, config.uniqueKey);

    if (!result.success) {
      return {
        success: false,
        exported: records.length,
        inserted: totalInserted,
        updated: totalUpdated,
        error: result.error,
      };
    }

    totalInserted += result.inserted;
    totalUpdated += result.updated;
  }

  return {
    success: true,
    exported: records.length,
    inserted: totalInserted,
    updated: totalUpdated,
  };
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));

  // Validate deploy keys are available
  const sourceKey = getDeployKey(options.source);
  const destKey = getDeployKey(options.dest);

  if (!sourceKey) {
    console.error(`❌ Missing deploy key for source deployment: ${options.source}`);
    console.error(`   Set the appropriate environment variable (e.g., CONVEX_DEPLOY_KEY_FAMOUS_CAMEL)`);
    process.exit(1);
  }

  if (!destKey) {
    console.error(`❌ Missing deploy key for destination deployment: ${options.dest}`);
    console.error(`   Set the appropriate environment variable (e.g., CONVEX_DEPLOY_KEY)`);
    process.exit(1);
  }

  console.log(`
╔════════════════════════════════════════════════════════════╗
║                    Convex Dev Sync                          ║
╠════════════════════════════════════════════════════════════╣
║  Source: ${options.source.padEnd(47)}║
║  Dest:   ${options.dest.padEnd(47)}║
║  Tables: ${options.tables.length.toString().padEnd(47)}║
╚════════════════════════════════════════════════════════════╝
`);

  if (options.dryRun) {
    console.log("🔍 DRY RUN - No changes will be made\n");
  }

  console.log(`📊 Syncing tables: ${options.tables.join(", ")}\n`);

  // Sync tables (could parallelize but keeping sequential for clearer output)
  const results: Array<{
    table: string;
    success: boolean;
    exported: number;
    inserted: number;
    updated: number;
    error?: string;
  }> = [];

  for (const table of options.tables) {
    process.stdout.write(`   ${table}... `);

    const result = await syncTable(
      options.source,
      options.dest,
      table,
      options.batchSize,
      options.dryRun,
    );

    results.push({ table, ...result });

    if (result.success) {
      if (options.dryRun) {
        console.log(`✅ ${result.exported} records to sync`);
      } else {
        console.log(`✅ ${result.exported} exported, ${result.inserted} inserted, ${result.updated} updated`);
      }
    } else {
      console.log(`❌ ${result.error}`);
    }
  }

  // Summary
  const successful = results.filter((r) => r.success);
  const failed = results.filter((r) => !r.success);
  const totalExported = successful.reduce((sum, r) => sum + r.exported, 0);
  const totalInserted = successful.reduce((sum, r) => sum + r.inserted, 0);
  const totalUpdated = successful.reduce((sum, r) => sum + r.updated, 0);

  console.log("\n" + "═".repeat(60));
  console.log("📊 Summary:");
  console.log(`   Tables processed: ${options.tables.length}`);
  console.log(`   Successful: ${successful.length}`);
  console.log(`   Failed: ${failed.length}`);
  console.log(`   Total records exported: ${totalExported}`);
  if (!options.dryRun) {
    console.log(`   Total inserted: ${totalInserted}`);
    console.log(`   Total updated: ${totalUpdated}`);
  }
  console.log("═".repeat(60));

  if (failed.length > 0) {
    console.log("\n❌ Failed tables:");
    for (const f of failed) {
      console.log(`   - ${f.table}: ${f.error}`);
    }
  }

  if (options.dryRun) {
    console.log("\n✨ Dry run complete. No changes were made.\n");
  } else {
    console.log("\n✅ Sync complete!\n");
  }
}

main().catch((err) => {
  console.error("Unexpected error:", err);
  process.exit(1);
});
