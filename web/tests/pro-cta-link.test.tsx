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
  test("routes the initial click to Stripe checkout", () => {
    const html = renderToStaticMarkup(
      <ProCtaLink
        checkoutHref="/api/billing/checkout?plan=pro"
      >
        Get Pro
      </ProCtaLink>,
    );

    expect(html).toContain(
      'href="/api/billing/checkout?plan=pro"',
    );
    expect(html).not.toContain('href="/download/confirmation?dl=1"');
  });
});
