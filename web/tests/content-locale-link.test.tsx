import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ContentLocaleLink } from "../app/[locale]/components/content-locale-link";
import { fallbackContentLocales } from "../i18n/locale-availability";

describe("fallback-content links", () => {
  test("renders localized hrefs for translated fallback content", () => {
    for (const href of [
      "/pricing",
      "/docs/agent-integrations/oh-my-pi",
    ]) {
      const markup = renderLink("de", href);
      expect(markup).toContain(`href="/de${href}"`);
      expect(markup).not.toContain("/en/");
    }
  });

  test("renders the localized Japanese href when translated content exists", () => {
    expect(renderLink("ja", "/pricing")).toContain('href="/ja/pricing"');
  });
});

function renderLink(locale: string, href: string) {
  return renderToStaticMarkup(
    <ContentLocaleLink
      href={href}
      currentLocale={locale}
      contentLocales={fallbackContentLocales}
    >
      Link
    </ContentLocaleLink>,
  );
}
