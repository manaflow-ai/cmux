import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { linkedText } from "../app/[locale]/(legal)/privacy-policy/page";
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

  test("localizes same-origin absolute content links", () => {
    const markup = renderToStaticMarkup(
      <>
        {linkedText(
          "[Terms](https://cmux.com/terms-of-service) [Home](https://cmux.com) [External](https://example.com/terms)",
          "de",
        )}
      </>,
    );
    expect(markup).toContain('href="/de/terms-of-service"');
    expect(markup).toContain('href="/de"');
    expect(markup).toContain('href="https://example.com/terms"');
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
