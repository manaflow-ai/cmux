import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AnchorHTMLAttributes, ReactNode } from "react";
import { createTranslator } from "use-intl/core";
import { NextRequest } from "next/server";
import enMessages from "../messages/en.json";
import jaMessages from "../messages/ja.json";
import middleware from "../proxy";
import sitemap from "../app/sitemap";
import { resolveAgentPageVariant } from "../app/lib/agent-page-paths";
import { jobsContentLocales } from "../i18n/locale-availability";
import { locales, type Locale } from "../i18n/routing";

type Messages = typeof enMessages;
const messagesByLocale = {} as Record<Locale, Messages>;
for (const locale of locales) {
  messagesByLocale[locale] = (
    await import(`../messages/${locale}.json`)
  ).default as Messages;
}

let activeLocale: Locale = "en";

function messagesFor(locale: Locale) {
  return messagesByLocale[locale];
}

function translator(locale: Locale, namespace?: string) {
  return createTranslator({
    locale,
    messages: messagesFor(locale),
    namespace: namespace as never,
  });
}

mock.module("next-intl", () => ({
  useLocale: () => activeLocale,
  useTranslations: (namespace?: string) => translator(activeLocale, namespace),
}));

mock.module("next-intl/server", () => ({
  getTranslations: async (
    options?: string | { locale?: string; namespace?: string },
  ) => {
    const requestedLocale =
      typeof options === "object" ? options?.locale : undefined;
    const locale = locales.includes(requestedLocale as Locale)
      ? (requestedLocale as Locale)
      : activeLocale;
    const namespace =
      typeof options === "string" ? options : options?.namespace;
    return translator(locale, namespace);
  },
}));

mock.module("../app/[locale]/components/site-header", () => ({
  SiteHeader: ({ section }: { section?: string }) => (
    <header data-section={section} />
  ),
}));

