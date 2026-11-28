import { describe, expect, mock, test } from "bun:test";
import { NextRequest } from "next/server";
import { renderToStaticMarkup } from "react-dom/server";
import { createTranslator } from "use-intl/core";
import { locales, type Locale } from "../i18n/routing";
import enMessages from "../messages/en.json";
import middleware from "../proxy";

type Messages = typeof enMessages;
const messagesByLocale = {} as Record<Locale, Messages>;
for (const locale of locales) {
  messagesByLocale[locale] = (await import(`../messages/${locale}.json`)).default as Messages;
}

let currentLocale: Locale = "en";

mock.module("next-intl/server", () => ({
  getTranslations: async (namespace: string) =>
    createTranslator({
      locale: currentLocale,
      messages: messagesByLocale[currentLocale],
      namespace: namespace as never,
    }),
}));

const { default: EmailSignInCallbackPage, generateMetadata } = await import(
  "../app/auth/callback/page"
);

// The iOS and macOS apps put https://cmux.com/auth/callback in the email
// sign-in message as the link target. Before this page existed the locale
// rewrite turned it into /en/auth/callback, a 404, so a user who tapped the
// link instead of typing the code landed on "Page not found".
describe("email sign-in link target", () => {
  test.each(["/auth/callback", "/auth/callback/"])(
    "proxy serves %s without a locale rewrite",
    (path) => {
      const response = middleware(
        new NextRequest(`https://cmux.com${path}?code=abc123nonce`, {
          headers: { host: "cmux.com", "accept-language": "ja" },
        }),
      );

      expect(response.headers.get("location")).toBeNull();
      expect(response.headers.get("x-middleware-rewrite")).toBeNull();
      expect(response.headers.get("x-middleware-next")).toBe("1");
      expect(response.headers.get("x-middleware-request-x-next-intl-locale")).toBe("ja");
    },
  );

  test("tells the user to type the code in the app and never echoes the link code", async () => {
    currentLocale = "en";
    const html = renderToStaticMarkup(await EmailSignInCallbackPage());

    expect(html).toContain("data-email-sign-in-callback");
    expect(html).toContain("Enter the code in the cmux app");
    expect(html).toContain("6-character code");
    expect(html).toContain('href="/handler/sign-in"');
    expect(html).not.toContain("abc123nonce");
  });

  test("keeps the page out of search and strips the code from referrers", async () => {
    currentLocale = "en";
    const metadata = await generateMetadata();

    expect(metadata.robots).toEqual({ index: false, follow: false });
    expect(metadata.referrer).toBe("no-referrer");
  });

  test.each(locales)("renders localized copy in %s", async (locale) => {
    currentLocale = locale;
    const html = renderToStaticMarkup(await EmailSignInCallbackPage());
    const copy = messagesByLocale[locale].emailSignInCallback;

    expect(copy.title.length).toBeGreaterThan(0);
    expect(html).toContain(copy.title);
  });
});
