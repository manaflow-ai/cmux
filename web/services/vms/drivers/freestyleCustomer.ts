import type { Vm, VmData } from "freestyle";
import type { ProviderCustomer } from "./types";

/**
 * Freestyle's customer id contract, from its 400 answer to an empty id:
 * "customerId must be 1-128 ASCII letters, digits, or _ . : @ -".
 */
const FREESTYLE_CUSTOMER_ID = /^[A-Za-z0-9_.:@-]{1,128}$/;

/**
 * The customer id Freestyle should record for a machine, or null when there is
 * none to send. An id Freestyle would refuse is dropped rather than sent: the
 * customer tag must never be the reason a create fails.
 */
export function freestyleCustomerId(customer: ProviderCustomer | undefined): string | null {
  const id = customer?.customerId.trim();
  return id && FREESTYLE_CUSTOMER_ID.test(id) ? id : null;
}

/**
 * The create-request fragment that tags a new machine with its owner. An
 * inline `customer` upserts the customer record in the same call, so the first
 * machine of a new account needs no separate customer write.
 */
export function freestyleCreateCustomer(customer: ProviderCustomer | undefined): { customer?: { customerId: string } } {
  const customerId = freestyleCustomerId(customer);
  return customerId ? { customer: { customerId } } : {};
}

/** What a wake did about the machine's customer. */
export type FreestyleWakeCustomerTag = "skipped" | "tagged" | "failed";

/**
 * Tag a machine created before customer tagging the next time it wakes. The
 * wake has already succeeded, so a refused update is reported and the machine
 * stays usable; the next wake, or the backfill, tries again.
 */
export async function tagFreestyleCustomerOnWake(
  vm: Pick<Vm, "update">,
  data: Pick<VmData, "customerId">,
  customer: ProviderCustomer | undefined,
  onError: (error: unknown) => void,
): Promise<FreestyleWakeCustomerTag> {
  const customerId = freestyleCustomerId(customer);
  if (!customerId || data.customerId === customerId) return "skipped";
  try {
    await vm.update({ customer: { customerId } });
    return "tagged";
  } catch (error) {
    onError(error);
    return "failed";
  }
}
