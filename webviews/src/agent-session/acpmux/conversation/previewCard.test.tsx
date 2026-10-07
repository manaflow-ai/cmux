import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { PreviewCard } from "./PreviewCard";

describe("preview card", () => {
  test("names the page, offers a browser tab, and waits for a click before it frames anything", () => {
    const html = renderToStaticMarkup(
      createElement(PreviewCard, { url: "http://localhost:5173/admin?tab=1", onOpen: () => {} }),
    );
    expect(html).toContain('<a class="acpmux-turn-preview-address" href="http://localhost:5173/admin?tab=1"');
    expect(html).toContain(">localhost:5173/admin?tab=1</a>");
    expect(html).toContain('aria-label="Open localhost:5173/admin?tab=1 in a browser tab"');
    expect(html).toContain(">Open in tab</button>");
    expect(html).toContain('aria-label="Load a preview of localhost:5173/admin?tab=1"');
    // The address is untrusted text, so nothing loads before the reader asks for it.
    expect(html).not.toContain("<iframe");
  });

  test("the root page reads as just its host", () => {
    const html = renderToStaticMarkup(createElement(PreviewCard, { url: "http://127.0.0.1:3000/", onOpen: () => {} }));
    expect(html).toContain(">127.0.0.1:3000</a>");
  });
});