mock.module("@/i18n/navigation", () => ({
  Link: ({
    href,
    children,
    ...props
  }: AnchorHTMLAttributes<HTMLAnchorElement> & {
    href: string;
    children?: ReactNode;
  }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
}));

const { default: JobsPage, generateMetadata } =
  await import("../app/[locale]/(landing)/jobs/page");
const {
  default: FoundingDesignerPage,
  generateMetadata: generateDesignerMetadata,
} = await import("../app/[locale]/(landing)/jobs/founding-designer/page");

describe("jobs page", () => {
  test("renders the complete English role copy and application CTA", () => {
    activeLocale = "en";
    const html = renderToStaticMarkup(<JobsPage />);

    expect(html).toContain("Founding Engineer");
    expect(html).toContain(
      "Hundreds of thousands of developers use cmux to drive their agentic coding workflows.",
    );
    expect(html).toContain("Build frontier devtools across the stack");
    expect(html).toContain("Using 10B+ tokens a day.");
    expect(html).toContain("$130k–$170k + 0.5%–1.5% equity");
    expect(html).toContain("San Francisco");
    expect(html).toContain("About cmux");
    expect(html).toContain("Open roles");
    expect(html).toContain("Build the future with us.");
    expect(html).toContain('href="/jobs/founding-designer"');
    expect(html).toContain('aria-current="page"');
    expect(html).toContain(">Email<");
    expect(html).not.toContain("Email founders@cmux.com");
    expect(html).toContain(
      `href="mailto:founders@cmux.com?subject=${encodeURIComponent(
        enMessages.jobs.applyEmailSubject,
      )}"`,
    );
    expect(html).toContain("focus-visible:outline-2");
    expect(html).toContain('aria-labelledby="jobs-title"');
  });

  test("renders the authored Japanese presentation", () => {
    activeLocale = "ja";
    const html = renderToStaticMarkup(<JobsPage />);

    expect(html).toContain("採用中");
    expect(html).toContain("仕事内容");
    expect(html).toContain("数十万人の開発者が");
    expect(html).toContain("$130k〜$170k + 株式 0.5%〜1.5%");
    expect(html).toContain("募集中のポジション");
    expect(html).toContain("一緒に未来をつくりませんか。");
    expect(html).toContain("Founding Designer");
    expect(html).toContain(">メールする<");
    expect(html).not.toContain("founders@cmux.com にメールする");
    expect(html).toContain(
      `subject=${encodeURIComponent(jaMessages.jobs.applyEmailSubject)}`,
    );
    expect(html).not.toContain("What you'll do");
  });

  test("renders localized Simplified and Traditional Chinese presentations", () => {
    activeLocale = "zh-CN";
    const simplified = renderToStaticMarkup(<JobsPage />);
    expect(simplified).toContain("我们正在招聘");
    expect(simplified).toContain("开放职位");
    expect(simplified).toContain("Founding Designer");
    expect(simplified).toContain(">发送邮件<");
    expect(simplified).toContain(
      `href="mailto:founders@cmux.com?subject=${encodeURIComponent(
        messagesByLocale["zh-CN"].jobs.applyEmailSubject,
      )}"`,
    );

    activeLocale = "zh-TW";
    const traditional = renderToStaticMarkup(<JobsPage />);
    expect(traditional).toContain("我們正在招募");
    expect(traditional).toContain("開放職缺");
    expect(traditional).toContain("Founding Designer");
    expect(traditional).toContain(">寄送電子郵件<");
    expect(traditional).toContain(
      `href="mailto:founders@cmux.com?subject=${encodeURIComponent(
        messagesByLocale["zh-TW"].jobs.applyEmailSubject,
      )}"`,
    );
  });

  test("keeps jobs copy complete and localized for every configured locale", () => {
    const expectedKeys = Object.keys(enMessages.jobs).sort();
    for (const locale of locales) {
      const catalog = messagesByLocale[locale];
      expect(Object.keys(catalog.jobs).sort()).toEqual(expectedKeys);
      expect(catalog.nav.jobs).toBeTruthy();
      expect(catalog.footer.jobs).toBeTruthy();
      expect(catalog.jobs.whatYoullDoItems).toHaveLength(4);
      expect(catalog.jobs.foundingDesigner.whatYoullDoItems).toHaveLength(4);
      expect(catalog.jobs.whoWereLookingForItems).toHaveLength(6);
      expect(catalog.jobs.foundingDesigner.whoWereLookingForItems).toHaveLength(5);

      activeLocale = locale;
      const html = renderToStaticMarkup(<JobsPage />);
      expect(html).toContain(catalog.jobs.section);
      expect(html).toContain(catalog.jobs.title);
      expect(html).toContain(catalog.jobs.applyCta);
      expect(html).toContain(
        `mailto:founders@cmux.com?subject=${encodeURIComponent(
          catalog.jobs.applyEmailSubject,
        )}`,
      );
    }
  });

  test("publishes locale-aware metadata and alternates", async () => {
    activeLocale = "en";
    const english = await generateMetadata({
      params: Promise.resolve({ locale: "en" }),
    });
    expect(english.title).toEqual({
      absolute: "Founding Engineer jobs at cmux",
    });
    expect(english.alternates).toEqual(expectedAlternates("/jobs", "en"));
    expect(english.description).toContain("future of coding with AI");

    const japanese = await generateMetadata({
      params: Promise.resolve({ locale: "ja" }),
    });
    expect(japanese.title).toEqual({
      absolute: "Founding Engineer の採用情報 — cmux",
    });
    expect(japanese.alternates).toMatchObject({
      canonical: "https://cmux.com/ja/jobs",
    });
    expect(japanese.description).toContain("AI コーディングの未来");

    const chinese = await generateMetadata({
      params: Promise.resolve({ locale: "zh-CN" }),
    });
    expect(chinese.title).toEqual({ absolute: "cmux 创始工程师招聘" });
    expect(chinese.alternates).toMatchObject({
      canonical: "https://cmux.com/zh-CN/jobs",
      languages: {
        "zh-CN": "https://cmux.com/zh-CN/jobs",
        "zh-TW": "https://cmux.com/zh-TW/jobs",
      },
    });
    expect(chinese.description).toContain("AI 编程的未来");
  });

  test("renders the English founding designer role and links the roles together", () => {
    activeLocale = "en";
    const html = renderToStaticMarkup(<FoundingDesignerPage />);

    expect(html).toContain("About the role");
    expect(html).toContain("Founding Designer");
    expect(html).toContain(
      "Design frontier devtools across the stack: cmux macOS, cmux TUI, cmux Windows/Linux, cmux iOS, cmux Cloud, cmux.com, chatmux, and more.",
    );
    expect(html).toContain(
      "You are a walking encyclopedia of design components from all sorts of apps.",
    );
    expect(html).toContain("Typography, motion, and systems thinking");
    expect(html).toContain("$130k–$170k + 0.5%–1.5% equity");
    expect(html).toContain(">Email<");
    expect(html).not.toContain("Email founders@cmux.com");
    expect(html).toContain('href="/jobs"');
    expect(html).toContain("Founding Engineer");
    expect(html).toContain(
      `subject=${encodeURIComponent(
        enMessages.jobs.foundingDesigner.applyEmailSubject,
      )}`,
    );
  });

  test("renders the authored Japanese founding designer presentation", () => {
    activeLocale = "ja";
    const html = renderToStaticMarkup(<FoundingDesignerPage />);

    expect(html).toContain("役割について");
    expect(html).toContain("Founding Designer");
    expect(html).toContain("デザインコンポーネントを知り尽くしている");
    expect(html).toContain("タイポグラフィ、モーション、システム思考");
    expect(html).toContain(">メールする<");
    expect(html).not.toContain("founders@cmux.com にメールする");
    expect(html).toContain(
      `subject=${encodeURIComponent(
        jaMessages.jobs.foundingDesigner.applyEmailSubject,
      )}`,
    );
    expect(html).not.toContain("What you'll do");
  });

  test("publishes founding designer metadata for both authored locales", async () => {
    activeLocale = "en";
    const english = await generateDesignerMetadata({
      params: Promise.resolve({ locale: "en" }),
    });
    expect(english.title).toEqual({
      absolute: "Founding Designer jobs at cmux",
    });
    expect(english.alternates).toEqual(
      expectedAlternates("/jobs/founding-designer", "en"),
    );
    expect(english.description).toContain(
      "design the future of coding with AI",
    );

    activeLocale = "ja";
    const japanese = await generateDesignerMetadata({
      params: Promise.resolve({ locale: "ja" }),
    });
    expect(japanese.title).toEqual({
      absolute: "Founding Designer の採用情報 — cmux",
    });
    expect(japanese.alternates).toMatchObject({
      canonical: "https://cmux.com/ja/jobs/founding-designer",
    });
    expect(japanese.description).toContain("AI とコーディングの未来");
  });
});

describe("jobs route integration", () => {
  test("negotiates the unprefixed route without redirect loops", () => {
    const english = middleware(
      new NextRequest("https://cmux.com/jobs", {
        headers: { "accept-language": "en" },
      }),
    );
    expect(english.status).toBe(200);
    expect(english.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/jobs",
    );
    expect(english.headers.get("link")).toContain('hreflang="zh-CN"');

    const japanese = middleware(
      new NextRequest("https://cmux.com/jobs", {
        headers: { "accept-language": "ja,en;q=0.8" },
      }),
    );
    expect(japanese.status).toBe(307);
    expect(japanese.headers.get("location")).toBe("https://cmux.com/ja/jobs");

    const simplifiedChinese = middleware(
      new NextRequest("https://cmux.com/jobs", {
        headers: { "accept-language": "zh-CN,zh;q=0.8" },
      }),
    );
    expect(simplifiedChinese.status).toBe(307);
    expect(simplifiedChinese.headers.get("location")).toBe(
      "https://cmux.com/zh-CN/jobs",
    );

    const localized = middleware(
      new NextRequest("https://cmux.com/de/jobs", {
        headers: { "accept-language": "de" },
      }),
    );
    expect(localized.status).toBe(200);

    for (const locale of jobsContentLocales) {
      const localizedRoute = middleware(
        new NextRequest(`https://cmux.com/${locale}/jobs`, {
          headers: { "accept-language": locale },
        }),
      );
      expect(localizedRoute.status).toBe(locale === "en" ? 307 : 200);
      if (locale === "en") {
        expect(localizedRoute.headers.get("location")).toBe(
          "https://cmux.com/jobs",
        );
      }
    }
  });

  test("negotiates the unprefixed founding designer route", () => {
    const english = middleware(
      new NextRequest("https://cmux.com/jobs/founding-designer", {
        headers: { "accept-language": "en" },
      }),
    );
    expect(english.status).toBe(200);
    expect(english.headers.get("x-middleware-rewrite")).toBe(
      "https://cmux.com/en/jobs/founding-designer",
    );

    const japanese = middleware(
      new NextRequest("https://cmux.com/jobs/founding-designer", {
        headers: { "accept-language": "ja,en;q=0.8" },
      }),
    );
    expect(japanese.status).toBe(307);
    expect(japanese.headers.get("location")).toBe(
      "https://cmux.com/ja/jobs/founding-designer",
    );

    const localized = middleware(
      new NextRequest("https://cmux.com/de/jobs/founding-designer", {
        headers: { "accept-language": "de" },
      }),
    );
    expect(localized.status).toBe(200);

    for (const locale of jobsContentLocales) {
      const localizedRoute = middleware(
        new NextRequest(`https://cmux.com/${locale}/jobs/founding-designer`, {
          headers: { "accept-language": locale },
        }),
      );
      expect(localizedRoute.status).toBe(locale === "en" ? 307 : 200);
      if (locale === "en") {
        expect(localizedRoute.headers.get("location")).toBe(
          "https://cmux.com/jobs/founding-designer",
        );
      }
    }
  });

  test("includes jobs in discovery and agent-readable variants", () => {
    const jobsEntry = sitemap().find(
      (entry) => entry.url === "https://cmux.com/jobs",
    );
    expect(jobsEntry?.alternates?.languages).toEqual(
      expectedAlternates("/jobs", "en").languages,
    );
    expect(
      sitemap().filter((entry) =>
        String(entry.url).endsWith("/jobs"),
      ),
    ).toHaveLength(jobsContentLocales.length);
    const designerEntry = sitemap().find(
      (entry) => entry.url === "https://cmux.com/jobs/founding-designer",
    );
    expect(designerEntry?.alternates?.languages).toEqual(
      expectedAlternates("/jobs/founding-designer", "en").languages,
    );
    expect(resolveAgentPageVariant("/jobs.md")).toEqual({
      kind: "page",
      format: "md",
      requestedPath: "/jobs.md",
      canonicalPath: "/jobs",
    });
    expect(resolveAgentPageVariant("/ja/jobs.txt")).not.toBeNull();
    expect(resolveAgentPageVariant("/jobs/founding-designer.md")).toEqual({
      kind: "page",
      format: "md",
      requestedPath: "/jobs/founding-designer.md",
      canonicalPath: "/jobs/founding-designer",
    });
    expect(resolveAgentPageVariant("/ja/jobs/founding-designer.txt")).toEqual({
      kind: "page",
      format: "txt",
      requestedPath: "/ja/jobs/founding-designer.txt",
      canonicalPath: "/ja/jobs/founding-designer",
    });
    expect(resolveAgentPageVariant("/de/jobs.md")).not.toBeNull();
    expect(resolveAgentPageVariant("/zh-CN/jobs/founding-designer.md")).not.toBeNull();
    for (const locale of jobsContentLocales) {
      const prefix = locale === "en" ? "" : `/${locale}`;
      expect(resolveAgentPageVariant(`${prefix}/jobs.md`)).not.toBeNull();
      expect(
        resolveAgentPageVariant(`${prefix}/jobs/founding-designer.txt`),
      ).not.toBeNull();
    }
  });
});

function expectedAlternates(path: string, locale: Locale) {
  const languages = Object.fromEntries(
    jobsContentLocales.map((contentLocale) => [
      contentLocale,
      contentLocale === "en"
        ? `https://cmux.com${path}`
        : `https://cmux.com/${contentLocale}${path}`,
    ]),
  );
  languages["x-default"] = `https://cmux.com${path}`;
  return {
    canonical:
      locale === "en"
        ? `https://cmux.com${path}`
        : `https://cmux.com/${locale}${path}`,
    languages,
  };
}
