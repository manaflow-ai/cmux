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
    }
  });
});

describe("SEO middleware", () => {
  test("does not advertise unsupported locale variants globally", () => {
    const response = middleware(requestFor("/ja/docs/remote-tmux"));

    expect(response.status).toBe(200);
    expect(response.headers.get("link")).toBeNull();
  });

  test("keeps the English-only Base docs canonical during locale negotiation", () => {
    const unsupportedLocale = middleware(
      requestFor("/de/docs/base", { "accept-language": "de" }),
    );
    expect(unsupportedLocale.status).toBe(301);
    expect(unsupportedLocale.headers.get("location")).toBe(
      "https://cmux.com/docs/base",
    );

    const canonicalEnglish = middleware(
      requestFor("/docs/base", { "accept-language": "de" }),
    );
    expect(canonicalEnglish.status).toBe(200);
    expect(canonicalEnglish.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/docs/base",
    );
    expect(canonicalEnglish.headers.get("location")).toBeNull();
  });

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
