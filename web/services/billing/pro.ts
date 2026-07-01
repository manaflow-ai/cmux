// cmux Pro subscription helpers.
//
// The `pro` product (user-scoped, product line `cmux-pro`) lives in the Stack
// Auth project config, not in this repo. Prices: yearly $240 (listed first so
// the hosted purchase page pre-selects it) and monthly $30.
//
// VM entitlements (services/vms/auth.ts) read the plan id from the user's
// `clientReadOnlyMetadata.cmuxPlan`, so syncing that key after a verified
// purchase is what upgrades Cloud VM limits — no VM code changes needed.
// `cmuxVmPlan` takes precedence over `cmuxPlan` there and is left untouched
// here so manual overrides survive.

export const PRO_PRODUCT_ID = "pro";
export const PRO_PLAN_ID = "pro";
export const PRO_ACCESS_ITEM_ID = "cmux-pro-access";

const PRODUCTS_PAGE_LIMIT = 50;
const MAX_PRODUCT_PAGES = 10;

type CustomerProductLike = {
  readonly id: string | null;
  readonly quantity: number;
  readonly subscription: null | {
    readonly cancelAtPeriodEnd: boolean;
    readonly currentPeriodEnd: Date | null;
  };
};

type ProductsPage = readonly CustomerProductLike[] & {
  readonly nextCursor: string | null;
};

export type ProductsCustomer = {
  listProducts(options?: {
    cursor?: string;
    limit?: number;
  }): Promise<ProductsPage>;
};

// Mirrors Stack's ReadonlyJson so ServerUser.update stays assignable.
export type ProMetadataJson =
  | null
  | boolean
  | number
  | string
  | readonly ProMetadataJson[]
  | { readonly [key: string]: ProMetadataJson };

export type ProMetadataCustomer = {
  readonly clientReadOnlyMetadata?: unknown;
  update(options: {
    clientReadOnlyMetadata: ProMetadataJson;
  }): Promise<unknown>;
};

/**
 * True when the customer owns the `pro` product, either through an active
 * subscription (including one set to cancel at period end — access lasts
 * until the period actually ends) or a manual `grantProduct` comp
 * (subscription null, quantity > 0).
 */
export async function hasActiveProSubscription(
  customer: ProductsCustomer,
): Promise<boolean> {
  let cursor: string | undefined;
  for (let page = 0; page < MAX_PRODUCT_PAGES; page++) {
    const products = await customer.listProducts({
      cursor,
      limit: PRODUCTS_PAGE_LIMIT,
    });
    for (const product of products) {
      if (product.id !== PRO_PRODUCT_ID) continue;
      if (product.subscription !== null) return true;
      if (product.quantity > 0) return true;
    }
    if (!products.nextCursor) return false;
    cursor = products.nextCursor;
  }
  return false;
}

/**
 * Writes `cmuxPlan: "pro"` into the user's clientReadOnlyMetadata when Pro is
 * active, and removes it when Pro lapsed. No-op when already in sync.
 */
export async function syncProPlanMetadata(
  user: ProMetadataCustomer,
  isPro: boolean,
): Promise<void> {
  const raw = user.clientReadOnlyMetadata;
  const metadata: Record<string, unknown> =
    raw && typeof raw === "object" && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {};
  const current = metadata.cmuxPlan;

  if (isPro) {
    if (current === PRO_PLAN_ID) return;
    metadata.cmuxPlan = PRO_PLAN_ID;
  } else {
    if (current !== PRO_PLAN_ID) return;
    delete metadata.cmuxPlan;
  }
  // Existing metadata came from Stack as JSON; the only value added is a string.
  await user.update({ clientReadOnlyMetadata: metadata as ProMetadataJson });
}
