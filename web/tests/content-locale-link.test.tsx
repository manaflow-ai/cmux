import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ContentLocaleLink } from "../app/[locale]/components/content-locale-link";
import { fallbackContentLocales } from "../i18n/locale-availability";
import type { Locale } from "../i18n/routing";

describe("fallback-content links", () => {
  test("keeps links in the current translated locale", () => {
    for (const href of [
      "/pricing",
      "/docs/agent-integrations/oh-my-pi",
    ]) {
      const markup = renderLink("de", href);
      expect(markup).toContain(`href="/de${href}"`);
    }
  });

  test("renders the localized Japanese href when translated content exists", () => {
    expect(renderLink("ja", "/pricing")).toContain('href="/ja/pricing"');
  });

  test("falls back to the first authored locale", () => {
    expect(renderLink("de", "/pricing", ["en", "ja"])).toContain(
      'href="/pricing"',
    );
  });
});

function renderLink(
  locale: string,
  href: string,
  contentLocales: readonly Locale[] = fallbackContentLocales,
) {
  return renderToStaticMarkup(
    <ContentLocaleLink
      href={href}
      currentLocale={locale}
      contentLocales={contentLocales}
    >
      Link
    </ContentLocaleLink>,
  );
}
