import { beforeEach, describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";
import type Stripe from "stripe";

import { makeStripeWebhookHandler } from "../app/api/stripe/webhook/route";
import {
  cloudIntroCheckoutParams,
  cloudIntroCheckoutResponse,
  resetCloudIntroPriceCacheForTests,
  type CloudIntroCheckoutDependencies,
} from "../services/billing/cloudIntroCheckout";
import {
  fulfillCloudIntroCheckout,
  type CloudIntroFulfillmentDependencies,
} from "../services/billing/cloudIntroFulfillment";
import type {
  CloudIntroAccountFacts,
  CloudIntroPass,
  CloudIntroPassStore,
  CloudIntroStoreFacts,
} from "../services/billing/cloudIntroPasses";
import { cloudIntroUtcDayStart, type CloudIntroRefusal } from "../services/billing/cloudIntro";
import { memoryStripeWebhookInbox } from "./helpers/stripe-webhook-inbox-memory";

const ON = { CMUX_CLOUD_INTRO: "1" };
const OFF = { NODE_ENV: "production", VERCEL_ENV: "production" };
const NOW = new Date("2026-11-23T12:00:00.000Z");

type Row = {
  checkoutSessionId: string;
  stackUserId: string;
  stackTeamIds: string[];
  status: CloudIntroPass["status"];
  refusal: CloudIntroRefusal | null;
  paymentIntentId: string | null;
  refundId: string | null;
  renewOnPlus: boolean;
  cardFingerprint: string | null;
  paymentMethodId: string | null;
  startedAt: Date | null;
  endsAt: Date | null;
};

/** The store contract of cloudIntroPasses.ts, in memory. */
function memoryStore() {
  const rows = new Map<string, Row>();
  const facts = (input: {
    stackUserId: string;
    stackTeamIds: readonly string[];
    now: Date;
    exclude: string | null;
    cardFingerprint: string | null;
  }): CloudIntroStoreFacts => {
    const others = [...rows.values()].filter((row) => row.checkoutSessionId !== input.exclude);
    const granted = others.filter((row) => row.status === "granted");
    const dayStart = cloudIntroUtcDayStart(input.now).getTime();
    return {
      hadPass: granted.some((row) => row.stackUserId === input.stackUserId),
      teamHadPass: granted.some((row) =>
        row.stackUserId !== input.stackUserId && row.stackTeamIds.some((id) => input.stackTeamIds.includes(id))),
      cardFingerprintUsed: Boolean(input.cardFingerprint) &&
        granted.some((row) => row.cardFingerprint === input.cardFingerprint),
      grantedToday: granted.filter((row) => (row.startedAt?.getTime() ?? 0) >= dayStart).length,
      grantedTotal: granted.length,
      cardAttempts: others.filter((row) => row.stackUserId === input.stackUserId).length,
    };
  };
  const pass = (row: Row): CloudIntroPass => ({ ...row });
  const open = (id: string, stackUserId: string, stackTeamIds: readonly string[], renewOnPlus: boolean): Row => ({
    checkoutSessionId: id, stackUserId, stackTeamIds: [...stackTeamIds], status: "open", refusal: null,
    paymentIntentId: null, refundId: null, renewOnPlus, cardFingerprint: null, paymentMethodId: null,
    startedAt: null, endsAt: null,
  });
  const store: CloudIntroPassStore = {
    async checkoutFacts({ stackUserId, stackTeamIds, now }) {
      return facts({ stackUserId, stackTeamIds, now, exclude: null, cardFingerprint: null });
    },
    async recordCheckout(record) {
      if (!rows.has(record.checkoutSessionId)) {
        rows.set(record.checkoutSessionId, open(record.checkoutSessionId, record.stackUserId, record.stackTeamIds, record.renewOnPlus));
      }
    },
    async settle(input, judge) {
      const row = rows.get(input.checkoutSessionId) ??
        open(input.checkoutSessionId, input.stackUserId, input.stackTeamIds, input.renewOnPlus);
      rows.set(row.checkoutSessionId, row);
      if (row.status !== "open") return pass(row);
      const refusal = judge(facts({
        stackUserId: input.stackUserId,
        stackTeamIds: input.stackTeamIds,
        now: input.startedAt,
        exclude: input.checkoutSessionId,
        cardFingerprint: input.cardFingerprint,
      }));
      Object.assign(row, {
        status: refusal ? "refused" : "granted",
        refusal,
        paymentIntentId: input.paymentIntentId,
        cardFingerprint: input.cardFingerprint,
        paymentMethodId: refusal ? null : input.paymentMethodId,
        startedAt: refusal ? null : input.startedAt,
        endsAt: refusal ? null : input.endsAt,
      });
      return pass(row);
    },
    async markRefunded(id, refundId) {
      const row = rows.get(id);
      if (row) row.refundId = refundId;
    },
  };
  return { rows, store };
}

const noHistory: CloudIntroAccountFacts = { hadPaidPlan: false, isTeamSeat: false, stackTeamIds: [] };

function paidSession(id: string, options: {
  stackUserId?: string;
  funding?: string;
  fingerprint?: string;
  renewOnPlus?: boolean;
  amount?: number;
  paymentStatus?: string;
} = {}) {
  return {
    id,
    mode: "payment",
    payment_status: options.paymentStatus ?? "paid",
    amount_total: options.amount ?? 100,
    currency: "usd",
    customer: "cus_1",
    metadata: {
      app: "cmux",
      purpose: "cloud_intro",
      plan: "intro",
      stackUserId: options.stackUserId ?? "user_1",
      renewOnPlus: options.renewOnPlus ? "true" : "false",
    },
    payment_intent: {
      id: `pi_${id}`,
      status: "succeeded",
      payment_method: "pm_1",
      latest_charge: {
        id: `ch_${id}`,
        payment_method_details: {
          card: { funding: options.funding ?? "credit", fingerprint: options.fingerprint ?? "fp_1" },
        },
      },
    },
  };
}

function fulfillmentHarness(env: Record<string, string | undefined> = ON) {
  const memory = memoryStore();
  const sessions = new Map<string, unknown>();
  const retrieve = mock(async (id: string) => sessions.get(id));
  const refundCreate = mock(async (_params: unknown, _options: unknown) => ({ id: `re_${refundCreate.mock.calls.length}` }));
  const writeGrant = mock(async (_userId: string, _term: unknown) => true);
  let account = noHistory;
  let now = NOW;
  const dependencies: CloudIntroFulfillmentDependencies = {
    env,
    now: () => now,
    stripe: () => ({ checkout: { sessions: { retrieve } }, refunds: { create: refundCreate } }) as never,
    store: memory.store,
    loadUser: async (id) => ({ id }),
    accountFacts: async () => account,
    writeGrant,
  };
  return {
    ...memory,
    sessions,
    retrieve,
    refundCreate,
    writeGrant,
    dependencies,
    setAccount(next: CloudIntroAccountFacts) { account = next; },
    setNow(next: Date) { now = next; },
  };
}

describe("cmux Cloud $1 pass fulfillment", () => {
  test("grants a verified $1 payment once and writes the 30-day term", async () => {
    const h = fulfillmentHarness();
    h.sessions.set("cs_1", paidSession("cs_1"));

    const first = await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(first.status).toBe("granted");
    expect(h.writeGrant).toHaveBeenCalledTimes(1);
    const [userId, term] = h.writeGrant.mock.calls[0]!;
    expect(userId).toBe("user_1");
    expect(term).toEqual({ startedAt: NOW, endsAt: new Date("2026-12-23T12:00:00.000Z") });

    // A redelivery, or the async-payment event of the same checkout, settles nothing new.
    const second = await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(second.status).toBe("granted");
    expect(h.rows.size).toBe(1);
    expect(h.refundCreate).not.toHaveBeenCalled();
    expect(h.rows.get("cs_1")?.paymentMethodId).toBeNull();
  });

  test("keeps the card only when the buyer chose to continue on Plus", async () => {
    const h = fulfillmentHarness();
    h.sessions.set("cs_1", paidSession("cs_1", { renewOnPlus: true }));
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(h.rows.get("cs_1")).toMatchObject({ status: "granted", renewOnPlus: true, paymentMethodId: "pm_1" });
  });

  test("refunds a prepaid card and grants nothing", async () => {
    const h = fulfillmentHarness();
    h.sessions.set("cs_1", paidSession("cs_1", { funding: "prepaid" }));

    const result = await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(result.status).toBe("refused");
    expect(h.rows.get("cs_1")).toMatchObject({ status: "refused", refusal: "prepaid_card", refundId: "re_1" });
    expect(h.writeGrant).not.toHaveBeenCalled();
    const [params, options] = h.refundCreate.mock.calls[0]!;
    expect(params).toMatchObject({ payment_intent: "pi_cs_1" });
    expect(options).toEqual({ idempotencyKey: "cmux-cloud-intro-refund-pi_cs_1" });

    // A replay neither refunds twice nor grants.
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(h.refundCreate).toHaveBeenCalledTimes(1);
    expect(h.writeGrant).not.toHaveBeenCalled();
  });

  test("refunds a second account paying with a card fingerprint already used", async () => {
    const h = fulfillmentHarness();
    h.sessions.set("cs_1", paidSession("cs_1", { stackUserId: "user_1", fingerprint: "fp_same" }));
    h.sessions.set("cs_2", paidSession("cs_2", { stackUserId: "user_2", fingerprint: "fp_same" }));
    expect((await fulfillCloudIntroCheckout("cs_1", h.dependencies)).status).toBe("granted");
    expect((await fulfillCloudIntroCheckout("cs_2", h.dependencies)).status).toBe("refused");
    expect(h.rows.get("cs_2")).toMatchObject({ refusal: "card_already_used", refundId: "re_1" });
  });

  test("refunds a second pass for one account, a team that already had one, and the caps", async () => {
    const h = fulfillmentHarness();
    h.setAccount({ ...noHistory, stackTeamIds: ["team_1"] });
    h.sessions.set("cs_1", paidSession("cs_1", { fingerprint: "fp_1" }));
    h.sessions.set("cs_2", paidSession("cs_2", { fingerprint: "fp_2" }));
    h.sessions.set("cs_3", paidSession("cs_3", { stackUserId: "user_3", fingerprint: "fp_3" }));
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    await fulfillCloudIntroCheckout("cs_2", h.dependencies);
    await fulfillCloudIntroCheckout("cs_3", h.dependencies);
    expect(h.rows.get("cs_2")?.refusal).toBe("already_had_pass");
    expect(h.rows.get("cs_3")?.refusal).toBe("team_already_had_pass");
  });

  test("refunds past the daily cap and the total cap", async () => {
    const h = fulfillmentHarness();
    for (let i = 0; i < 100; i += 1) {
      h.rows.set(`cs_old_${i}`, {
        checkoutSessionId: `cs_old_${i}`, stackUserId: `old_${i}`, stackTeamIds: [], status: "granted",
        refusal: null, paymentIntentId: null, refundId: null, renewOnPlus: false, cardFingerprint: `fp_old_${i}`,
        paymentMethodId: null, startedAt: NOW, endsAt: NOW,
      });
    }
    h.sessions.set("cs_1", paidSession("cs_1"));
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(h.rows.get("cs_1")?.refusal).toBe("daily_cap_reached");

    for (let i = 100; i < 1_000; i += 1) {
      h.rows.set(`cs_old_${i}`, { ...h.rows.get("cs_old_0")!, checkoutSessionId: `cs_old_${i}`, stackUserId: `old_${i}`,
        startedAt: new Date("2026-11-01T00:00:00.000Z") });
    }
    h.sessions.set("cs_2", paidSession("cs_2", { stackUserId: "user_2", fingerprint: "fp_2" }));
    h.setNow(new Date("2026-11-24T01:00:00.000Z"));
    await fulfillCloudIntroCheckout("cs_2", h.dependencies);
    expect(h.rows.get("cs_2")?.refusal).toBe("total_cap_reached");
  });

  test("refunds an account that had a paid plan or holds a Team seat", async () => {
    const h = fulfillmentHarness();
    h.setAccount({ ...noHistory, hadPaidPlan: true });
    h.sessions.set("cs_1", paidSession("cs_1"));
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(h.rows.get("cs_1")?.refusal).toBe("had_paid_plan");

    h.setAccount({ ...noHistory, isTeamSeat: true });
    h.sessions.set("cs_2", paidSession("cs_2", { stackUserId: "user_2", fingerprint: "fp_2" }));
    await fulfillCloudIntroCheckout("cs_2", h.dependencies);
    expect(h.rows.get("cs_2")?.refusal).toBe("team_seat");
  });

  test("skips an unpaid or wrong-amount session without settling it", async () => {
    const h = fulfillmentHarness();
    h.sessions.set("cs_unpaid", paidSession("cs_unpaid", { paymentStatus: "unpaid" }));
    h.sessions.set("cs_wrong", paidSession("cs_wrong", { amount: 5000 }));
    expect(await fulfillCloudIntroCheckout("cs_unpaid", h.dependencies)).toEqual({ status: "skipped", reason: "cloud_intro_not_paid" });
    expect(await fulfillCloudIntroCheckout("cs_wrong", h.dependencies)).toEqual({ status: "skipped", reason: "cloud_intro_not_paid" });
    expect(h.rows.size).toBe(0);
  });

  test("with the flag off grants nothing and never reads Stripe", async () => {
    const h = fulfillmentHarness(OFF);
    h.sessions.set("cs_1", paidSession("cs_1"));
    expect(await fulfillCloudIntroCheckout("cs_1", h.dependencies)).toEqual({ status: "skipped", reason: "cloud_intro_disabled" });
    expect(h.retrieve).not.toHaveBeenCalled();
    expect(h.writeGrant).not.toHaveBeenCalled();
  });

  test("a replay after the pass ended never writes it back", async () => {
    const h = fulfillmentHarness();
    h.sessions.set("cs_1", paidSession("cs_1"));
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    h.setNow(new Date("2027-01-01T00:00:00.000Z"));
    await fulfillCloudIntroCheckout("cs_1", h.dependencies);
    expect(h.writeGrant).toHaveBeenCalledTimes(1);
  });
});

describe("cmux Cloud $1 pass webhook", () => {
  let inbox = memoryStripeWebhookInbox();
  let currentEvent: Record<string, unknown> = {};
  const deferred: Array<() => Promise<void>> = [];
  const retrieveSession = mock(async () => ({}));
  const fulfill = mock(async (_id: string) => ({ status: "granted" as const, pass: {} as CloudIntroPass }));
  const handlerFor = (fulfillCloudIntroCheckout?: (id: string) => ReturnType<typeof fulfill>) => makeStripeWebhookHandler({
    webhookSecret: () => "whsec_test",
    isConfigured: () => true,
    stripe: () => ({
      webhooks: { constructEvent: () => currentEvent },
      checkout: { sessions: { retrieve: retrieveSession } },
    }) as never,
    get inbox() { return inbox.inbox; },
    recordCheckoutCompletion: mock(async () => { throw new Error("must not record a subscription"); }) as never,
    applySubscriptionUpdate: mock(async () => null) as never,
    sendProSignupWelcome: mock(async () => {}),
    revokeCoderouterRouteTokens: mock(async () => {}),
    revokeCoderouterTeamRouteTokens: mock(async () => {}),
    captureStripeBillingEvent: mock(async () => {}),
    ...(fulfillCloudIntroCheckout ? { fulfillCloudIntroCheckout } : {}),
    defer: (task) => deferred.push(task),
  });
  const deliver = async (handler: ReturnType<typeof handlerFor>) => {
    const response = await handler(new Request("https://cmux.test/api/stripe/webhook", {
      method: "POST",
      headers: { "stripe-signature": "t=1,v1=test" },
      body: JSON.stringify({ id: currentEvent.id }),
    }));
    expect(response.status).toBe(200);
    for (const task of deferred.splice(0)) await task();
    return inbox.rows.get(String(currentEvent.id));
  };

  beforeEach(() => {
    inbox = memoryStripeWebhookInbox();
    fulfill.mockClear();
    retrieveSession.mockClear();
  });

  test("routes a pass checkout to fulfillment, never to the subscription path", async () => {
    for (const type of ["checkout.session.completed", "checkout.session.async_payment_succeeded"]) {
      currentEvent = { id: `evt_${type}`, type, created: 1, data: { object: paidSession("cs_1") } };
      const row = await deliver(handlerFor(fulfill));
      expect(row?.processedAt).toBeTruthy();
      expect(row?.skipReason ?? null).toBeNull();
    }
    expect(fulfill.mock.calls.map(([id]) => id)).toEqual(["cs_1", "cs_1"]);
    expect(retrieveSession).not.toHaveBeenCalled();
  });

  test("with the flag off the default fulfillment grants nothing", async () => {
    currentEvent = { id: "evt_off", type: "checkout.session.completed", created: 1, data: { object: paidSession("cs_1") } };
    const row = await deliver(handlerFor());
    expect(row?.skipReason).toBe("cloud_intro_disabled");
    expect(retrieveSession).not.toHaveBeenCalled();
  });
});

describe("cmux Cloud $1 pass checkout", () => {
  const create = mock(async (_params: unknown) => ({ id: "cs_new", url: "https://checkout.stripe.com/c/pass" }));
  const list = mock(async (_params: unknown) => ({
    data: [{ id: "price_intro", type: "one_time", unit_amount: 100, currency: "usd" }],
  }));
  let user: { id: string; isAnonymous?: boolean; primaryEmail?: string | null; clientReadOnlyMetadata?: unknown } | null;
  const context = {
    stackServerApp: async () => ({ getUser: async () => user }),
    signInRedirect: () => Response.redirect("https://cmux.test/sign-in") as never,
  };
  const dependencies = (store: CloudIntroPassStore, extra: Partial<CloudIntroCheckoutDependencies> = {}) => ({
    env: ON,
    now: () => NOW,
    isStripeConfigured: () => true,
    stripe: () => ({ checkout: { sessions: { create } }, prices: { list } }) as never,
    store,
    accountFacts: async () => noHistory,
    customerId: async () => null,
    ...extra,
  });
  const request = (query: string) => new NextRequest(`https://cmux.test/api/billing/checkout?${query}`);

  beforeEach(() => {
    create.mockClear();
    list.mockClear();
    resetCloudIntroPriceCacheForTests();
    user = { id: "user_1", primaryEmail: "a@example.com" };
  });

  test("with the flag off answers nothing, so the route keeps treating intro as an unknown plan", async () => {
    const { store } = memoryStore();
    expect(await cloudIntroCheckoutResponse(request("plan=intro"), context, { ...dependencies(store), env: OFF })).toBeNull();
    expect(await cloudIntroCheckoutResponse(request("plan=pro"), context, dependencies(store))).toBeNull();
    expect(create).not.toHaveBeenCalled();
  });

  test("opens a one-time payment with 3-D Secure requested and the renew choice off by default", async () => {
    const { store, rows } = memoryStore();
    const response = await cloudIntroCheckoutResponse(request("plan=intro"), context, dependencies(store));
    expect(response?.headers.get("location")).toBe("https://checkout.stripe.com/c/pass");
    const params = create.mock.calls[0]![0] as Stripe.Checkout.SessionCreateParams;
    expect(params.mode).toBe("payment");
    expect(params.subscription_data).toBeUndefined();
    expect(params.allow_promotion_codes).toBeUndefined();
    expect(params.line_items).toEqual([{ price: "price_intro", quantity: 1 }]);
    expect(params.payment_method_options).toEqual({ card: { request_three_d_secure: "any" } });
    expect(params.payment_intent_data?.setup_future_usage).toBeUndefined();
    expect(params.payment_intent_data?.description).toBe("cmux Cloud: $1 pass, 30 days, does not renew");
    expect(params.metadata).toMatchObject({ app: "cmux", purpose: "cloud_intro", stackUserId: "user_1", renewOnPlus: "false" });
    expect(params.customer_creation).toBe("always");
    expect(rows.get("cs_new")).toMatchObject({ status: "open", renewOnPlus: false });
  });

  test("saves the card for later only when renew=1", async () => {
    const { store, rows } = memoryStore();
    await cloudIntroCheckoutResponse(request("plan=intro&renew=1"), context, dependencies(store));
    const params = create.mock.calls[0]![0] as Stripe.Checkout.SessionCreateParams;
    expect(params.payment_intent_data?.setup_future_usage).toBe("off_session");
    expect(params.metadata?.renewOnPlus).toBe("true");
    expect(rows.get("cs_new")?.renewOnPlus).toBe(true);
  });

  test("refuses over a cap without charging, and after three attempts", async () => {
    const { store } = memoryStore();
    const capped = { ...store, checkoutFacts: async () => ({ ...(await store.checkoutFacts({ stackUserId: "u", stackTeamIds: [], now: NOW })), grantedToday: 100 }) };
    let response = await cloudIntroCheckoutResponse(request("plan=intro"), context, dependencies(capped));
    expect(response?.headers.get("location")).toBe("https://cmux.test/pricing?billing=intro_sold_out_today");
    const sold = { ...store, checkoutFacts: async () => ({ ...(await store.checkoutFacts({ stackUserId: "u", stackTeamIds: [], now: NOW })), grantedTotal: 1_000 }) };
    response = await cloudIntroCheckoutResponse(request("plan=intro"), context, dependencies(sold));
    expect(response?.headers.get("location")).toBe("https://cmux.test/pricing?billing=intro_sold_out");
    expect(create).not.toHaveBeenCalled();

    for (let i = 0; i < 3; i += 1) await cloudIntroCheckoutResponse(request("plan=intro"), context,
      dependencies(store, { stripe: () => ({ checkout: { sessions: { create: async () => ({ id: `cs_${i}`, url: "https://checkout.stripe.com/c/x" }) } }, prices: { list } }) as never }));
    response = await cloudIntroCheckoutResponse(request("plan=intro"), context, dependencies(store));
    expect(response?.headers.get("location")).toBe("https://cmux.test/pricing?billing=intro_unavailable");
  });

  test("refuses an account that had a paid plan, and asks a signed-out visitor to sign in", async () => {
    const { store } = memoryStore();
    const response = await cloudIntroCheckoutResponse(request("plan=intro"), context,
      dependencies(store, { accountFacts: async () => ({ ...noHistory, hadPaidPlan: true }) }));
    expect(response?.headers.get("location")).toBe("https://cmux.test/pricing?billing=intro_unavailable");
    user = null;
    const signIn = await cloudIntroCheckoutResponse(request("plan=intro"), context, dependencies(store));
    expect(signIn?.headers.get("location")).toBe("https://cmux.test/sign-in");
    expect(create).not.toHaveBeenCalled();
  });

  test("reuses the account's Stripe customer", () => {
    const params = cloudIntroCheckoutParams({
      origin: "https://cmux.test", stackUserId: "user_1", priceId: "price_intro", renewOnPlus: false,
      customerId: "cus_1", email: "a@example.com",
    });
    expect(params.customer).toBe("cus_1");
    expect(params.customer_creation).toBeUndefined();
    expect(params.customer_email).toBeUndefined();
  });
});
