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
  return subscription?.items?.data?.find((item) => item?.price?.recurring?.usage_type !== "metered");
}
