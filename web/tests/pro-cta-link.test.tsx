import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

const capture = mock(() => undefined);

mock.module("posthog-js", () => ({
  default: { capture },
}));

const { ProCtaLink } = await import(
  "../app/[locale]/components/pro-cta-link"
);
const { PricingIntervalProvider } = await import(
  "../app/components/pricing-interval-selector"
);

describe("Pro pricing CTA", () => {
  test("routes the initial monthly selection to Stripe checkout", () => {
    const html = renderToStaticMarkup(
      <PricingIntervalProvider initialInterval="month">
        <ProCtaLink
          checkoutHrefs={{
            month: "/api/billing/checkout?plan=pro&interval=month",
            year: "/api/billing/checkout?plan=pro&interval=year",
          }}
        >
          Get Pro
        </ProCtaLink>
      </PricingIntervalProvider>,
    );

    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;interval=month"',
    );
    expect(html).not.toContain("interval=year");
    expect(html).not.toContain('href="/download/confirmation?dl=1"');
  });

  test("routes the initial annual selection to annual Stripe checkout", () => {
    const html = renderToStaticMarkup(
      <PricingIntervalProvider initialInterval="year">
        <ProCtaLink
          checkoutHrefs={{
            month: "/api/billing/checkout?plan=pro&interval=month",
            year: "/api/billing/checkout?plan=pro&interval=year",
          }}
        >
          Get Pro
        </ProCtaLink>
      </PricingIntervalProvider>,
    );

    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;interval=year"',
    );
    expect(html).not.toContain("interval=month");
  });
});
