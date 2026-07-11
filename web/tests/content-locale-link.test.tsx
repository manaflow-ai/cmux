import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { ContentLocaleLink } from "../app/[locale]/components/content-locale-link";
import { fallbackContentLocales } from "../i18n/locale-availability";

describe("fallback-content links", () => {
  test("renders direct canonical hrefs for English fallback content", () => {
    for (const href of [
      "/pricing",
      "/docs/agent-integrations/oh-my-pi",
    ]) {
      const markup = renderLink("de", href);
      expect(markup).toContain(`href="${href}"`);
      expect(markup).not.toContain("/en/");
      expect(markup).not.toContain("/de/");
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
