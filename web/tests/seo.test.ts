import { describe, expect, test } from "bun:test";
import {
  buildAlternates,
  canonicalUrl,
  hasLocalizedSeoCopy,
  openGraphDefaults,
  openGraphImageTagline,
  seoDescription,
  twitterSummary,
} from "../i18n/seo";
import { locales } from "../i18n/routing";

describe("SEO metadata helpers", () => {
  test("keeps canonical URLs locale-aware", () => {
    expect(canonicalUrl("en", "/docs")).toBe("https://cmux.com/docs");
    expect(canonicalUrl("ja", "/docs")).toBe("https://cmux.com/ja/docs");
    expect(buildAlternates("ja", "/docs").canonical).toBe(
      "https://cmux.com/ja/docs",
    );
  });

  test("extends short descriptions with localized product context", () => {
    expect(seoDescription("en", "CLI reference")).toBe(
      "CLI reference. Built for AI coding agents on macOS.",
    );
    expect(seoDescription("ja", "CLI リファレンス。")).toContain(
      "macOS の AI コーディングエージェント向けです。",
    );
    expect(
      seoDescription(
        "en",
        "A detailed page about running multiple coding agents in cmux on macOS.",
      ),
    ).toContain("Built for AI coding agents on macOS.");
  });

  test("adds complete shared social metadata", () => {
    expect(openGraphDefaults("en", "article")).toEqual({
      siteName: "cmux",
      type: "article",
      images: [
        {
          url: "https://cmux.com/opengraph-image",
          width: 1200,
          height: 630,
          alt: "cmux - The terminal built for multitasking",
        },
      ],
    });
    expect(twitterSummary("Title", "Description")).toEqual({
      card: "summary_large_image",
      title: "Title",
      description: "Description",
      images: ["https://cmux.com/opengraph-image"],
    });
  });

  test("has localized SEO fallback copy for every configured locale", () => {
    for (const locale of locales) {
      expect(hasLocalizedSeoCopy(locale)).toBe(true);
      expect(seoDescription(locale, "CLI reference").length).toBeGreaterThan(
        "CLI reference".length,
      );
      expect(openGraphDefaults(locale, "website").images[0].alt).not.toBe("");
      expect(openGraphImageTagline(locale)).not.toBe("");
    }
  });
});
