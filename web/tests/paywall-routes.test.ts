import { beforeEach, describe, expect, mock, test } from "bun:test";

import * as appleStoreModule from "../services/billing/apple/store";
import * as proModule from "../services/billing/pro";
import * as teamResolutionModule from "../services/billing/teamResolution";
import * as paywallStoreModule from "../services/billing/paywall/store";
import * as serverEventsModule from "../services/analytics/serverEvents";
import { IOS_PAYWALL_CONTROL, IOS_PAYWALL_V1_SEED } from "../services/billing/paywall/iosPaywallV1";
import type { ServerEventInput } from "../services/analytics/serverEvents";

// The route boundary: GET /api/billing/paywall and POST account-token with
// real paywall resolution, validator and exposure; only Stack, PostHog's
// /flags endpoint, the database and the event transport are replaced.

type TestUser = { id: string; isAnonymous: boolean; primaryEmail: string | null; primaryEmailVerified: boolean };
let currentUser: TestUser | null = null;

mock.module("../app/lib/stack", () => ({
  isStackConfigured: () => true,
  getStackServerApp: () => ({ getUser: async () => currentUser }),
}));

mock.module("../services/billing/apple/store", () => ({
  ...appleStoreModule,
  databaseAppleIapStore: () => ({ accountTokenForUser: async () => "3f1b0a8e-7f6c-4d6e-9b1a-0c2d3e4f5a6b" }),
}));

let planId = "free";
mock.module("../services/billing/pro", () => ({
  ...proModule,
  stripeBillingStatusForUser: async () => ({ hasActiveSubscription: false, hasRecurringSubscription: false }),
  resolveProPlanStatus: async () => ({
    planId, isPro: planId !== "free", billingManagement: "none", billingSource: planId === "free" ? "none" : "apple",
    manageUrl: null, metadataPlanId: null, hasManualVmPlanOverride: false, metadataChanged: false,
  }),
}));

mock.module("../services/billing/teamResolution", () => ({
  ...teamResolutionModule,
  resolveBillingTeam: async () => null,
}));

const assignments = new Map<string, { variant: string; payload: unknown; assignedAt: Date }>();
mock.module("../services/billing/paywall/store", () => ({
  ...paywallStoreModule,
  databasePaywallAssignmentStore: () => ({
    assignment: async (userId: string, experiment: string) => assignments.get(`${userId}:${experiment}`) ?? null,
    recordServed: async (userId: string, experiment: string, variant: string, payload: unknown) => {
      assignments.set(`${userId}:${experiment}`, { variant, payload, assignedAt: new Date() });
    },
  }),
}));

const events: ServerEventInput[] = [];
mock.module("../services/analytics/serverEvents", () => ({
  ...serverEventsModule,
  captureServerEvent: async (input: ServerEventInput) => {
    events.push(input);
  },
}));

type FlagAnswer = { variant: string; payload: unknown } | "off" | "down";
let flagAnswer: FlagAnswer = "off";
let flagCalls = 0;
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
  const url = String(input instanceof Request ? input.url : input);
  if (!url.includes("/flags/")) return realFetch(input, init);
  flagCalls += 1;
  if (flagAnswer === "down") return new Response("unavailable", { status: 503 });
  if (flagAnswer === "off") {
    return Response.json({ flags: { "ios-paywall-v1": { key: "ios-paywall-v1", enabled: false } } });
  }
  return Response.json({
    flags: {
      "ios-paywall-v1": {
        key: "ios-paywall-v1",
        enabled: true,
        variant: flagAnswer.variant,
        metadata: { payload: typeof flagAnswer.payload === "string" ? flagAnswer.payload : JSON.stringify(flagAnswer.payload) },
      },
    },
  });
}) as typeof fetch;

const paywallRoute = await import("../app/api/billing/paywall/route");
const accountTokenRoute = await import("../app/api/billing/apple/account-token/route");

