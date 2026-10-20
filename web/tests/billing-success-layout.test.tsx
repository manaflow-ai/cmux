import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

mock.module("next/font/google", () => ({
  Geist: () => ({ variable: "font-geist-sans" }),
  Geist_Mono: () => ({ variable: "font-geist-mono" }),
}));

const { default: BillingLayout } = await import("../app/billing/layout");

describe("billing success layout", () => {
  test("renders root html and body tags for the billing subtree", () => {
    const html = renderToStaticMarkup(
      <BillingLayout>
        <main>billing-success-child</main>
      </BillingLayout>,
    );

    expect(html).toContain("<html");
    expect(html).toContain("<body");
    expect(html).toContain("billing-success-child");
  });
});
