import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import { CheckoutPendingContent } from "../app/components/checkout-navigation";

describe("checkout loading content", () => {
  test("keeps the label in layout and centers the pending spinner", () => {
    const html = renderToStaticMarkup(
      <CheckoutPendingContent pending>Get Teams</CheckoutPendingContent>,
    );

    expect(html).toContain('class="invisible"');
    expect(html).toContain(
      'class="absolute inset-0 flex items-center justify-center"',
    );
    expect(html).toContain("<svg");
    expect(html).toContain("Get Teams");
  });

  test("shows the label without a spinner when idle", () => {
    const html = renderToStaticMarkup(
      <CheckoutPendingContent pending={false}>
        Get Teams
      </CheckoutPendingContent>,
    );

    expect(html).not.toContain('class="invisible"');
    expect(html).not.toContain("absolute inset-0");
    expect(html).not.toContain("<svg");
    expect(html).toContain("Get Teams");
  });
});
