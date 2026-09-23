import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";

import {
  createFoundersPortalSession,
  resolveFoundersBilling,
  type FoundersStackUser,
  type StripeLike,
} from "../services/billing/founders";
import { makeSignOutAndSignInHandler } from "../app/handler/sign-out-and-sign-in/route";
import { makeFoundersPortalHandler } from "../app/api/founders/portal/route";
import { localizedVaultPath, vaultSignInHref } from "../app/lib/vault-auth";

type Customer = {
  id: string;
  email?: string | null;
  deleted?: boolean;
};

type Subscription = {
  id: string;
  status: string;
  created?: number;
  cancel_at_period_end?: boolean;
  items?: {
    data?: Array<{
      current_period_end?: number;
      price?: { product?: string | { name?: string | null } | null };
    }>;
  };
};

type FakeStripe = StripeLike & {
  customerListCalls: Array<{ email: string; limit: number }>;
  subscriptionListCalls: Array<{ customer: string }>;
  portalSessionCalls: Array<{ customer: string; return_url: string }>;
};

describe("resolveFoundersBilling", () => {
  test("does not call Stripe for an anonymous user", async () => {
    const stripe = fakeStripe();
    const result = await resolveFoundersBilling(
      foundersUser({ isAnonymous: true, primaryEmailVerified: false }),
      { stripe: () => stripe },
    );

    expect(result).toEqual({
      status: "email-unverified",
      email: "Buyer@Example.com",
    });
    expect(stripe.customerListCalls).toHaveLength(0);
    expect(stripe.subscriptionListCalls).toHaveLength(0);
  });

  test("does not call Stripe for an unverified email", async () => {
    const stripe = fakeStripe();
    const result = await resolveFoundersBilling(
      foundersUser({ primaryEmailVerified: false }),
      { stripe: () => stripe },
    );

    expect(result).toEqual({
      status: "email-unverified",
      email: "Buyer@Example.com",
    });
    expect(stripe.customerListCalls).toHaveLength(0);
    expect(stripe.subscriptionListCalls).toHaveLength(0);
  });

  test("consults a mapped customer first and returns it when active", async () => {
    const stripe = fakeStripe({
      subscriptionsByCustomer: {
        cus_mapped: [subscription({ id: "sub_mapped", status: "active" })],
      },
    });

    const result = await resolveFoundersBilling(foundersUser(), {
      stripe: () => stripe,
      findMappedStripeCustomerId: async () => "cus_mapped",
    });

    expect(result).toMatchObject({
      status: "ready",
      customerId: "cus_mapped",
      subscriptions: [{ id: "sub_mapped", status: "active" }],
    });
    expect(stripe.subscriptionListCalls).toEqual([{ customer: "cus_mapped" }]);
    expect(stripe.customerListCalls).toHaveLength(0);
  });

  test("filters email customers and prefers active over canceled", async () => {
    const stripe = fakeStripe({
      customersByEmail: {
        "buyer@example.com": [
          { id: "cus_canceled", email: "Buyer@Example.com" },
          { id: "cus_other", email: "other@example.com" },
          { id: "cus_active", email: "buyer@example.com" },
        ],
      },
      subscriptionsByCustomer: {
        cus_canceled: [subscription({ id: "sub_old", status: "canceled" })],
        cus_active: [subscription({ id: "sub_new", status: "active" })],
      },
    });

    const result = await resolveFoundersBilling(foundersUser({
      primaryEmail: "buyer@example.com",
    }), {
      stripe: () => stripe,
      findMappedStripeCustomerId: async () => null,
    });

    expect(result).toMatchObject({
      status: "ready",
      customerId: "cus_active",
      subscriptions: [{ id: "sub_new", status: "active" }],
    });
    expect(stripe.subscriptionListCalls).toEqual([
      { customer: "cus_canceled" },
      { customer: "cus_active" },
    ]);
  });

  test("matches mixed-case Stack email to lowercase Stripe customer email", async () => {
    const stripe = fakeStripe({
      customersByEmail: {
        "Buyer@Example.com": [{ id: "cus_1", email: "buyer@example.com" }],
        "buyer@example.com": [{ id: "cus_1", email: "buyer@example.com" }],
      },
      subscriptionsByCustomer: {
        cus_1: [subscription({ id: "sub_1", status: "active" })],
      },
    });

    const result = await resolveFoundersBilling(foundersUser(), {
      stripe: () => stripe,
      findMappedStripeCustomerId: async () => null,
    });

    expect(result).toMatchObject({
      status: "ready",
      email: "buyer@example.com",
      customerId: "cus_1",
    });
    expect(stripe.customerListCalls).toEqual([
      { email: "Buyer@Example.com", limit: 10 },
      { email: "buyer@example.com", limit: 10 },
    ]);
    expect(stripe.subscriptionListCalls).toEqual([{ customer: "cus_1" }]);
  });

  test("returns no-subscription when no matching customer has subscriptions", async () => {
    const stripe = fakeStripe({
      customersByEmail: {
        "buyer@example.com": [{ id: "cus_empty", email: "buyer@example.com" }],
      },
    });

    const result = await resolveFoundersBilling(foundersUser({
      primaryEmail: "buyer@example.com",
    }), {
      stripe: () => stripe,
      findMappedStripeCustomerId: async () => null,
    });

    expect(result).toEqual({
      status: "no-subscription",
      email: "buyer@example.com",
    });
  });

  test("shapes summaries and returns canceled-only customers", async () => {
    const stripe = fakeStripe({
      customersByEmail: {
        "buyer@example.com": [{ id: "cus_canceled", email: "buyer@example.com" }],
      },
      subscriptionsByCustomer: {
        cus_canceled: [
          subscription({
            id: "sub_string_product",
            status: "canceled",
            created: 10,
            product: "prod_123",
          }),
          subscription({
            id: "sub_named_product",
            status: "canceled",
            created: 20,
            cancel_at_period_end: true,
            current_period_end: 1_800_000_000,
            product: { name: "Founder's Edition" },
          }),
        ],
      },
    });

    const result = await resolveFoundersBilling(foundersUser({
      primaryEmail: "buyer@example.com",
    }), {
      stripe: () => stripe,
      findMappedStripeCustomerId: async () => null,
    });

    expect(result).toEqual({
      status: "ready",
      email: "buyer@example.com",
      customerId: "cus_canceled",
      subscriptions: [
        {
          id: "sub_named_product",
          status: "canceled",
          productName: "Founder's Edition",
          currentPeriodEnd: new Date(1_800_000_000 * 1000),
          cancelAtPeriodEnd: true,
        },
        {
          id: "sub_string_product",
          status: "canceled",
          productName: null,
          currentPeriodEnd: null,
          cancelAtPeriodEnd: false,
        },
      ],
    });
  });
});

