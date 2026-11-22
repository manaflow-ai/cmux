// One accessibility fixture exercises both live HTML preview paths on NEXT.
// Keep URLs and remote images subject to each renderer's existing policy.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import "../../Resources/markdown-viewer/markdown-sanitizer.js";
import { htmlPreview } from "../src/pages/markdown/htmlPreview";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
let originalDocument: Document | undefined;
let originalDOMParser: typeof DOMParser | undefined;

beforeAll(() => {
  originalDocument = globalThis.document;
  originalDOMParser = globalThis.DOMParser;
  (globalThis as Record<string, unknown>).document = dom.window.document;
  (globalThis as Record<string, unknown>).DOMParser = dom.window.DOMParser;
});

afterAll(() => {
  (globalThis as Record<string, unknown>).document = originalDocument;
  (globalThis as Record<string, unknown>).DOMParser = originalDOMParser;
  dom.window.close();
});

function classicPreview(source: string, allowImages: boolean): DocumentFragment {
  return CmuxMarkdownSanitizer.sanitizeToFragment(source, {
    document: dom.window.document,
    profile: CmuxMarkdownSanitizer.markdownProfile({
      url: ({ tag, name, value }) => {
        if (tag === "a" && name === "href" && value === "https://example.com/docs") return value;
        if (allowImages && tag === "img" && name === "src" && value === "./badge.png") return value;
        return null;
      },
    }),
  });
}

describe("Markdown HTML image-only links", () => {
  test("both renderers preserve the author's link name and decorative image", () => {
    const source =
      '<p><a href="https://example.com/docs" aria-label="Open documentation">' +
      '<img src="./badge.png" alt=""></a></p>';

    const fragments = [htmlPreview(source, (src) => src), classicPreview(source, true)];
    for (const fragment of fragments) {
      const link = fragment?.querySelector("a");
      expect(link?.getAttribute("href")).toBe("https://example.com/docs");
      expect(link?.getAttribute("aria-label")).toBe("Open documentation");
      expect(link?.textContent).toBe("");
      expect(link?.querySelector("img")?.getAttribute("alt")).toBe("");
    }
  });

  test("the name stays anchor-scoped; blocked URLs and handlers stay blocked", () => {
    const source =
      '<p aria-label="discard"><a href="javascript:alert(1)" aria-label="Open documentation" ' +
      'onclick="alert(1)" data-cmux-bridge="x"><img src="https://tracker.example/p.png" alt=""></a></p>';

    const fragments = [htmlPreview(source, () => ""), classicPreview(source, false)];
    for (const fragment of fragments) {
      const paragraph = fragment?.querySelector("p");
      const link = paragraph?.querySelector("a");
      expect(paragraph?.hasAttribute("aria-label")).toBe(false);
      expect(link?.getAttribute("aria-label")).toBe("Open documentation");
      expect(link?.hasAttribute("href")).toBe(false);
      expect(link?.hasAttribute("onclick")).toBe(false);
      expect(link?.hasAttribute("data-cmux-bridge")).toBe(false);
      expect(link?.querySelector("img")?.hasAttribute("src")).toBe(false);
    }
  });
});
