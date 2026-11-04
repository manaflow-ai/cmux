#!/usr/bin/env bun
/**
 * Read-only: prints a CSV of running machines whose owner has lapsed, with the
 * owner's email, from the same decision the vm-plan-lapse cron uses. It holds
 * personal data: redirect it to a private file and never commit or paste it.
 *
 * It never pauses: CMUX_VM_PLAN_LAPSE_PAUSE is ignored and no provider is called.
 *
 * Usage (from web/, with the target's DATABASE_URL, Stack and Stripe env exported):
 *   SKIP_ENV_VALIDATION=1 bun scripts/cloud-vm/vm-plan-lapse-report.ts > ~/private/lapsed.csv
 */
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import { getStackServerApp } from "../../app/lib/stack";
import { enforceVmPlanLapse } from "../../services/vms/planLapseJob";
import { VmProviderGateway } from "../../services/vms/providerGateway";
import { VmRepository } from "../../services/vms/repository";

const readOnly = Layer.mergeAll(
  Layer.succeed(VmRepository, {} as never),
  Layer.succeed(VmProviderGateway, {} as never),
);
const { lapsed, ...summary } = await Effect.runPromise(
  enforceVmPlanLapse({ env: { ...process.env, CMUX_VM_PLAN_LAPSE_PAUSE: "" } }).pipe(Effect.provide(readOnly)),
);
if (summary.mode === "off_free_provisioning") {
  console.error("CMUX_VM_ALLOW_FREE_PROVISIONING is on here, so no list was computed: unset it");
  process.exit(1);
}
const app = getStackServerApp();
console.log("email,user_id,provider_vm_id,vm_id");
const emails = new Map<string, string>();
for (const vm of lapsed) {
  if (!emails.has(vm.userId)) emails.set(vm.userId, (await app.getUser(vm.userId))?.primaryEmail ?? "");
  console.log([emails.get(vm.userId), vm.userId, vm.providerVmId, vm.vmId].join(","));
}
console.error(JSON.stringify(summary));
// The database client holds its connections open.
process.exit(0);