describe("createFoundersPortalSession", () => {
  test("returns the Stripe Billing Portal URL", async () => {
    const stripe = fakeStripe({ portalUrl: "https://billing.stripe.com/session" });
    await expect(
      createFoundersPortalSession("cus_123", "https://cmux.test/founders", {
        stripe: () => stripe,
      }),
    ).resolves.toBe("https://billing.stripe.com/session");
  });
});

describe("makeFoundersPortalHandler", () => {
  test("redirects unauthenticated users to the founders page", async () => {
    const handler = makeFoundersPortalHandler({
      isStackConfigured: () => true,
      isStripeBillingConfigured: () => true,
      getStackServerApp: () => ({ getUser: async () => null }),
    });

    const response = await handler(
      new NextRequest("https://cmux.test/api/founders/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe("https://cmux.test/founders");
  });

  test("redirects ready users to Stripe Billing Portal", async () => {
    const portalCalls: Array<{ customerId: string; returnUrl: string }> = [];
    const handler = makeFoundersPortalHandler({
      isStackConfigured: () => true,
      isStripeBillingConfigured: () => true,
      getStackServerApp: () => ({ getUser: async () => foundersUser() }),
      resolveFoundersBilling: async () => ({
        status: "ready",
        email: "buyer@example.com",
        customerId: "cus_123",
        subscriptions: [],
      }),
      createFoundersPortalSession: async (customerId, returnUrl) => {
        portalCalls.push({ customerId, returnUrl });
        return "https://billing.stripe.com/session";
      },
    });

    const response = await handler(
      new NextRequest("https://cmux.test/api/founders/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://billing.stripe.com/session",
    );
    expect(portalCalls).toEqual([
      { customerId: "cus_123", returnUrl: "https://cmux.test/founders" },
    ]);
  });

  test("redirects missing subscriptions with billing=missing", async () => {
    const handler = makeFoundersPortalHandler({
      isStackConfigured: () => true,
      isStripeBillingConfigured: () => true,
      getStackServerApp: () => ({ getUser: async () => foundersUser() }),
      resolveFoundersBilling: async () => ({
        status: "no-subscription",
        email: "buyer@example.com",
      }),
    });

    const response = await handler(
      new NextRequest("https://cmux.test/api/founders/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/founders?billing=missing",
    );
  });

  test("captures thrown errors and redirects with billing=error", async () => {
    const captured: Array<{ error: unknown; context: unknown }> = [];
    const handler = makeFoundersPortalHandler({
      isStackConfigured: () => true,
      isStripeBillingConfigured: () => true,
      getStackServerApp: () => ({ getUser: async () => foundersUser() }),
      resolveFoundersBilling: async () => {
        throw new Error("stripe failed");
      },
      captureBillingError: (error, context) => {
        captured.push({ error, context });
      },
    });

    const response = await handler(
      new NextRequest("https://cmux.test/api/founders/portal"),
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      "https://cmux.test/founders?billing=error",
    );
    expect(captured[0]?.error).toBeInstanceOf(Error);
    expect(captured[0]?.context).toEqual({
      route: "/api/founders/portal",
      stackUserId: "user_123",
    });
  });
});

describe("founders switch account link", () => {
  test("builds a web sign-in target accepted by sign-out-and-sign-in", async () => {
    const signOutCalls: Array<{ redirectUrl: string }> = [];
    const handler = makeSignOutAndSignInHandler({
      projectId: "test-project",
      signOut: async (options) => {
        signOutCalls.push(options);
      },
    });
    const signInTarget = vaultSignInHref(localizedVaultPath("en", "/founders"));
    const switchAccountHref = `/handler/sign-out-and-sign-in?after_auth_return_to=${encodeURIComponent(signInTarget)}`;

    const response = await handler(
      new NextRequest(`https://cmux.test${switchAccountHref}`, {
        headers: {
          "sec-fetch-site": "same-origin",
          cookie: "stack-access=access-token; stack-refresh-test-project=refresh-token",
        },
      }),
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(`https://cmux.test${signInTarget}`);
    expect(response.headers.get("set-cookie")).toContain("stack-access=;");
    expect(response.headers.get("set-cookie")).toContain(
      "stack-refresh-test-project=;",
    );
    expect(signOutCalls).toEqual([
      { redirectUrl: `https://cmux.test${signInTarget}` },
    ]);
  });
});

describe("founders localization", () => {
  test("all catalogs have matching key paths, placeholders, and rich tags", async () => {
    const fs = await import("node:fs/promises");
    const messagesDir = new URL("../messages/", import.meta.url);
    const files = (await fs.readdir(messagesDir))
      .filter((file) => file.endsWith(".json"))
      .sort();
    const catalogs = await Promise.all(
      files.map(async (file) => ({
        file,
        data: JSON.parse(
          await fs.readFile(new URL(file, messagesDir), "utf8"),
        ) as Record<string, unknown>,
      })),
    );
    const english = catalogs.find((catalog) => catalog.file === "en.json");
    expect(english).toBeDefined();
    const englishFounders = english?.data.founders;
    expect(isRecord(englishFounders)).toBe(true);
    const expectedPaths = leafPaths(englishFounders as Record<string, unknown>);
    const expectedPlaceholders = placeholderMap(
      englishFounders as Record<string, unknown>,
    );
    const expectedRichTags = richTagMap(englishFounders as Record<string, unknown>);

    for (const catalog of catalogs) {
      const founders = catalog.data.founders;
      expect(isRecord(founders)).toBe(true);
      expect(leafPaths(founders as Record<string, unknown>)).toEqual(
        expectedPaths,
      );
      expect(
        placeholderMap(founders as Record<string, unknown>),
      ).toEqual(expectedPlaceholders);
      expect(richTagMap(founders as Record<string, unknown>)).toEqual(
        expectedRichTags,
      );
    }
  });
});

function fakeStripe(options: {
  customersByEmail?: Record<string, Customer[]>;
  subscriptionsByCustomer?: Record<string, Subscription[]>;
  portalUrl?: string | null;
} = {}): FakeStripe {
  const customerListCalls: Array<{ email: string; limit: number }> = [];
  const subscriptionListCalls: Array<{ customer: string }> = [];
  const portalSessionCalls: Array<{ customer: string; return_url: string }> = [];
  return {
    customerListCalls,
    subscriptionListCalls,
    portalSessionCalls,
    customers: {
      list: async (params) => {
        customerListCalls.push(params);
        return { data: options.customersByEmail?.[params.email] ?? [] };
      },
    },
    subscriptions: {
      list: async (params) => {
        subscriptionListCalls.push({ customer: params.customer });
        return { data: options.subscriptionsByCustomer?.[params.customer] ?? [] };
      },
    },
    billingPortal: {
      sessions: {
        create: async (params) => {
          portalSessionCalls.push(params);
          return { url: options.portalUrl ?? "https://billing.stripe.com/session" };
        },
      },
    },
  };
}

function foundersUser(overrides: Partial<FoundersStackUser> = {}): FoundersStackUser {
  return {
    id: "user_123",
    primaryEmail: "Buyer@Example.com",
    primaryEmailVerified: true,
    isAnonymous: false,
    ...overrides,
  };
}

function subscription(options: {
  id: string;
  status: string;
  created?: number;
  cancel_at_period_end?: boolean;
  current_period_end?: number;
  product?: string | { name?: string | null } | null;
}): Subscription {
  return {
    id: options.id,
    status: options.status,
    created: options.created ?? 1,
    cancel_at_period_end: options.cancel_at_period_end ?? false,
    items: {
      data: [
        {
          current_period_end: options.current_period_end,
          price: { product: options.product ?? { name: "cmux Pro" } },
        },
      ],
    },
  };
}

function leafPaths(value: Record<string, unknown>, prefix = ""): string[] {
  return Object.entries(value)
    .flatMap(([key, child]) => {
      const next = prefix ? `${prefix}.${key}` : key;
      return isRecord(child) ? leafPaths(child, next) : [next];
    })
    .sort();
}

function placeholderMap(value: Record<string, unknown>): Record<string, string[]> {
  const placeholders: Record<string, string[]> = {};
  for (const path of leafPaths(value)) {
    const message = valueAtPath(value, path);
    placeholders[path] = typeof message === "string"
      ? [...message.matchAll(/\{[a-zA-Z][a-zA-Z0-9_]*\}/g)].map((match) => match[0])
      : [];
  }
  return placeholders;
}

function richTagMap(value: Record<string, unknown>): Record<string, string[]> {
  const tags: Record<string, string[]> = {};
  for (const path of leafPaths(value)) {
    const message = valueAtPath(value, path);
    tags[path] = typeof message === "string"
      ? [...message.matchAll(/<\/?[a-zA-Z][a-zA-Z0-9_-]*\b[^>]*>/g)].map(
          (match) => match[0],
        )
      : [];
  }
  return tags;
}

function valueAtPath(value: Record<string, unknown>, path: string): unknown {
  return path.split(".").reduce<unknown>((current, segment) => {
    if (!isRecord(current)) return undefined;
    return current[segment];
  }, value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