function request(path: string, method: "GET" | "POST", bundleId = "com.cmux.app") {
  return new Request(`https://cmux.test${path}`, {
    method,
    headers: {
      authorization: "Bearer access-token",
      "x-stack-refresh-token": "refresh-token",
      "x-cmux-bundle-id": bundleId,
      "x-cmux-storekit-environment": "Production",
      "x-cmux-billing-periods": "monthly,yearly",
      "content-type": "application/json",
    },
    ...(method === "POST" ? { body: "{}" } : {}),
  });
}

async function paywallFor(bundleId = "com.cmux.app") {
  const response = await paywallRoute.GET(request("/api/billing/paywall", "GET", bundleId));
  expect(response.status).toBe(200);
  return (await response.json() as { paywall: Record<string, unknown> }).paywall;
}

const seed = (key: string) => IOS_PAYWALL_V1_SEED.find((variant) => variant.key === key)!;

beforeEach(() => {
  currentUser = { id: "user-a", isAnonymous: false, primaryEmail: "someone@example.com", primaryEmailVerified: true };
  planId = "free";
  assignments.clear();
  events.length = 0;
  flagAnswer = "off";
  flagCalls = 0;
});

describe("GET /api/billing/paywall", () => {
  test("serves every seeded variant from its flag payload and records the exposure", async () => {
    // The trial arm is covered below: it is served only when the trial is configured.
    for (const variant of IOS_PAYWALL_V1_SEED.filter((item) => item.key !== "pro-trial-7d")) {
      assignments.clear();
      events.length = 0;
      flagAnswer = { variant: variant.key, payload: variant.payload };
      const paywall = await paywallFor();
      expect(paywall).toEqual({ experiment: "ios-paywall-v1", variant: variant.key, ...variant.payload });
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({
        event: "$feature_flag_called",
        distinctId: "user-a",
        properties: {
          $feature_flag: "ios-paywall-v1",
          $feature_flag_response: variant.key,
          paywall_variant: variant.key,
          paywall_channel: "production",
          paywall_internal: false,
        },
      });
    }
  });

  test("keeps an exposed user on their variant when the flag moves them", async () => {
    flagAnswer = { variant: "outcome-copy", payload: seed("outcome-copy").payload };
    await paywallFor();
    flagAnswer = { variant: "comparison", payload: seed("comparison").payload };
    expect((await paywallFor()).variant).toBe("outcome-copy");
    flagAnswer = "down";
    expect((await paywallFor()).variant).toBe("outcome-copy");
    expect(events.map((event) => event.properties?.paywall_variant)).toEqual(["outcome-copy", "outcome-copy", "outcome-copy"]);
    // A copy edit in the flag reaches new users only; this arm keeps one version per person.
    flagAnswer = { variant: "outcome-copy", payload: { ...seed("outcome-copy").payload, headline: "Your agents keep working" } };
    expect((await paywallFor()).headline).toBe(seed("outcome-copy").payload.headline);
  });

  test("the kill switch serves control without an exposure, even to an exposed user", async () => {
    flagAnswer = { variant: "comparison", payload: seed("comparison").payload };
    await paywallFor();
    events.length = 0;
    flagAnswer = "off";
    expect(await paywallFor()).toEqual(IOS_PAYWALL_CONTROL);
    expect(events).toHaveLength(0);
  });

  test("a payload that fails the copy validator is never served", async () => {
    const unsafe = [
      { ...seed("comparison").payload, headline: "Pay with Stripe today" },
      { ...seed("comparison").payload, subheadline: "See cmux.com/pricing for details." },
      { ...seed("comparison").payload, bullets: ["Unlimited Cloud VMs"] },
      { ...seed("comparison").payload, bullets: ["Up to 10 Cloud VMs"] },
      { ...seed("comparison").payload, headline: "The best way to run agents" },
      { ...seed("comparison").payload, headline: "Start your free trial" },
      { ...seed("comparison").payload, bullets: ["Only 3 spots left"] },
      { ...seed("comparison").payload, headline: "x".repeat(61) },
      { ...seed("comparison").payload, bullets: ["**Bold** claims"] },
      { ...seed("comparison").payload, bullets: ["Up to 1,000 Cloud VMs"] },
      { ...seed("comparison").payload, bullets: ["Builds 2x faster"] },
      { ...seed("comparison").payload, bullets: ["Up to 80 parallel VMs"] },
      { ...seed("comparison").payload, bullets: ["Pro: 160 GB RAM to share"] },
      { ...seed("comparison").payload, headline: "Pay with Str\u0456pe" },
      { ...seed("comparison").payload, subheadline: "Read more at cmux.cloud" },
      { ...seed("comparison").payload, headline: "Try it free" },
      { ...seed("comparison").payload, bullets: ["Run ten agents at once"] },
    ];
    for (const payload of unsafe) {
      assignments.clear();
      flagAnswer = { variant: "comparison", payload };
      expect(await paywallFor()).toEqual(IOS_PAYWALL_CONTROL);
    }
    expect(events).toHaveLength(0);
    expect(assignments.size).toBe(0);
  });

  test("only the App Store app, free accounts and internal accounts enter", async () => {
    flagAnswer = { variant: "comparison", payload: seed("comparison").payload };
    expect(await paywallFor("dev.cmux.app.beta")).toEqual(IOS_PAYWALL_CONTROL);
    expect(flagCalls).toBe(0);
    planId = "pro";
    expect(await paywallFor()).toEqual(IOS_PAYWALL_CONTROL);
    expect(flagCalls).toBe(0);
    planId = "free";
    currentUser = { ...currentUser!, primaryEmail: "dev@manaflow.ai" };
    expect((await paywallFor("dev.cmux.app.beta")).variant).toBe("comparison");
    expect(events.at(-1)?.properties).toMatchObject({ paywall_internal: true, paywall_channel: "beta" });
  });
});

