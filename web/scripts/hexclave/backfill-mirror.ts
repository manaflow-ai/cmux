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
 * It uses the webhook's reconcile path (same locks and tombstones), so it is
 * idempotent, safe to rerun, and safe while webhooks arrive. It removes mirror
 * rows Hexclave no longer lists. It never revokes access or invalidates
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
    throw new Error("DATABASE_URL is required unless --dry-run is set");
  }

  const summary = await backfillHexclaveMirror({
    source: createHexclaveServerApi({ projectId, secretServerKey, retries: 8 }),
    store: dryRun ? null : createDrizzleHexclaveMirrorStore(cloudDb),
    concurrency: boundedInteger(values.concurrency, "concurrency", 2, 16),
    // Hexclave caps team pages at 200 and user pages at 1000.
    pageSize: boundedInteger(values["page-size"], "page-size", 200, 200),
    log: (message) => console.error(`[hexclave-backfill] ${message}`),
  });
  console.log(JSON.stringify({ projectId, ...summary }, null, 2));
}

try {
  await main();
} finally {
  await closeCloudDbForTests();
}
