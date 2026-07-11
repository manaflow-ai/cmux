import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import middleware from "../proxy";
import {
  buildAlternates,
  canonicalUrl,
  hasLocalizedSeoCopy,
  openGraphDefaults,
  openGraphImageTagline,
  seoDescription,
  seoTitle,
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
    expect(seoDescription("en", "CLI reference")).toContain(
      "vertical tabs, notifications, split panes, and browser automation",
    );
    expect(seoDescription("ja", "CLI リファレンス。")).toContain(
      "macOS の AI コーディングエージェント向け。",
    );
    expect(
      seoDescription(
        "en",
        "A detailed page about running multiple coding agents in cmux on macOS.",
      ),
    ).toContain("Built for AI coding agents on macOS,");
  });

  test("keeps descriptions within search snippet bounds", () => {
    const short = seoDescription("en", "News from the cmux team");
    expect(short.length).toBeGreaterThanOrEqual(110);
    expect(short.length).toBeLessThanOrEqual(160);

    const long = seoDescription(
      "en",
      "A very long metadata description ".repeat(12),
    );
    expect(long.length).toBeLessThanOrEqual(160);
    expect(long.endsWith("…")).toBe(true);
    expect(long).not.toMatch(/\s…$/);
  });

  test("keeps truncated descriptions above the minimum boundary", () => {
    const description = seoDescription(
      "en",
      `${"A".repeat(100)}. ${"B".repeat(100)}`,
    );
    expect(Array.from(description).length).toBeGreaterThanOrEqual(110);
    expect(Array.from(description).length).toBeLessThanOrEqual(160);
  });

  test("does not split Unicode characters at the metadata cutoff", () => {
    const description = seoDescription(
      "en",
      `${"A".repeat(158)}👩🏽‍💻${"B".repeat(20)}`,
    );
    expect(description).toContain("👩🏽‍💻");
    expect(
      Array.from(
        new Intl.Segmenter("en", { granularity: "grapheme" }).segment(
          description,
        ),
      ).length,
    ).toBeLessThanOrEqual(160);
  });

  test("adds useful context to short titles and trims long titles", () => {
    expect(seoTitle("en", "Blog")).toBe(
      "Blog — The terminal built for multitasking",
    );
    const long = seoTitle(
      "en",
      "The best terminal and agent workspace for every AI coding workflow in 2026",
    );
    expect(long.length).toBeLessThanOrEqual(60);
    expect(long.endsWith("…")).toBe(true);
  });

  test("adds complete shared social metadata", () => {
    expect(openGraphDefaults("en", "article")).toEqual({
      siteName: "cmux",
      type: "article",
      images: [
        {
          url: "https://cmux.com/opengraph-image",
          width: 2400,
          height: 1260,
          alt: "cmux - The terminal built for multitasking",
        },
      ],
    });
    expect(twitterSummary("en", "Title", "Description")).toEqual({
      card: "summary_large_image",
      title: "Title",
      description: "Description",
      images: ["https://cmux.com/opengraph-image"],
    });
    expect(twitterSummary("ja", "Title", "Description").images).toEqual([
      "https://cmux.com/ja/opengraph-image",
    ]);
  });

  test("has localized SEO fallback copy for every configured locale", () => {
    for (const locale of locales) {
      expect(hasLocalizedSeoCopy(locale)).toBe(true);
      expect(seoDescription(locale, "CLI reference").length).toBeGreaterThan(
        "CLI reference".length,
      );
      expect(openGraphDefaults(locale, "website").images[0].alt).not.toBe("");
      expect(openGraphImageTagline(locale)).not.toBe("");
      expect(seoDescription(locale, "CLI reference").length).toBeLessThanOrEqual(
        160,
      );
    }
  });
});

describe("SEO middleware", () => {
  test("serves the English remote tmux docs without locale redirect loops", () => {
    const unsupportedLocale = middleware(
      requestFor("/de/docs/remote-tmux", { "accept-language": "de" }),
    );
    expect(unsupportedLocale.status).toBe(301);
    expect(unsupportedLocale.headers.get("location")).toBe(
      "https://cmux.com/docs/remote-tmux",
    );

    const canonicalEnglish = middleware(
      requestFor("/docs/remote-tmux", { "accept-language": "de" }),
    );
    expect(canonicalEnglish.status).toBe(200);
    expect(canonicalEnglish.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/docs/remote-tmux",
    );
    expect(canonicalEnglish.headers.get("location")).toBeNull();
  });
});

function requestFor(pathname: string, headers: Record<string, string> = {}) {
  return new NextRequest(`https://cmux.com${pathname}`, {
    headers: {
      host: "cmux.com",
      ...headers,
    },
  });
}
