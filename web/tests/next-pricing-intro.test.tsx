import { afterEach, describe, expect, mock, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { createTranslator, type AbstractIntlMessages } from "use-intl/core";

import enMessages from "../messages/en.json";
import { createNextNavigationMock } from "./helpers/next-navigation-mock";
import { CLOUD_INTRO_BILLING_COPY } from "../services/billing/cloudIntro";
import { cloudIntroBillingCode, cloudIntroLayout, cloudIntroOfferFacts } from "../services/billing/cloudIntroOffer";

// The $1 pass on the cmux NEXT pricing preview and its /pricing notices.

const translator = (namespace?: string) =>
  createTranslator({
    locale: "en",
    messages: enMessages as unknown as AbstractIntlMessages,
    namespace: namespace as never,
    timeZone: "UTC",
  });

let search = new URLSearchParams();
const navigation = createNextNavigationMock(() => {
  throw new Error("redirect");
});
mock.module("next/navigation", () => ({ ...navigation, useSearchParams: () => search }));
mock.module("next-intl", () => ({
  NextIntlClientProvider: ({ children }: { children: React.ReactNode }) => children,
  useLocale: () => "en",
  useTranslations: (namespace?: string) => translator(namespace),
}));
mock.module("next-intl/server", () => ({
  getTranslations: async (options?: string | { namespace?: string }) =>
    translator(typeof options === "string" ? options : options?.namespace),
  setRequestLocale: () => undefined,
}));
mock.module("../app/[locale]/components/site-header", () => ({ SiteHeader: () => <header /> }));
mock.module("../app/[locale]/components/content-locale-link", () => ({
  ContentLocaleLink: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));

const { default: NextPricingPage } = await import("../app/[locale]/(landing)/next/pricing/page");
const { ProWelcomeBanner } = await import("../app/[locale]/components/pro-welcome-banner");

const previousIntro = process.env.CMUX_CLOUD_INTRO;
afterEach(() => {
  if (previousIntro === undefined) delete process.env.CMUX_CLOUD_INTRO;
  else process.env.CMUX_CLOUD_INTRO = previousIntro;
  search = new URLSearchParams();
});

async function renderPage(intro?: string) {
  const element = await NextPricingPage({
    params: Promise.resolve({ locale: "en" }),
    ...(intro === undefined ? {} : { searchParams: Promise.resolve({ intro }) }),
  });
  return renderToString(element);
}

/** The query a browser submits for the buy form: hidden fields always, the checkbox only when ticked. */
function submittedQuery(html: string, ticked: boolean): string {
  const form = html.match(/<form[^>]*data-testid="cloud-intro-form"[^>]*>[\s\S]*?<\/form>/)?.[0];
  if (!form) throw new Error("no pass form");
  expect(form).toContain('action="/api/billing/checkout"');
  expect(form).toContain('method="get"');
  const query = new URLSearchParams();
  for (const input of form.match(/<input[^>]*>/g) ?? []) {
    const attr = (name: string) => input.match(new RegExp(`${name}="([^"]*)"`))?.[1];
    const type = attr("type");
    if (type === "checkbox") {
      // Off by default: the server render never pre-ticks it.
      expect(input).not.toMatch(/\schecked/);
      if (!ticked) continue;
    }
    query.append(attr("name")!, attr("value")!);
  }
  return query.toString();
}

const introStrings = JSON.stringify([
  enMessages.nextPricing.intro,
  enMessages.pricing.cloudIntro,
  enMessages.dashboard.billing.welcome.introTitle,
  enMessages.dashboard.billing.welcome.introBody,
]);

describe("the $1 pass on the cmux NEXT pricing preview", () => {
  test("with the flag off the page is unchanged by ?intro= and names no pass", async () => {
    delete process.env.CMUX_CLOUD_INTRO;
    const plain = await renderPage();
    for (const layout of ["a", "b", "c"]) expect(await renderPage(layout)).toBe(plain);
    expect(plain).not.toContain("data-cloud-intro");
    expect(plain).not.toContain("$1 pass");
    expect(plain).not.toContain("plan=intro");
    expect(plain).toContain("mt-12 grid items-stretch gap-5 md:grid-cols-3");
  });

  test("with the flag on each layout shows the offer and what is inside", async () => {
    process.env.CMUX_CLOUD_INTRO = "1";
    for (const layout of ["a", "b", "c"] as const) {
      const html = await renderPage(layout);
      expect(html.match(/data-cloud-intro="/g)).toHaveLength(1);
      expect(html).toContain(`data-cloud-intro="${layout}"`);
      expect(html).toContain("$1 for 30 days of your own always-on agent in the cloud, with its machines and your phone. It never renews on its own: at the end we ask, and you pay nothing more unless you say yes.");
      expect(html).toContain("One Chief, an always-on agent machine (2 vCPU / 4 GiB), with 100 awake hours");
      expect(html).toContain("3,000 machine-minutes for other machines, on machines up to 4 vCPU / 8 GiB");
      expect(html).toContain("3,000 is 25 hours of a 2 vCPU machine");
      expect(html).toContain("Up to 5 machines at once");
      expect(html).toContain("Claude or Codex");
      expect(html).toContain("25 Chief hours and 750 machine-minutes a week");
      expect(html).toContain("Continue on Plus after 30 days");
      expect(html).toContain("everything is kept 14 days");
    }
    // No or an unknown ?intro= is the recommended band.
    expect(await renderPage()).toContain('data-cloud-intro="a"');
    expect(await renderPage("z")).toContain('data-cloud-intro="a"');
    expect(await renderPage("b")).toContain("md:grid-cols-2 lg:grid-cols-4");
  });

  test("renew is off by default; renew=1 goes to checkout only when ticked", async () => {
    process.env.CMUX_CLOUD_INTRO = "1";
    const html = await renderPage("a");
    expect(submittedQuery(html, false)).toBe("plan=intro");
    expect(submittedQuery(html, true)).toBe("plan=intro&renew=1");
  });

  test("every number comes from cloudIntro.ts", () => {
    expect(cloudIntroOfferFacts()).toEqual({
      priceUsd: 1,
      termDays: 30,
      chiefVcpu: 2,
      chiefGib: 4,
      chiefHours: 100,
      chiefHoursWeekly: 25,
      machineMinutes: 3_000,
      machineMinutesWeekly: 750,
      machineMinuteHours: 25,
      otherVcpu: 4,
      otherGib: 8,
      concurrentMachines: 5,
      keepDays: 14,
    });
    expect(cloudIntroLayout(undefined)).toBe("a");
    expect(cloudIntroLayout(["c"])).toBe("c");
  });

  test("the new strings name no vendor, cost or margin, and nothing that is not offered", () => {
    for (const word of [
      /margin/i, /\bcost/i, /stripe/i, /freestyle/i, /vercel/i, /planetscale/i, /\baws\b/i, /amazon/i,
      /anthropic/i, /openai/i, /daytona/i, /\be2b\b/i, /modal/i, /\bfly\b/i, /cloudflare/i, /google/i,
      /free week/i, /\bten machines/i, /\b10 machines/i, /trial/i,
    ]) {
      expect(introStrings).not.toMatch(word);
    }
  });
});

describe("the $1 pass /pricing notices", () => {
  const renderBanner = (billing: string, cloudIntro: boolean) => {
    search = new URLSearchParams({ billing });
    return renderToString(<ProWelcomeBanner cloudIntro={cloudIntro} />);
  };

  test("the catalog says what checkout's copy says", () => {
    expect(enMessages.pricing.cloudIntro).toEqual(CLOUD_INTRO_BILLING_COPY);
  });

  for (const [code, message] of Object.entries(CLOUD_INTRO_BILLING_COPY)) {
    test(`renders ${code} only with the flag on`, () => {
      expect(cloudIntroBillingCode(code)).toBe(code as keyof typeof CLOUD_INTRO_BILLING_COPY);
      expect(renderBanner(code, true)).toContain(message.replace("'", "&#x27;"));
      expect(renderBanner(code, false)).toBe("");
    });
  }

  test("the existing codes are unchanged", () => {
    expect(renderBanner("cancelled", true)).toContain(enMessages.pricing.billingCancelled);
    expect(renderBanner("cancelled", false)).toContain(enMessages.pricing.billingCancelled);
    expect(cloudIntroBillingCode("toString")).toBeNull();
  });
});

describe("the proof strip on the $1 pass", () => {
  const { cloudIntroProofStats, CLOUD_PROOF_BURST_MACHINES, CLOUD_PROOF_BURST_LAST_READY_SECONDS } =
    require("../services/billing/cloudIntroProof") as typeof import("../services/billing/cloudIntroProof");

  test("the constants are the measured figures", () => {
    expect(cloudIntroProofStats()).toEqual([
      { id: "newMachine", seconds: 9.5 },
      { id: "burst", seconds: 19.8, machines: 10 },
      { id: "chatMove", seconds: 158 },
    ]);
  });

  test("every layout shows each number from the constants, and only those", async () => {
    process.env.CMUX_CLOUD_INTRO = "1";
    for (const layout of ["a", "b", "c"]) {
      const html = await renderPage(layout);
      const strip = html.match(/data-testid="cloud-intro-proof"[\s\S]*?<\/dl>/)?.[0];
      if (!strip) throw new Error(`no proof strip in layout ${layout}`);
      const shown = [...strip.matchAll(/<dt[^>]*>([^<]*)<\/dt>/g)].map((m) => m[1]);
      expect(shown).toEqual(cloudIntroProofStats().map((stat) => `${stat.seconds} s`));
      expect(strip).toContain(`${CLOUD_PROOF_BURST_MACHINES} machines`);
      expect(shown).toContain(`${CLOUD_PROOF_BURST_LAST_READY_SECONDS} s`);
      expect(html).toContain(`up to ${cloudIntroOfferFacts().concurrentMachines} machines at once`);
    }
  });

  test("the flag off shows no strip, and the strip names no vendor", async () => {
    delete process.env.CMUX_CLOUD_INTRO;
    expect(await renderPage()).not.toContain("cloud-intro-proof");
    const strings = JSON.stringify(enMessages.nextPricing.proof);
    for (const word of [/stripe/i, /freestyle/i, /vercel/i, /\baws\b/i, /anthropic/i, /openai/i, /google/i, /\$/, /margin/i, /\bcost/i]) {
      expect(strings).not.toMatch(word);
    }
  });
});
