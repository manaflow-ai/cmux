import { getProvider, type ProviderId, type VMProvider } from "./drivers";

/**
 * After an account deletion commits, clear the deleted account's id from the
 * provider customer of every machine a shared team kept. Best effort and
 * never fails the deletion: a machine that could not be cleared is cleared on
 * its next wake or by `scripts/cloud-vm/backfill-freestyle-customers.ts`.
 * Returns how many machines are still to be cleared.
 */
export async function detachDeletedAccountCustomers(
  rows: readonly { readonly provider: ProviderId; readonly providerVmId: string | null }[],
  providerFor: (id: ProviderId) => Pick<VMProvider, "detachCustomer"> = getProvider,
): Promise<number> {
  let pending = 0;
  for (const row of rows) {
    if (!row.providerVmId) continue;
    const provider = providerFor(row.provider);
    if (!provider.detachCustomer) continue;
    try {
      await provider.detachCustomer(row.providerVmId);
    } catch (error) {
      pending += 1;
      console.error("[account] provider customer not cleared after deletion", { providerVmId: row.providerVmId, error });
    }
  }
  return pending;
}
