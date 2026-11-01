import type { CreateVmOptions } from "freestyle";

/** Freestyle's customer id rule (freestyle@0.2.21 `Customer.customerId`): 1-128 ASCII letters, digits and `_.:@-`. */
const CUSTOMER_ID = /^[A-Za-z0-9_.:@-]{1,128}$/u;

/**
 * The `customer` of a Freestyle VM create: the owning team or user id, so
 * Freestyle's abuse protection tells our customers' VMs apart. Inline, so no
 * separate customer upsert has to exist first, and the id only (no profile
 * data). Empty for a missing or malformed id: the VM is still made, untagged.
 */
export function freestyleCustomer(customerId: string | undefined): Pick<CreateVmOptions, "customer"> {
  return customerId && CUSTOMER_ID.test(customerId) ? { customer: { customerId } } : {};
}
