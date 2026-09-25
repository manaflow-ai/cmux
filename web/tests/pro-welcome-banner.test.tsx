import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

mock.module("next/navigation", () => ({
  useSearchParams: () => new URLSearchParams("welcome=success"),
}));

mock.module("next-intl", () => ({
  useLocale: () => "en",
  useTranslations: () => (key: string) => key,
}));

mock.module("../app/[locale]/components/content-locale-link", () => ({
  ContentLocaleLink: () => null,
}));

const { ProWelcomeBanner } = await import(
  "../app/[locale]/components/pro-welcome-banner"
);

describe("ProWelcomeBanner", () => {
  test("reads native URLSearchParams without losing its receiver", () => {
    const html = renderToStaticMarkup(<ProWelcomeBanner />);

    expect(html).toContain('role="status"');
    expect(html).toContain("welcomeSuccess");
  });
});
