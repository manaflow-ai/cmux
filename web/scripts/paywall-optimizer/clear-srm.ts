#!/usr/bin/env bun
// Records that a person explained a sample-ratio-mismatch halt, so the
// optimizer's SRM window restarts now and traffic can move again.
//
//   DATABASE_URL=... bun scripts/paywall-optimizer/clear-srm.ts --experiment ios-paywall-v1 --reason "..." --actor you@example.com

import { experimentDefinition } from "../../services/billing/paywall/experiments";
import { databasePaywallExperimentLog } from "../../services/billing/paywall/store";

function option(name: string): string | null {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] ?? null : null;
}

const experiment = option("--experiment");
const reason = option("--reason")?.trim();
const actor = option("--actor")?.trim();
if (!experiment || !experimentDefinition(experiment) || !reason || !actor) {
  console.error("Usage: clear-srm.ts --experiment <key> --reason <explanation> --actor <who>");
  process.exit(2);
}
await databasePaywallExperimentLog().appendChanges([{ experiment, kind: "srm_cleared", variant: null, reason, details: null, actor }]);
console.log(`srm_cleared recorded for ${experiment}`);
process.exit(0);
