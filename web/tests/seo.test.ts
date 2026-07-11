import { describe, expect, test } from "bun:test";
import { NextRequest } from "next/server";
import { createTranslator } from "use-intl/core";
import { comparePages } from "../app/lib/compare-pages";
import sitemap from "../app/sitemap";
import { legalMetadata } from "../app/[locale]/(legal)/legal-metadata";
import middleware from "../proxy";
import {
  buildAlternates,
  canonicalUrl,
  completeMetadataSentence,
  hasLocalizedSeoCopy,
  joinMetadataSentences,
  joinMetadataQuestionAndAnswer,
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
  docsPageSeoCopy,
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
    expect(seoDescription("ja", "Hacker Newsでcmuxをローンチした話。"))
      .toContain("縦型タブ、通知、分割ペイン、ブラウザ自動化、セッション復元");
    const thaiDescription = seoDescription(
      "th",
      "ทำไมเราถึงสร้าง cmux เทอร์มินัลใหม่สำหรับ macOS",
    );
    expect(thaiDescription).toContain(
      "สร้างมาเพื่อเอเจนต์เขียนโค้ด AI บน macOS.",
    );
    expect(searchSnippetLength(thaiDescription)).toBeGreaterThanOrEqual(90);
    expect(searchSnippetLength(thaiDescription)).toBeLessThanOrEqual(160);
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

  test("joins metadata sentences without duplicating localized punctuation", () => {
    expect(joinMetadataSentences("km", "សាកល្បង។", "បន្ទាប់")).toBe(
      "សាកល្បង។ បន្ទាប់",
    );
    expect(joinMetadataSentences("ja", "ブランドアセット", "次の文です。")).toBe(
      "ブランドアセット。次の文です。",
    );
    expect(
      completeMetadataSentence("en", "The terminal built for multitasking"),
    ).toBe("The terminal built for multitasking.");
    expect(completeMetadataSentence("en", "Examples:")).toBe("Examples:");
    expect(joinMetadataQuestionAndAnswer("th", "ทำไมต้อง cmux", "เพราะเร็ว")).toBe(
      "ทำไมต้อง cmux? เพราะเร็ว.",
    );
  });

  test("preserves overbound authored copy when no complete candidate fits", () => {
    const description = `${"A".repeat(157)}👩🏽‍💻${"B".repeat(20)}`;
    expect(seoDescription("en", description)).toBe(description);

    const title =
      "The best terminal and agent workspace for every AI coding workflow in 2026";
    expect(
      seoTitle("en", title, { fallbackCandidates: ["Short fallback"] }),
    ).toBe(title);

    const safeCandidate = `Complete localized route description ${"B".repeat(75)}`;
    expect(
      seoDescription("en", "X".repeat(200), {
        minLength: 110,
        fallbackCandidates: [
          `Literal {count, plural, one {item} other {items}} ${"A".repeat(60)}`,
          safeCandidate,
        ],
      }),
    ).toBe(safeCandidate);
    expect(
      seoTitle("en", "Compare {product} for AI coding agents", {
        fallbackCandidates: ["Complete safe metadata title for cmux"],
      }),
    ).toBe("Complete safe metadata title for cmux");
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
          [
            messages.blog.title,
            messages.blog.metaDescription,
            messages.blog.description,
          ],
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
            messages.blog.posts.cmuxHistory.reopenTitle,
            messages.blog.posts.cmuxHistory.agentTitle,
            messages.blog.posts.cmuxHistory.focusTitle,
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
            pageMessages.faqQ2,
            pageMessages.faqQ3,
            pageMessages.summaryBody,
            pageMessages.intro,
            ...(page.key === "bestTerminalForAgents"
              ? [messages.landing.links.agents]
              : []),
            ...(page.key === "multipleClaudeAgents"
              ? [messages.landing.links.claudeTeams]
              : []),
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
                  ? [messages.landing.links.claudeTeams]
                  : []),
              ],
          ),
        );
      }
      expect(new Set(compareTitles).size).toBe(comparePages.length);

      const auditedDocsPages = [
        ["/docs/agent-integrations/oh-my-opencode", "ohMyOpenCode"],
        ["/docs/api", "api"],
        ["/docs/configuration", "configuration"],
        ["/docs/browser-automation", "browserAutomation"],
        ["/docs/ios", "ios"],
        ["/docs/ssh", "ssh"],
        ["/docs/workspace-groups", "workspaceGroups"],
        ["/docs/textbox", "textBox"],
        ["/docs/concepts", "concepts"],
        ["/docs/custom-commands", "customCommands"],
        ["/docs/notifications", "notifications"],
        ["/docs/session-restore", "sessionRestore"],
        ["/docs/skills", "skills"],
        ["/docs/dock", "dock"],
        ["/docs/keyboard-shortcuts", "keyboardShortcuts"],
        ["/docs/getting-started", "gettingStarted"],
        ["/docs/remote-tmux", "remoteTmux"],
      ] as const;
      for (const [path, pageKey] of auditedDocsPages) {
        if (
          pageKey === "remoteTmux" &&
          locale !== "en" &&
          locale !== "ja"
        ) {
          continue;
        }
        const page = messages.docs[pageKey];
        rows.push(
          auditedRow(
            path,
            docsPageSeoCopy(
              locale,
              pageKey,
              messageLookup(page),
              siteMeta,
            ),
            Object.values(page).filter(
              (value): value is string =>
                typeof value === "string" && !value.includes("<"),
            ),
            [page.metaTitle, page.title],
          ),
        );
      }

      if (locale === "en" || locale === "ja") {
        const pricing = messageLookup(messages.pricing);
        rows.push(
          auditedRow(
            "/pricing",
            pricingSeoCopy(locale, pricing, siteMeta, "metaDescription"),
            [
              messages.pricing.title,
              messages.pricing.metaDescription,
              messages.pricing.metaDescriptionShort,
            ],
          ),
          auditedRow(
            "/pricing?without-vault",
            pricingSeoCopy(
              locale,
              pricing,
              siteMeta,
              "metaDescriptionNoVault",
            ),
            [
              messages.pricing.title,
              messages.pricing.metaDescriptionNoVault,
              messages.pricing.metaDescriptionNoVaultShort,
            ],
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
        if (descriptionLength < 110 || descriptionLength > 160) {
          throw new Error(
            `${locale}${row.route} description length ${descriptionLength}: ${row.copy.description}`,
          );
        }
        if (!conciseTitleLocales.has(locale)) {
          expect(titleLength).toBeGreaterThanOrEqual(30);
        }
        expect(titleLength).toBeLessThanOrEqual(60);
        expect(row.copy.title).not.toMatch(/cmux\s*—\s*cmux/iu);
        expect(`${row.copy.title}${row.copy.description}`).not.toMatch(
          /…|<\/?(?:link|code)>/u,
        );
        expect(`${row.copy.title}${row.copy.description}`).not.toMatch(
          /[{}]|__CMUXPH/iu,
        );
        expect(row.copy.description).not.toMatch(/[!?។៕。！？؟]\./u);
        expect(row.copy.description).not.toMatch(/[:：][.。]/u);
        expect(row.copy.description).toMatch(/[.!?。！？؟។៕]$/u);
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

  test("uses deterministic code-point widths for Khmer metadata", async () => {
    const messages = await messagesFor("km");
    const page = messages.landing.compare.pages.cmuxVsZed;
    const copy = comparePageSeoCopy(
      "km",
      "cmuxVsZed",
      messageLookup(page),
      messageLookup(messages.landing.links),
      messageLookup(messages.meta),
    );

    expect(searchSnippetLength("ក\u17D2ម")).toBe(4);
    expect(copy.description).not.toBe(page.metaDescription);
    expect(copy.description).toContain(page.faqQ2);
    expect(copy.description).toContain(page.faqA2);
    expect(searchSnippetLength(copy.description)).toBeGreaterThanOrEqual(110);
    expect(searchSnippetLength(copy.description)).toBeLessThanOrEqual(160);
  });

  test("keeps synthesized compare metadata tied to its localized route", async () => {
    const messages = await messagesFor("th");
    const lookup = messageLookup(messages.landing.links);
    const siteMeta = messageLookup(messages.meta);
    const bestTerminal = messages.landing.compare.pages.bestTerminalForAgents;
    const bestTerminalCopy = comparePageSeoCopy(
      "th",
      "bestTerminalForAgents",
      messageLookup(bestTerminal),
      lookup,
      siteMeta,
    );
    const multipleAgents = messages.landing.compare.pages.multipleClaudeAgents;
    const multipleAgentsCopy = comparePageSeoCopy(
      "th",
      "multipleClaudeAgents",
      messageLookup(multipleAgents),
      lookup,
      siteMeta,
    );

    expect(bestTerminalCopy.description).toContain(bestTerminal.faqQ2);
    expect(bestTerminalCopy.description).toContain(`${bestTerminal.faqQ2}?`);
    expect(bestTerminalCopy.description).toContain(bestTerminal.faqA2);
    expect(bestTerminalCopy.description).not.toBe(bestTerminal.faqA1);
    expect(multipleAgentsCopy.title).toContain(
      messages.landing.links.claudeTeams,
    );
    expect(multipleAgentsCopy.title).not.toContain("cmux · Claude Code");

    const khmerMessages = await messagesFor("km");
    const khmerMultipleAgents =
      khmerMessages.landing.compare.pages.multipleClaudeAgents;
    const khmerCopy = comparePageSeoCopy(
      "km",
      "multipleClaudeAgents",
      messageLookup(khmerMultipleAgents),
      messageLookup(khmerMessages.landing.links),
      messageLookup(khmerMessages.meta),
    );
    expect(khmerCopy.description).not.toContain("។.");
  });

  test("prefers complete route prose over generic metadata context", async () => {
    const messages = await messagesFor("en");
    const siteMeta = messageLookup(messages.meta);
    const communityCopy = communitySeoCopy(
      "en",
      messageLookup(messages.community),
      siteMeta,
    );
    const pricingCopy = pricingSeoCopy(
      "en",
      messageLookup(messages.pricing),
      siteMeta,
      "metaDescription",
    );

    expect(communityCopy.description).toContain(messages.community.description);
    expect(pricingCopy.description).toContain("Pro");
    expect(pricingCopy.description).toContain("Enterprise");
    expect(pricingCopy.description).not.toBe(
      joinMetadataSentences(
        "en",
        messages.pricing.title,
        "Built for AI coding agents on macOS.",
      ),
    );

    const khmerMessages = await messagesFor("km");
    const khmerBlogCopy = blogIndexSeoCopy(
      "km",
      messageLookup(khmerMessages.blog),
      messageLookup(khmerMessages.meta),
    );
    expect(khmerBlogCopy.description).toContain(
      khmerMessages.blog.description,
    );
  });

  test("reads docs candidates without formatting UI placeholders", async () => {
    const messages = await messagesFor("zh-CN");
    const docs = createTranslator({
      locale: "zh-CN",
      messages,
      namespace: "docs.concepts",
    });
    const meta = createTranslator({
      locale: "zh-CN",
      messages,
      namespace: "meta",
    });

    const copy = docsPageSeoCopy(
      "zh-CN",
      "concepts",
      (key) => docs(key as never),
      (key) => meta(key as never),
    );

    expect(`${copy.title}${copy.description}`).not.toMatch(/\{[^{}]+\}/u);
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

    const wildcardPrefersEnglish = middleware(
      requestFor("/pricing", {
        "accept-language": "ja;q=0.5,*;q=0.9",
      }),
    );
    expect(wildcardPrefersEnglish.status).toBe(200);
    expect(wildcardPrefersEnglish.headers.get("location")).toBeNull();
    expect(wildcardPrefersEnglish.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/pricing",
    );

    const wildcardExcludesEnglish = middleware(
      requestFor("/pricing", {
        "accept-language": "en;q=0,*;q=1",
      }),
    );
    expect(wildcardExcludesEnglish.status).toBe(307);
    expect(wildcardExcludesEnglish.headers.get("location")).toBe(
      "https://cmux.com/ja/pricing",
    );

    const invalidJapaneseQuality = middleware(
      requestFor("/pricing", {
        "accept-language": "ja;q=0.8oops,en;q=0.4",
      }),
    );
    expect(invalidJapaneseQuality.status).toBe(200);
    expect(invalidJapaneseQuality.headers.get("location")).toBeNull();

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

    const cookieEnglish = middleware(
      requestFor("/pricing", {
        cookie: "NEXT_LOCALE=en",
        "accept-language": "en;q=0,*;q=1",
      }),
    );
    expect(cookieEnglish.status).toBe(200);
    expect(cookieEnglish.headers.get("location")).toBeNull();
    expect(cookieEnglish.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/pricing",
    );

    const unavailableCookieLocale = middleware(
      requestFor("/pricing", {
        cookie: "NEXT_LOCALE=de",
        "accept-language": "ja,en;q=0.9",
      }),
    );
    expect(unavailableCookieLocale.status).toBe(200);
    expect(unavailableCookieLocale.headers.get("location")).toBeNull();
    expect(unavailableCookieLocale.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/pricing",
    );
    expect(unavailableCookieLocale.headers.get("set-cookie")).toBeNull();

    const encodedUnavailableLocale = middleware(
      requestFor("/de/pr%69cing", { "accept-language": "de" }),
    );
    expect(encodedUnavailableLocale.status).toBe(301);
    expect(encodedUnavailableLocale.headers.get("location")).toBe(
      "https://cmux.com/pricing",
    );

    const encodedDocsLocale = middleware(
      requestFor("/de/docs/agent-integrations/oh-my-p%69", {
        "accept-language": "de",
      }),
    );
    expect(encodedDocsLocale.status).toBe(301);
    expect(encodedDocsLocale.headers.get("location")).toBe(
      "https://cmux.com/docs/agent-integrations/oh-my-pi",
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

const wideSearchBaseCodePoint =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Thai}\p{Script=Khmer}\p{Extended_Pictographic}]/u;
const zeroWidthSearchCodePoint =
  /[\p{Mark}\u200D\uFE0E\uFE0F\u{E0100}-\u{E01EF}\u{1F3FB}-\u{1F3FF}]/u;
const conciseTitleLocales = new Set(["ja", "zh-CN", "zh-TW", "ko"]);
type Messages = typeof import("../messages/en.json");
type SeoCopy = { title: string; description: string };

function searchSnippetLength(value: string) {
  return Array.from(value).reduce((sum, codePoint) => {
    if (zeroWidthSearchCodePoint.test(codePoint)) return sum;
    return sum + (wideSearchBaseCodePoint.test(codePoint) ? 2 : 1);
  }, 0);
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
