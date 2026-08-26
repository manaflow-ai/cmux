#!/usr/bin/env bun

import { reconcileStripeSubscriptions } from "../../services/billing/reconcile";
import { captureCoderouterError } from "../../services/errors";

const dryRun = process.argv.includes("--dry-run");
const unknown = process.argv.slice(2).filter((value) => value !== "--dry-run");
if (unknown.length > 0) {
  console.error("Unknown arguments. Use --dry-run or no arguments.");
  process.exit(2);
}

try {
  const result = await reconcileStripeSubscriptions({ dryRun });
  console.log(JSON.stringify({ dryRun, ...result }, null, 2));
  if (result.failed > 0 || result.truncated) process.exitCode = 1;
} catch (error) {
  captureCoderouterError(error, {
    operation: "stripe_subscription_reconcile_command",
    recoverable: true,
  });
  console.error(
    "Billing reconciliation did not complete. Check internal telemetry and retry.",
  );
  process.exitCode = 1;
}
