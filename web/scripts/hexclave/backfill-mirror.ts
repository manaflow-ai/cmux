#!/usr/bin/env bun
/**
 * Backfill the Hexclave mirror tables (hexclave_users, hexclave_teams,
 * hexclave_team_memberships, hexclave_team_permissions,
 * hexclave_project_permissions) from the Hexclave server API.
 *
 * Usage, from web/:
 *
 *   DATABASE_URL=postgres://... \
 *   NEXT_PUBLIC_STACK_PROJECT_ID=<project id> \
 *   STACK_SECRET_SERVER_KEY=<server key> \
 *   bun run hexclave:backfill-mirror -- [--dry-run] [--concurrency 2] [--page-size 200]
 *
 * It reads in bulk (team and user pages, one member list per team, one
 * project-wide call each for team and project permissions) and writes under
 * the webhook's locks, skipping any entity a webhook wrote after the snapshot
 * started. It is idempotent, safe to rerun, and safe while webhooks arrive. It
 * removes mirror rows Hexclave no longer lists. It never revokes access or invalidates
 * identity snapshots. `--dry-run` makes and validates every Hexclave read but
 * does not open the database. The mirror migration must be applied first.
 */
import { parseArgs } from "node:util";
import { cloudDb, closeCloudDbForTests } from "../../db/client";
import { backfillHexclaveMirror } from "../../services/auth/hexclave/backfill";
import { createDrizzleHexclaveMirrorStore } from "../../services/auth/hexclave/mirrorStore";
import { createHexclaveServerApi } from "../../services/auth/hexclave/serverApi";

function boundedInteger(raw: string | undefined, name: string, fallback: number, max: number): number {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1 || value > max) throw new Error(`--${name} must be an integer from 1 to ${max}`);
  return value;
}

async function main(): Promise<void> {
  const { values } = parseArgs({
    options: {
      "dry-run": { type: "boolean", default: false },
      concurrency: { type: "string" },
      "page-size": { type: "string" },
    },
    strict: true,
  });
  const projectId = process.env.NEXT_PUBLIC_STACK_PROJECT_ID?.trim() || process.env.STACK_PROJECT_ID?.trim();
  const secretServerKey = process.env.STACK_SECRET_SERVER_KEY?.trim();
  if (!projectId || !secretServerKey) {
    throw new Error("NEXT_PUBLIC_STACK_PROJECT_ID (or STACK_PROJECT_ID) and STACK_SECRET_SERVER_KEY are required");
  }
  const dryRun = values["dry-run"] === true;
  if (!dryRun && !process.env.DATABASE_URL?.trim() && !process.env.DIRECT_DATABASE_URL?.trim()) {
    throw new Error("DATABASE_URL or DIRECT_DATABASE_URL is required unless --dry-run is set");
  }

  let apiRequests = 0;
  let rateLimited = 0;
  const countingFetch: typeof fetch = async (input, init) => {
    apiRequests += 1;
    const response = await fetch(input, init);
    if (response.status === 429) rateLimited += 1;
    return response;
  };
  const startedAt = performance.now();
  const summary = await backfillHexclaveMirror({
    source: createHexclaveServerApi({ projectId, secretServerKey, retries: 8, fetch: countingFetch }),
    // The prune pass reads under a mirror lock: one attempt, no backoff.
    reconcileSource: createHexclaveServerApi({ projectId, secretServerKey, retries: 0, timeoutMs: 5_000, fetch: countingFetch }),
    store: dryRun ? null : createDrizzleHexclaveMirrorStore(cloudDb),
    concurrency: boundedInteger(values.concurrency, "concurrency", 2, 16),
    // Hexclave caps team pages at 200 and user pages at 1000.
    pageSize: boundedInteger(values["page-size"], "page-size", 200, 200),
    log: (message) => console.error(`[hexclave-backfill] ${message}`),
  });
  const elapsedSeconds = Math.round((performance.now() - startedAt) / 100) / 10;
  console.log(JSON.stringify({ projectId, ...summary, apiRequests, rateLimited, elapsedSeconds }, null, 2));
}

try {
  await main();
} finally {
  await closeCloudDbForTests();
}
