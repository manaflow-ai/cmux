/**
 * One orphan sweep from CI (cmux-vm.yml action sweep-orphans-production, cmux#35013): the same code the Worker's cron
 * runs (src/upstream/orphan-sweep.ts), against the environment's provider account and database.
 *
 *   CMUX_VM_ENVIRONMENT=production UPSTREAM_API_URL=... CMUX_VM_UPSTREAM_API_KEY=... CMUX_VM_DATABASE_URL=... \
 *     bun scripts/sweep-orphans.ts [--delete]
 *
 * It always lists first and prints every orphan (provider id, cmux id, tenant, state, creation time); with --delete it
 * then deletes them and prints what it deleted. Prints no secret, no database URL and no provider response body; the
 * Actions log of this public repository shows tenants only as a short hash.
 */
import { createHash } from "node:crypto";
import { Effect, Redacted } from "effect";
import { recordedVmIds } from "../src/db/orphans.ts";
import { hyperdriveSqlLayer } from "../src/db/sql.ts";
import { parseEnvironment } from "../src/policy.ts";
import { sweepOrphanVms, type OrphanSweepReport, type OrphanVm } from "../src/upstream/orphan-sweep.ts";

const need = (name: string) => {
  const value = process.env[name]?.trim();
  if (!value) {
    console.error(`::error title=sweep-orphans::${name} is not set`);
    process.exit(1);
  }
  return value;
};

// The raw value, before parseEnvironment: it reads any unknown value (a typo) as production.
const rawEnvironment = need("CMUX_VM_ENVIRONMENT");
if (rawEnvironment !== "staging" && rawEnvironment !== "production") {
  console.error("::error title=sweep-orphans::CMUX_VM_ENVIRONMENT must be exactly staging or production");
  process.exit(1);
}
const environment = parseEnvironment(rawEnvironment);
const config = { baseUrl: need("UPSTREAM_API_URL"), apiKey: Redacted.make(need("CMUX_VM_UPSTREAM_API_KEY")), environment };
const sql = hyperdriveSqlLayer(need("CMUX_VM_DATABASE_URL"));
const remove = process.argv.includes("--delete");

/** A failure prints only its tag, operation and HTTP status: a driver message can name the database host. */
const run = async (dryRun: boolean) => {
  const outcome = await Effect.runPromise(Effect.either(
    sweepOrphanVms(config, { nowMs: Date.now(), dryRun, maxDeletes: 2000, recorded: recordedVmIds }).pipe(Effect.provide(sql)),
  ));
  if (outcome._tag === "Right") return outcome.right;
  const error = outcome.left;
  const status = "status" in error ? ` HTTP ${String(error.status ?? "none")}` : "";
  console.error(`::error title=sweep-orphans::${error._tag} ${error.operation}${status}`);
  process.exit(1);
};

/** Freestyle list price while running (web/services/billing/chiefPricing.ts FREESTYLE_COST_USD). */
const VCPU_HOUR_USD = 0.04032;
const GIB_HOUR_USD = 0.0129;
const hourly = (vm: OrphanVm) => (vm.vcpus ?? 0) * VCPU_HOUR_USD + ((vm.memoryMib ?? 0) / 1024) * GIB_HOUR_USD;

const tenantTag = (tenant: string | null) => (tenant === null ? "(none)" : `t:${createHash("sha256").update(tenant).digest("hex").slice(0, 8)}`);

const print = (label: string, report: OrphanSweepReport) => {
  const running = report.orphans.filter((vm) => vm.state === "running" || vm.state === "starting");
  const usd = running.reduce((sum, vm) => sum + hourly(vm), 0);
  console.log(`${label}: ${report.listed} provider VMs of ${environment} listed${report.complete ? "" : " (listing cut short; run again)"}, ${report.orphans.length} orphans (${running.length} running, about $${usd.toFixed(2)}/hour, $${(usd * 24).toFixed(2)}/day at list price)`);
  const byState = new Map<string, number>();
  for (const vm of report.orphans) byState.set(vm.state, (byState.get(vm.state) ?? 0) + 1);
  for (const [state, count] of byState) console.log(`  state ${state}: ${count}`);
  const byTenant = new Map<string, number>();
  for (const vm of report.orphans) byTenant.set(tenantTag(vm.tenant), (byTenant.get(tenantTag(vm.tenant)) ?? 0) + 1);
  for (const [tenant, count] of byTenant) console.log(`  tenant ${tenant}: ${count}`);
  for (const vm of report.orphans) console.log(`  orphan ${vm.upstreamId} ${vm.cmuxId} tenant=${tenantTag(vm.tenant)} state=${vm.state} vcpus=${vm.vcpus ?? "-"} memoryMib=${vm.memoryMib ?? "-"} created=${vm.createdAt}`);
};

const listing = await run(true);
print("dry run", listing);
if (remove && listing.orphans.length > 0) {
  // The delete run lists again: a VM recorded since the dry run is never deleted.
  const swept = await run(false);
  print("delete run", swept);
  for (const id of swept.deleted) console.log(`  deleted ${id}`);
  // Failed deletes are counted, not named: the next cron run retries them.
  if (swept.failed.length > 0) console.log(`::warning title=sweep-orphans::${swept.failed.length} deletes failed; the Worker's cron retries them`);
  console.log(`deleted ${swept.deleted.length}, failed ${swept.failed.length}`);
  if (swept.failed.length > 0) process.exitCode = 1;
} else if (!remove) {
  console.log("dry run only: dispatch with dry_run=false to delete");
}
