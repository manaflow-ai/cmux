import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import { comparePages } from "../app/lib/compare-pages";
import sitemap from "../app/sitemap";
import { legalMetadata } from "../app/[locale]/(legal)/legal-metadata";
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
import {
  assetsSeoCopy,
  bestTerminalSeoCopy,
  blogIndexSeoCopy,
  cmuxHistorySeoCopy,
  communitySeoCopy,
  compareIndexSeoCopy,
  comparePageSeoCopy,
  homeSeoCopy,
  ohMyPiSeoCopy,
  pricingSeoCopy,
} from "../i18n/audited-seo";
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
    const overboundWithSuffix =
      "A detailed page about running multiple coding agents in cmux on macOS.";
    expect(
      seoDescription("en", overboundWithSuffix, { minLength: 110 }),
    ).toBe(overboundWithSuffix);
  });

  test("appends complete localized context only when the result fits", () => {
    const short = seoDescription("en", "News from the cmux team", {
      minLength: 110,
    });
    expect(short.length).toBeGreaterThanOrEqual(110);
    expect(short.length).toBeLessThanOrEqual(160);

    const original = "A very long metadata description ".repeat(12).trim();
    expect(seoDescription("en", original)).toBe(original);
  });

  test("preserves overbound authored copy when no complete candidate fits", () => {
    const description = `${"A".repeat(157)}👩🏽‍💻${"B".repeat(20)}`;
    expect(seoDescription("en", description)).toBe(description);

    const title =
      "The best terminal and agent workspace for every AI coding workflow in 2026";
    expect(
      seoTitle("en", title, { fallbackCandidates: ["Short fallback"] }),
    ).toBe(title);
  });

  test("adds useful context to short titles and selects complete fallbacks", () => {
    expect(seoTitle("en", "Blog")).toBe(
      "Blog — The terminal built for multitasking",
    );
    expect(
      seoTitle(
        "en",
        "The best terminal and agent workspace for every AI coding workflow in 2026",
        { fallbackCandidates: ["A complete authored fallback title"] },
      ),
    ).toBe("A complete authored fallback title");
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

  test("keeps legal descriptions limited to their legal summary", () => {
    const summary = "The terms that govern use of cmux.";
    expect(legalMetadata("/terms-of-service", "Terms", summary).description).toBe(
      summary,
    );
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
      const standardDescription = seoDescription(locale, "CLI reference");
      const detailedDescription = seoDescription(locale, "CLI reference", {
        minLength: 110,
      });
      const detailedLength = searchSnippetLength(detailedDescription);
      expect(hasLocalizedSeoCopy(locale)).toBe(true);
      expect(openGraphDefaults(locale, "website").images[0].alt).not.toBe("");
      expect(openGraphImageTagline(locale)).not.toBe("");
      expect(standardDescription).not.toContain("…");
      expect(detailedDescription).not.toContain("…");
      expect(searchSnippetLength(standardDescription)).toBeLessThanOrEqual(160);
      expect(detailedLength).toBeLessThanOrEqual(160);
    }
  });

  test("selects bounded, route-specific copy for the audited matrix", async () => {
    for (const locale of locales) {
      const messages = await messagesFor(locale);
      const siteMeta = messageLookup(messages.meta);
      const rows = [
        auditedRow("/", homeSeoCopy(locale, siteMeta), [
          "cmux",
          messages.meta.description,
          messages.meta.ogDescription,
        ]),
        auditedRow(
          "/assets",
          assetsSeoCopy(locale, messageLookup(messages.brandAssets), siteMeta),
          [
            messages.brandAssets.title,
            messages.brandAssets.metaDescription,
            messages.brandAssets.description,
          ],
        ),
        auditedRow(
          "/blog",
          blogIndexSeoCopy(locale, messageLookup(messages.blog), siteMeta),
          [messages.blog.title, messages.blog.metaDescription],
        ),
        auditedRow(
          "/blog/cmux-history",
          cmuxHistorySeoCopy(
            locale,
            messageLookup(messages.blog.cmuxHistory),
            messageLookup(messages.blog.posts.cmuxHistory),
            siteMeta,
          ),
          [
            messages.blog.cmuxHistory.metaDescription,
            messages.blog.posts.cmuxHistory.title,
            messages.blog.posts.cmuxHistory.summary,
            messages.blog.posts.cmuxHistory.p1,
            messages.blog.posts.cmuxHistory.focusP,
            messages.blog.posts.cmuxHistory.fullHistoryP,
          ],
          [
            messages.blog.cmuxHistory.metaTitle,
            messages.blog.posts.cmuxHistory.title,
            messages.blog.posts.cmuxHistory.reopenTitle,
            messages.blog.posts.cmuxHistory.agentTitle,
            messages.blog.posts.cmuxHistory.focusTitle,
          ],
        ),
        auditedRow(
          "/community",
          communitySeoCopy(
            locale,
            messageLookup(messages.community),
            siteMeta,
          ),
          [
            messages.community.title,
            messages.community.metaDescription,
            messages.community.description,
          ],
        ),
        auditedRow(
          "/best-terminal-for-mac",
          bestTerminalSeoCopy(
            locale,
            messageLookup(messages.landing.bestTerminal),
            siteMeta,
          ),
          [
            messages.landing.bestTerminal.title,
            messages.landing.bestTerminal.metaDescription,
            messages.landing.bestTerminal.cmuxBuiltFor,
          ],
        ),
        auditedRow(
          "/compare",
          compareIndexSeoCopy(
            locale,
            messageLookup(messages.landing.compare),
            siteMeta,
          ),
          [
            messages.landing.compare.title,
            messages.landing.compare.metaDescription,
            messages.landing.compare.intro,
          ],
          [
            messages.landing.compare.metaTitle,
            messages.landing.compare.title,
          ],
        ),
      ];

      const compareTitles: string[] = [];
      for (const page of comparePages) {
        const pageMessages = messages.landing.compare.pages[page.key];
        const copy = comparePageSeoCopy(
          locale,
          page.key,
          messageLookup(pageMessages),
          messageLookup(messages.landing.links),
          siteMeta,
        );
        compareTitles.push(copy.title);
        rows.push(
          auditedRow(`/compare/${page.slug}`, copy, [
            pageMessages.title,
            pageMessages.metaDescription,
            pageMessages.faqQ1,
            pageMessages.summaryBody,
            pageMessages.intro,
            pageMessages.faqA1,
            pageMessages.faqA2,
            pageMessages.faqA3,
          ],
          page.key === "bestTerminalForAgents"
            ? [
                pageMessages.metaTitle,
                pageMessages.title,
                messages.landing.links.bestTerminal,
              ]
            : [
                pageMessages.metaTitle,
                pageMessages.title,
                ...(page.key === "multipleClaudeAgents"
                  ? ["cmux · Claude Code"]
                  : []),
              ],
          ),
        );
      }
      expect(new Set(compareTitles).size).toBe(comparePages.length);

      if (locale === "en" || locale === "ja") {
        const pricing = messageLookup(messages.pricing);
        rows.push(
          auditedRow(
            "/pricing",
            pricingSeoCopy(locale, pricing, siteMeta, "metaDescription"),
            [messages.pricing.title, messages.pricing.metaDescription],
          ),
          auditedRow(
            "/pricing?without-vault",
            pricingSeoCopy(
              locale,
              pricing,
              siteMeta,
              "metaDescriptionNoVault",
            ),
            [messages.pricing.title, messages.pricing.metaDescriptionNoVault],
          ),
          auditedRow(
            "/docs/agent-integrations/oh-my-pi",
            ohMyPiSeoCopy(
              locale,
              messageLookup(messages.docs.ohMyPi),
              siteMeta,
            ),
            [
              messages.docs.ohMyPi.title,
              messages.docs.ohMyPi.metaDescription,
              messages.docs.ohMyPi.intro,
            ],
          ),
        );
      }

      for (const row of rows) {
        const titleLength = searchSnippetLength(row.copy.title);
        const descriptionLength = searchSnippetLength(row.copy.description);
        if (!conciseTitleLocales.has(locale)) {
          expect(titleLength).toBeGreaterThanOrEqual(30);
        }
        expect(titleLength).toBeLessThanOrEqual(60);
        expect(descriptionLength).toBeGreaterThanOrEqual(110);
        expect(descriptionLength).toBeLessThanOrEqual(160);
        expect(`${row.copy.title}${row.copy.description}`).not.toMatch(
          /…|<\/?(?:link|code)>/u,
        );
        const hasRouteContext = row.contexts.some(
          (context) =>
            context.length > 0 && row.copy.description.includes(context),
        );
        if (!hasRouteContext) {
          throw new Error(
            `${locale}${row.route} lost route context: ${row.copy.description}`,
          );
        }
        if (
          !row.titleContexts.some(
            (context) =>
              context.length > 0 && row.copy.title.includes(context),
          )
        ) {
          throw new Error(
            `${locale}${row.route} lost title identity: ${row.copy.title}`,
          );
        }
      }
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
      expect(canonical.headers.get("Link")).toContain('hreflang="ja"');
      expect(canonical.headers.get("Link")).not.toContain('hreflang="de"');
    }

    const negotiatedJapanese = middleware(
      requestFor("/pricing", { "accept-language": "ja,en;q=0.9" }),
    );
    expect(negotiatedJapanese.status).toBe(307);
    expect(negotiatedJapanese.headers.get("location")).toBe(
      "https://cmux.com/ja/pricing",
    );
    expect(negotiatedJapanese.headers.get("location")).not.toContain("/en/");

    const cookieJapanese = middleware(
      requestFor("/pricing", {
        cookie: "NEXT_LOCALE=ja",
        "accept-language": "en",
      }),
    );
    expect(cookieJapanese.status).toBe(307);
    expect(cookieJapanese.headers.get("location")).toBe(
      "https://cmux.com/ja/pricing",
    );

    const japanese = middleware(
      requestFor("/ja/pricing", { "accept-language": "ja" }),
    );
    expect(japanese.status).toBe(200);
    expect(japanese.headers.get("location")).toBeNull();
    expect(japanese.headers.get("Link")).toContain('hreflang="en"');
    expect(japanese.headers.get("Link")).toContain('hreflang="ja"');
    expect(japanese.headers.get("Link")).not.toContain('hreflang="de"');
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
const conciseTitleLocales = new Set(["ja", "zh-CN", "zh-TW", "ko"]);
type Messages = typeof import("../messages/en.json");
type SeoCopy = { title: string; description: string };

function searchSnippetLength(value: string) {
  return Array.from(searchWidthSegmenter.segment(value), ({ segment }) =>
    wideSearchGrapheme.test(segment) ? 2 : 1,
  ).reduce((sum, length) => sum + length, 0);
}

function messageLookup(messages: object) {
  return (key: string) => {
    const value = (messages as Record<string, unknown>)[key];
    if (typeof value !== "string") {
      throw new Error(`Expected a string message for ${key}`);
    }
    return value;
  };
}

async function messagesFor(locale: string) {
  return (await import(`../messages/${locale}.json`)).default as Messages;
}

function auditedRow(
  route: string,
  copy: SeoCopy,
  contexts: string[],
  titleContexts: string[] = [contexts[0]],
) {
  return { route, copy, contexts, titleContexts };
}

function requestFor(pathname: string, headers: Record<string, string> = {}) {
  return new NextRequest(`https://cmux.com${pathname}`, {
    headers: {
      host: "cmux.com",
      ...headers,
    },
  });
}
