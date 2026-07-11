import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import sitemap from "../app/sitemap";
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
    expect(
      seoDescription("en", "CLI reference", { minLength: 110 }),
    ).toContain(
      "vertical tabs, notifications, split panes, and browser automation",
    );
    expect(
      seoDescription("ja", "CLI リファレンス。", { minLength: 110 }),
    ).toContain(
      "macOS の AI コーディングエージェント向け。",
    );
    expect(
      seoDescription(
        "en",
        "A detailed page about running multiple coding agents in cmux on macOS.",
        { minLength: 110 },
      ),
    ).toContain("Built for AI coding agents on macOS,");
  });

  test("keeps descriptions within search snippet bounds", () => {
    const short = seoDescription("en", "News from the cmux team", {
      minLength: 110,
    });
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
      { minLength: 110 },
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

  test("can preserve a complete localized title below the generic minimum", () => {
    const title = "cmux — 专为多任务打造的终端";
    expect(seoTitle("zh-CN", title, { minLength: 0 })).toBe(title);
  });

  test("does not add localized copy to an English fallback description", () => {
    const fallback =
      "Talk with cmux about Enterprise deployment, SSO, self-hosted Cloud VMs, audit logs, and committed usage.";
    expect(seoDescription("de", fallback)).toBe(fallback);
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
      expect(
        searchSnippetLength(
          seoDescription(locale, "CLI reference", { minLength: 110 }),
        ),
      ).toBeGreaterThanOrEqual(110);
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

  test("redirects fallback-only locale routes to translated content", () => {
    for (const canonicalPath of [
      "/pricing",
      "/docs/agent-integrations/oh-my-pi",
    ]) {
      const path = `/de${canonicalPath}`;
      const response = middleware(
        requestFor(path, { "accept-language": "de" }),
      );
      expect(response.status).toBe(301);
      expect(response.headers.get("location")).toBe(
        `https://cmux.com${canonicalPath}`,
      );

      const canonical = middleware(
        requestFor(canonicalPath, { "accept-language": "de" }),
      );
      expect(canonical.status).toBe(200);
      expect(canonical.headers.get("location")).toBeNull();
      expect(canonical.headers.get("x-middleware-rewrite")).toBe(
        `https://cmux.com/en${canonicalPath}`,
      );
    }

    const japanese = middleware(
      requestFor("/ja/pricing", { "accept-language": "ja" }),
    );
    expect(japanese.status).toBe(200);
    expect(japanese.headers.get("location")).toBeNull();
  });

  test("lists only translated fallback-content locales in the sitemap", () => {
    const urls = sitemap()
      .map((entry) => entry.url)
      .filter(
        (url) =>
          url.endsWith("/pricing") ||
          url.endsWith("/docs/agent-integrations/oh-my-pi"),
      );
    expect(urls).toEqual([
      "https://cmux.com/pricing",
      "https://cmux.com/ja/pricing",
      "https://cmux.com/docs/agent-integrations/oh-my-pi",
      "https://cmux.com/ja/docs/agent-integrations/oh-my-pi",
    ]);
  });
});

const searchWidthSegmenter = new Intl.Segmenter("en", {
  granularity: "grapheme",
});
const wideSearchGrapheme =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Thai}\p{Script=Khmer}\p{Extended_Pictographic}]/u;

function searchSnippetLength(value: string) {
  return Array.from(searchWidthSegmenter.segment(value), ({ segment }) =>
    wideSearchGrapheme.test(segment) ? 2 : 1,
  ).reduce((sum, length) => sum + length, 0);
}

function requestFor(pathname: string, headers: Record<string, string> = {}) {
  return new NextRequest(`https://cmux.com${pathname}`, {
    headers: {
      host: "cmux.com",
      ...headers,
    },
  });
}
