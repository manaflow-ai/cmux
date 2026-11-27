import type { Vm, VmData } from "freestyle";
import { DELETED_ACCOUNT_ACTOR_ID } from "../../auth/deletedAccount";
import type { ProviderCustomer } from "./types";

/**
 * Freestyle's customer id contract, from its 400 answer to an empty id:
 * "customerId must be 1-128 ASCII letters, digits, or _ . : @ -".
 */
const FREESTYLE_CUSTOMER_ID = /^[A-Za-z0-9_.:@-]{1,128}$/;

/**
 * The customer id Freestyle should record for a machine, or null when there is
 * none to send. An id Freestyle would refuse is dropped rather than sent: the
 * customer tag must never be the reason a create fails. A deleted account's
 * shared-team machines carry a sentinel owner; sending it would make every such
 * machine, across unrelated teams, one Freestyle customer.
 */
export function freestyleCustomerId(customer: ProviderCustomer | undefined): string | null {
  const id = customer?.customerId.trim();
  return id && id !== DELETED_ACCOUNT_ACTOR_ID && FREESTYLE_CUSTOMER_ID.test(id) ? id : null;
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
export type FreestyleWakeCustomerTag = "skipped" | "tagged" | "detached" | "failed";

/**
 * Bring a machine's customer in line with its owner the next time it wakes:
 * tag one created before customer tagging, or clear a deleted account's id
 * from a machine its shared team kept (`customer` null). The wake has already
 * succeeded, so a refused update is reported and the machine stays usable;
 * the next wake, or the backfill, tries again.
 */
export async function tagFreestyleCustomerOnWake(
  vm: Pick<Vm, "update">,
  data: Pick<VmData, "customerId">,
  customer: ProviderCustomer | null | undefined,
  onError: (error: unknown) => void,
): Promise<FreestyleWakeCustomerTag> {
  const customerId = customer === null ? null : freestyleCustomerId(customer);
  const detach = customer === null && !!data.customerId;
  if (!detach && (!customerId || data.customerId === customerId)) return "skipped";
  try {
    await vm.update(detach ? { customerId: null } : { customer: { customerId: customerId! } });
    return detach ? "detached" : "tagged";
  } catch (error) {
    onError(error);
    return "failed";
  }
}
