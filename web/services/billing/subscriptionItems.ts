/**
 * The plan item of a Stripe subscription: the first item whose price is not
 * metered. A subscription may also carry metered usage items (usage billing,
 * cx-y79zh); those never hold the plan's price, seats or lookup key, so code
 * that asks "which plan, how many seats, which period" reads this item, never
 * `items.data[0]`. Items without a price (old or partial data) count as plan
 * items. Returns undefined when every item is metered.
 */
export type SubscriptionItemLike = {
  readonly price?: { readonly recurring?: { readonly usage_type?: string | null } | null } | null;
};

export function planItem<T extends SubscriptionItemLike>(
  subscription: { readonly items?: { readonly data?: readonly T[] | null } | null } | null | undefined,
): T | undefined {
  // Stored raw payloads are untrusted JSON: anything but an array has no plan item.
  const data: unknown = subscription?.items?.data;
  if (!Array.isArray(data)) return undefined;
  return (data as readonly T[]).find((item) => item?.price?.recurring?.usage_type !== "metered");
}

/**
 * The same rule in SQL for a stored `raw` subscription payload (jsonb): the first item whose price
 * is not metered. An item without `price.recurring.usage_type` counts as a plan item.
 */
export const PLAN_ITEM_JSONPATH = '$.items.data[*] ? (!exists(@.price.recurring.usage_type ? (@ == "metered")))';
