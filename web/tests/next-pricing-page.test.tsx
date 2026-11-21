import { afterEach, describe, expect, mock, test } from "bun:test";
import { Fragment, type ReactNode } from "react";
import { renderToString } from "react-dom/server";

import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";

// Keep the real exports (other imported modules read them); the helper's notFound throws "notFound".
const nextNavigation = { ...await import("next/navigation") };
mock.module("next/navigation", () => ({ ...nextNavigation, ...createNextNavigationMock(() => undefined) }));
mock.module("next-intl/server", () => ({
  getTranslations: async (options?: string | { namespace?: string }) =>
    translator(typeof options === "string" ? options : options?.namespace),
}));
mock.module("../app/[locale]/components/site-header", () => ({ SiteHeader: () => <header /> }));

const { default: NextPricingPage, generateMetadata } = await import("../app/[locale]/(landing)/next/pricing/page");
const {
  NEXT_PLANS,
  NEXT_PLAN_CHECKOUT_ENABLED,
  NEXT_PLAN_CONTACT_EMAIL,
  NEXT_PLAN_TRANSFER_HREF,
  nextPlanActionHref,
} = await import("../services/billing/nextPlans");
const plans = await import("../services/billing/plans");
const { personalPlanIdForSubscription } = await import("../services/billing/subscriptionPlan");
const { planTier, planIncludes } = await import("../services/billing/planTier");
const { isPaidPlanId, isPersonalPlanId } = await import("../services/billing/pro");
const { isNextPricingPreviewEnabled } = await import("../services/billing/nextPricingPreview");

const originalVercelEnv = process.env.VERCEL_ENV;
const originalPreview = process.env.CMUX_NEXT_PRICING_PREVIEW;
afterEach(() => {
  restore("VERCEL_ENV", originalVercelEnv);
  restore("CMUX_NEXT_PRICING_PREVIEW", originalPreview);
});

async function renderPage(): Promise<string> {
  return renderToString(await NextPricingPage({ params: Promise.resolve({ locale: "en" }) }));
}

function hrefs(html: string): string[] {
  return [...html.matchAll(/href="([^"]*)"/g)].map((match) => match[1]!.replaceAll("&amp;", "&"));
}

// Every way the page could start or reach the classic plan purchase.
const CLASSIC_PURCHASE = [/^\/pricing/, /\/api\/billing\//, /checkout/i, /[?&]plan=(pro|max|go|team)\b/];

describe("cmux NEXT pricing page", () => {
  test("renders exactly two plans, cmux Pro at $50 and cmux Max at $200, monthly only", async () => {
    const html = await renderPage();
    expect(NEXT_PLANS.map((plan) => [plan.id, plan.monthlyUsd])).toEqual([["next-pro", 50], ["next-max", 200]]);
    expect(html.match(/<h2 class="pr-28[^"]*">[^<]*<\/h2>/g)?.map((h) => h.replace(/<[^>]+>/g, ""))).toEqual([
      "cmux Pro",
      "cmux Max",
    ]);
    expect(html).toContain("$50");
    expect(html).toContain("$200");
    expect(html).toContain("$20 of usage included each month");
    expect(html).toContain("$100 of usage included each month");
    for (const gone of ["Free", "Plus", "Team", "Enterprise", "billed yearly", "Best fit"]) {
      expect(html).not.toContain(gone);
    }
    expect(html).not.toContain("$40");
    expect(html).not.toContain("$160");
  });

  test("tells classic cmux Pro subscribers the plans are separate and to email to transfer", async () => {
    const html = await renderPage();
    const note = html.slice(html.indexOf('data-testid="next-classic-transfer"'));
    expect(note).toContain("cmux NEXT plans are separate from cmux classic plans");
    expect(note).toContain("does not carry over to cmux NEXT");
    expect(note).toContain(`To transfer your cmux Pro plan to cmux NEXT, email <a href="${NEXT_PLAN_TRANSFER_HREF.replaceAll("&", "&amp;")}"`);
    expect(NEXT_PLAN_TRANSFER_HREF.startsWith(`mailto:${NEXT_PLAN_CONTACT_EMAIL}?subject=`)).toBe(true);
    expect(NEXT_PLAN_CONTACT_EMAIL).toBe("founders@cmux.com");
    expect(enMessages.nextPricing.faq.items[0]!.a).toContain(NEXT_PLAN_CONTACT_EMAIL);
    expect(jaMessages.nextPricing.faq.items[0]!.a).toContain(NEXT_PLAN_CONTACT_EMAIL);
  });

  test("buy buttons lead to the contact email, never to the classic checkout", async () => {
    const links = hrefs(await renderPage());
    expect(links.length).toBeGreaterThan(0);
    for (const href of links) {
      expect(href.startsWith(`mailto:${NEXT_PLAN_CONTACT_EMAIL}`)).toBe(true);
      for (const pattern of CLASSIC_PURCHASE) expect(href).not.toMatch(pattern);
    }
    for (const plan of NEXT_PLANS) expect(links).toContain(nextPlanActionHref(plan.id));
  });

  test("online checkout is off and cannot be turned on without the decoupled route", () => {
    expect(NEXT_PLAN_CHECKOUT_ENABLED).toBe(false);
    expect(() => nextPlanActionHref("next-pro", true)).toThrow(/not built yet/);
  });

  test("stays a noindex preview, hidden in production unless an operator opts in", async () => {
    expect(isNextPricingPreviewEnabled({ VERCEL_ENV: "production" })).toBe(false);
    expect(isNextPricingPreviewEnabled({ VERCEL_ENV: "production", CMUX_NEXT_PRICING_PREVIEW: "1" })).toBe(true);
    expect(isNextPricingPreviewEnabled({ VERCEL_ENV: "preview" })).toBe(true);
    process.env.VERCEL_ENV = "production";
    delete process.env.CMUX_NEXT_PRICING_PREVIEW;
    await expect(renderPage()).rejects.toThrow("notFound");
    const metadata = await generateMetadata({ params: Promise.resolve({ locale: "en" }) });
    expect(metadata.robots).toEqual({ index: false, follow: false });
  });

  test("English and Japanese carry the same plan strings for both plans", () => {
    for (const messages of [enMessages, jaMessages]) {
      expect(Object.keys(messages.nextPricing.plans)).toEqual(["next-pro", "next-max"]);
      expect(messages.nextPricing.classic.transfer).toContain("<link>{email}</link>");
    }
    expect(jaMessages.nextPricing.faq.items.length).toBe(enMessages.nextPricing.faq.items.length);
    expect(jaMessages.nextPricing.plans["next-max"].features.length).toBe(
      enMessages.nextPricing.plans["next-max"].features.length,
    );
  });
});

