import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

const capture = mock(() => undefined);

mock.module("posthog-js", () => ({
  default: { capture },
}));

const { ProCtaLink } = await import(
  "../app/[locale]/components/pro-cta-link"
);

describe("Pro pricing CTA", () => {
  test("routes the initial monthly selection to Stripe checkout", () => {
    const html = renderToStaticMarkup(
        <ProCtaLink
          checkoutHref="/api/billing/checkout?plan=pro&interval=month"
        >
          Get Pro
        </ProCtaLink>
      ,
    );

    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro&amp;interval=month&amp;cmux_placement=pricing_page"',
    );
    expect(html).not.toContain("interval=year");
    expect(html).not.toContain('href="/download/confirmation?dl=1"');
  });

});
