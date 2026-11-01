import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { createTranslator } from "use-intl/core";
import { locales, type Locale } from "../i18n/routing";
import enMessages from "../messages/en.json";

type Messages = typeof enMessages;
const messagesByLocale = {} as Record<Locale, Messages>;
for (const locale of locales) {
  messagesByLocale[locale] = (await import(`../messages/${locale}.json`)).default as Messages;
}

let currentLocale: Locale = "en";

mock.module("next-intl", () => ({
  useTranslations: (namespace: string) =>
    createTranslator({
      locale: currentLocale,
      messages: messagesByLocale[currentLocale],
      namespace: namespace as never,
    }),
}));

// The header is a client component with its own navigation hooks; the page
// contract under test is the body (icon, copy, download link).
mock.module("../app/[locale]/components/site-header", () => ({
  SiteHeader: ({ section }: { section: string }) => <header>{section}</header>,
}));

const { default: NightlyPage } = await import("../app/[locale]/(landing)/nightly/page");
const { default: NextNightlyPage } = await import("../app/[locale]/(landing)/next/page");
const { sitemapEntries } = await import("../app/sitemap");

function render(page: () => React.ReactElement, locale: Locale): string {
  currentLocale = locale;
  return renderToStaticMarkup(page());
}

describe("nightly download pages", () => {
  test("/next downloads the latest cmux NEXT NIGHTLY arm64 DMG", () => {
    const html = render(NextNightlyPage, "en");
    expect(html).toContain(
      'href="https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos-arm64.dmg"',
    );
    expect(html).toContain('src="/logo-next-nightly.png"');
    expect(html).toContain("cmux NEXT NIGHTLY");
    expect(html).not.toContain("cmux-nightly-macos.dmg");
  });

  test("/nightly keeps downloading the classic cmux NIGHTLY DMG", () => {
    const html = render(NightlyPage, "en");
    expect(html).toContain(
      'href="https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg"',
    );
    expect(html).toContain('src="/logo-nightly.png"');
    expect(html).not.toContain("nightly-next");
  });

  test("/next renders translated copy in every locale", () => {
    for (const locale of locales) {
      const page = messagesByLocale[locale].next;
      expect(page).toBeDefined();
      const html = render(NextNightlyPage, locale);
      expect(html).toContain("cmux-nightly-next-macos-arm64.dmg");
      expect(html).toContain("https://github.com/manaflow-ai/cmux/issues");
      if (locale !== "en") {
        expect(page.description).not.toBe(enMessages.next.description);
        expect(page.download).not.toBe(enMessages.next.download);
      }
    }
  });

  test("/next is listed in the sitemap", () => {
    expect(sitemapEntries().some((entry) => entry.url.endsWith("/next"))).toBe(true);
  });
});