describe("cmux NEXT plan catalog stays decoupled from classic", () => {
  test("has its own plan IDs and monthly lookup keys carrying the amount", () => {
    expect(plans.NEXT_PLAN_IDS).toEqual(["next-pro", "next-max"]);
    expect(plans.NEXT_PRO_PRICING_USD.month).toEqual({
      billedAmount: 50,
      monthlyEquivalent: 50,
      discountPercent: 0,
      lookupKey: "cmux-next-pro-monthly-50",
    });
    expect(plans.NEXT_MAX_PRICING_USD.month).toEqual({
      billedAmount: 200,
      monthlyEquivalent: 200,
      discountPercent: 0,
      lookupKey: "cmux-next-max-monthly-200",
    });
    expect("year" in plans.NEXT_PRO_PRICING_USD).toBe(false);
    expect("year" in plans.NEXT_MAX_PRICING_USD).toBe(false);
  });

  test("no NEXT lookup key is a classic key, a portal switch target or a legacy key", () => {
    const classic = [
      ...Object.values(plans.PRO_PRICING_USD),
      ...Object.values(plans.MAX_PRICING_USD),
      ...Object.values(plans.GO_PRICING_USD),
      ...Object.values(plans.TEAM_PRICING_USD),
    ].map((price) => price.lookupKey);
    for (const plan of NEXT_PLANS) {
      expect(plans.isNextPlanLookupKey(plan.lookupKey)).toBe(true);
      expect(classic).not.toContain(plan.lookupKey);
      expect(plans.isPortalSwitchableLookupKey(plan.lookupKey)).toBe(false);
      expect(plans.LEGACY_PRICE_LOOKUP_KEYS as readonly string[]).not.toContain(plan.lookupKey);
    }
    for (const key of classic) expect(plans.isNextPlanLookupKey(key)).toBe(false);
  });

  test("a NEXT subscription never resolves to a classic plan, even with classic metadata", () => {
    for (const plan of NEXT_PLANS) {
      const subscription = {
        items: { data: [{ price: { lookup_key: plan.lookupKey } }] },
        metadata: { app: "cmux", plan: plan.id === "next-pro" ? "pro" : "max" },
      } as unknown as Parameters<typeof personalPlanIdForSubscription>[0];
      expect(personalPlanIdForSubscription(subscription, { plan: "pro" })).toBeNull();
    }
  });

  test("NEXT plan IDs grant no classic tier or paid plan", () => {
    for (const id of plans.NEXT_PLAN_IDS) {
      expect(planTier(id)).toBeNull();
      expect(planIncludes(id, "free")).toBe(false);
      expect(isPaidPlanId(id)).toBe(false);
      expect(isPersonalPlanId(id)).toBe(false);
    }
  });
});

function restore(name: string, value: string | undefined) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

function translator(namespace?: string) {
  const root = namespace ? valueAtPath(enMessages, namespace) : enMessages;
  const t = (key: string, values?: Record<string, unknown>) => interpolate(String(valueAtPath(root, key)), values);
  t.raw = (key: string) => valueAtPath(root, key);
  // Renders `<tag>chunks</tag>` through the matching function, like next-intl's t.rich.
  t.rich = (key: string, values: Record<string, unknown> = {}): ReactNode[] => {
    const message = interpolate(String(valueAtPath(root, key)), values);
    const parts: ReactNode[] = [];
    let last = 0;
    for (const match of message.matchAll(/<(\w+)>(.*?)<\/\1>/g)) {
      parts.push(message.slice(last, match.index));
      const render = values[match[1]!] as (chunks: ReactNode) => ReactNode;
      parts.push(<Fragment key={match.index}>{render(match[2])}</Fragment>);
      last = match.index! + match[0].length;
    }
    parts.push(message.slice(last));
    return parts;
  };
  return t;
}

function valueAtPath(root: unknown, path: string): unknown {
  return path.split(".").reduce<unknown>((value, part) => {
    if (value && typeof value === "object" && part in value) return (value as Record<string, unknown>)[part];
    return path;
  }, root);
}

function interpolate(message: string, values?: Record<string, unknown>) {
  if (!values) return message;
  return Object.entries(values).reduce(
    (result, [key, value]) => (typeof value === "function" ? result : result.replaceAll(`{${key}}`, String(value))),
    message,
  );
}
