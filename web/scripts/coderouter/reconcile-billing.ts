#!/usr/bin/env bun

import { reconcileStripeSubscriptions } from "../../services/billing/reconcile";

const dryRun = process.argv.includes("--dry-run");
const unknown = process.argv.slice(2).filter((value) => value !== "--dry-run");
if (unknown.length > 0) {
  throw new Error(`Unknown arguments: ${unknown.join(", ")}`);
}

const result = await reconcileStripeSubscriptions({ dryRun });
console.log(JSON.stringify({ dryRun, ...result }, null, 2));
if (result.failed > 0 || result.truncated) process.exitCode = 1;

