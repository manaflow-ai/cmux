import { afterEach, beforeEach, describe, expect, mock, test } from "bun:test";

type Configuration = { id: string; metadata: Record<string, string | undefined> };
const listConfigurations = mock(async (..._args: unknown[]) => ({ data: [] as Configuration[] }));
const createConfiguration = mock(async (..._args: unknown[]) => ({ id: "bpc_next_new" }));
const createSession = mock(async (..._args: unknown[]) => ({ url: "https://billing.stripe.com/p/session/x" }));
const retrievePrice = mock(async (id: string) => ({ id, product: `prod_${id}` }));
const resolveNextPlanPrice = mock(async (plan: string) => `price_${plan}`);

mock.module("../services/billing/stripe", () => ({
  resolveNextPlanPrice,
  stripe: () => ({
    billingPortal: { configurations: { list: listConfigurations, create: createConfiguration }, sessions: { create: createSession } },
    prices: { retrieve: retrievePrice },
  }),
}));

const { nextPlanSwitchPortalSession, resetNextPlanSwitchCacheForTests, resolveNextPlanSwitchPortalConfiguration } = await import("../services/billing/nextPlanSwitch");

const ENV = ["STRIPE_PRICE_NEXT_PLUS_MONTHLY", "STRIPE_PRICE_NEXT_PRO_MONTHLY", "STRIPE_PRICE_NEXT_MAX_MONTHLY"] as const;

describe("NEXT plan switch portal configuration", () => {
  beforeEach(() => {
    for (const name of ENV) process.env[name] = `configured_${name}`;
    resetNextPlanSwitchCacheForTests();
    for (const fn of [listConfigurations, createConfiguration, createSession, retrievePrice]) fn.mockClear();
    listConfigurations.mockImplementation(async () => ({ data: [] as Configuration[] }));
  });
  afterEach(() => {
    for (const name of ENV) delete process.env[name];
  });

  test("creates one from the NEXT Prices for sale when none exists, then reuses it", async () => {
    const id = await resolveNextPlanSwitchPortalConfiguration();
    expect(id).toBe("bpc_next_new");
    const params = createConfiguration.mock.calls[0]![0] as {
      features: { subscription_update: { default_allowed_updates: string[]; products: Array<{ product: string; prices: string[] }> } };
      metadata: Record<string, string>;
    };
    expect(params.features.subscription_update.default_allowed_updates).toEqual(["price"]);
    expect(params.features.subscription_update.products).toEqual([
      { product: "prod_price_next_plus", prices: ["price_next_plus"], adjustable_quantity: { enabled: false } },
      { product: "prod_price_next_pro", prices: ["price_next_pro"], adjustable_quantity: { enabled: false } },
      { product: "prod_price_next_max", prices: ["price_next_max"], adjustable_quantity: { enabled: false } },
    ] as never);
    expect(params.metadata).toEqual({ app: "cmux", purpose: "next_plan_switch", prices: "price_next_plus,price_next_pro,price_next_max" });
    expect(await resolveNextPlanSwitchPortalConfiguration()).toBe("bpc_next_new");
    expect(createConfiguration).toHaveBeenCalledTimes(1);
  });

  test("finds an existing configuration for the same Prices instead of creating one", async () => {
    delete process.env.STRIPE_PRICE_NEXT_MAX_MONTHLY;
    listConfigurations.mockImplementation(async () => ({
      data: [
        { id: "bpc_other", metadata: { app: "cmux", purpose: "personal_plan_switch" } },
        { id: "bpc_next_existing", metadata: { app: "cmux", purpose: "next_plan_switch", prices: "price_next_plus,price_next_pro" } },
      ],
    }));
    expect(await resolveNextPlanSwitchPortalConfiguration()).toBe("bpc_next_existing");
    expect(createConfiguration).not.toHaveBeenCalled();
  });

  test("the session opens the subscription-update flow on the subscriber's subscription", async () => {
    await nextPlanSwitchPortalSession({ customerId: "cus_1", subscriptionId: "sub_1", origin: "https://cmux.test" });
    expect(createSession.mock.calls[0]![0]).toMatchObject({
      customer: "cus_1",
      return_url: "https://cmux.test/dashboard/billing",
      flow_data: { type: "subscription_update", subscription_update: { subscription: "sub_1" } },
    });
  });
});
