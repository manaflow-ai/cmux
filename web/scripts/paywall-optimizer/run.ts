#!/usr/bin/env bun
// Paywall optimizer (services/billing/paywall/EXPERIMENTS.md).
//
//   POSTHOG_PERSONAL_API_KEY=phx_... bun scripts/paywall-optimizer/run.ts --dry-run
//   POSTHOG_PERSONAL_API_KEY=phx_... DATABASE_URL=... bun scripts/paywall-optimizer/run.ts
//
// --dry-run prints the decision and report and writes nothing (no flag
// change, no database row). Without it the run writes the new traffic split
// to the PostHog flag and the change log and report to the database; the
// daily `paywall-optimizer` cron does the same.
// --experiment <key> limits the run to one experiment. --report-dir <dir>
// also writes each report as <dir>/<experiment>-<date>.md.

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { experimentDefinition, PAYWALL_EXPERIMENTS } from "../../services/billing/paywall/experiments";
import { optimizerPostHogApi, runAllOptimizers } from "../../services/billing/paywall/runAll";

function option(name: string): string | null {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] ?? null : null;
}

const dryRun = process.argv.includes("--dry-run");
const experimentKey = option("--experiment");
const reportDir = option("--report-dir");
const api = optimizerPostHogApi(process.env);
if (!api) {
  console.error("POSTHOG_PERSONAL_API_KEY is required (a personal API key with project read and feature flag write).");
  process.exit(2);
}
const experiments = experimentKey ? [experimentDefinition(experimentKey)].filter((item) => item !== null) : PAYWALL_EXPERIMENTS;
if (experiments.length === 0) {
  console.error(`Unknown experiment ${experimentKey}`);
  process.exit(2);
}
const log = dryRun ? null : (await import("../../services/billing/paywall/store")).databasePaywallExperimentLog();
const now = new Date();
const outcomes = await runAllOptimizers({ api, log, dryRun, now, actor: dryRun ? "optimizer-dry-run" : "optimizer-cli", experiments });
let failed = false;
for (const outcome of outcomes) {
  if (!outcome.ok) {
    failed = true;
    console.error(`${outcome.experiment}: ${outcome.error}`);
    continue;
  }
  console.log(outcome.result.report);
  console.log(JSON.stringify({ experiment: outcome.experiment, dryRun, target: outcome.result.snapshot.decision.target, changed: outcome.result.snapshot.decision.changed, halted: outcome.result.snapshot.decision.halted }));
  if (reportDir) {
    await mkdir(reportDir, { recursive: true });
    await writeFile(join(reportDir, `${outcome.experiment}-${now.toISOString().slice(0, 10)}.md`), outcome.result.report);
  }
}
process.exit(failed ? 1 : 0);