describe("the trial arm", () => {
  const trialEnv = {
    APPLE_IAP_KEY_ID: "IAPKEY1234",
    APPLE_IAP_ISSUER_ID: "11111111-2222-3333-4444-555555555555",
    APPLE_IAP_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----",
    DEVICECHECK_KEY_ID: "DCKEY12345",
    DEVICECHECK_PRIVATE_KEY: "-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----",
  };

  test("is never served while the trial cannot be granted, and its trial copy passes only for it", async () => {
    flagAnswer = { variant: "pro-trial-7d", payload: seed("pro-trial-7d").payload };
    expect(await paywallFor()).toEqual(IOS_PAYWALL_CONTROL);
    expect(events).toHaveLength(0);
    Object.assign(process.env, trialEnv);
    try {
      expect((await paywallFor()).variant).toBe("pro-trial-7d");
      // The same trial wording in another arm is refused.
      assignments.clear();
      flagAnswer = { variant: "comparison", payload: { ...seed("comparison").payload, headline: seed("pro-trial-7d").payload.headline } };
      expect(await paywallFor()).toEqual(IOS_PAYWALL_CONTROL);
    } finally {
      for (const key of Object.keys(trialEnv)) delete process.env[key];
    }
  });
});

describe("POST /api/billing/apple/account-token", () => {
  test("includes the same paywall, and staff only for staff", async () => {
    flagAnswer = { variant: "focus-pro-yearly", payload: seed("focus-pro-yearly").payload };
    const body = await (await accountTokenRoute.POST(request("/api/billing/apple/account-token", "POST"))).json() as Record<string, unknown>;
    expect((body.paywall as { variant: string }).variant).toBe("focus-pro-yearly");
    expect(body.staff).toBeUndefined();
    currentUser = { ...currentUser!, primaryEmail: "dev@manaflow.ai" };
    const staff = await (await accountTokenRoute.POST(request("/api/billing/apple/account-token", "POST"))).json() as Record<string, unknown>;
    expect(staff.staff).toBe(true);
  });
});
