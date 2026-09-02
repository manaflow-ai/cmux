import { describe, expect, mock, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";

import arabicMessages from "../messages/ar.json";
import bosnianMessages from "../messages/bs.json";
import danishMessages from "../messages/da.json";
import germanMessages from "../messages/de.json";
import englishMessages from "../messages/en.json";
import spanishMessages from "../messages/es.json";
import frenchMessages from "../messages/fr.json";
import italianMessages from "../messages/it.json";
import japaneseMessages from "../messages/ja.json";
import khmerMessages from "../messages/km.json";
import koreanMessages from "../messages/ko.json";
import norwegianMessages from "../messages/no.json";
import polishMessages from "../messages/pl.json";
import brazilianPortugueseMessages from "../messages/pt-BR.json";
import russianMessages from "../messages/ru.json";
import thaiMessages from "../messages/th.json";
import turkishMessages from "../messages/tr.json";
import ukrainianMessages from "../messages/uk.json";
import simplifiedChineseMessages from "../messages/zh-CN.json";
import traditionalChineseMessages from "../messages/zh-TW.json";
import { locales } from "../i18n/routing";

let acceptLanguage = "en";

mock.module("next/headers", () => ({
  headers: async () => new Headers({ "accept-language": acceptLanguage }),
}));

const { default: AuthErrorPage, generateMetadata } = await import(
  "../app/handler/auth-error/page"
);

const messagesByLocale = {
  en: englishMessages,
  ja: japaneseMessages,
  "zh-CN": simplifiedChineseMessages,
  "zh-TW": traditionalChineseMessages,
  ko: koreanMessages,
  de: germanMessages,
  es: spanishMessages,
  fr: frenchMessages,
  it: italianMessages,
  da: danishMessages,
  pl: polishMessages,
  ru: russianMessages,
  bs: bosnianMessages,
  ar: arabicMessages,
  no: norwegianMessages,
  "pt-BR": brazilianPortugueseMessages,
  th: thaiMessages,
  tr: turkishMessages,
  km: khmerMessages,
  uk: ukrainianMessages,
} as const;

type AuthErrorMessages = {
  emailUnverifiedTitle: string;
  emailUnverifiedBody: string;
  genericTitle: string;
  genericBody: string;
  backToSignIn: string;
};

describe("localized browser auth error page", () => {
  test("renders safe unverified-email guidance without upstream details", async () => {
    acceptLanguage = "en-US,en;q=0.9";
    const element = await AuthErrorPage({
      searchParams: Promise.resolve({ code: "email-conflict" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('data-auth-error="emailUnverified"');
    expect(html).toContain("Verify your email to continue");
    expect(html).toContain('href="/handler/sign-in"');
    expect(html).not.toContain("USER_EMAIL_ALREADY_EXISTS");
    expect(html).not.toContain("buyer@example.com");
  });

  test("uses the selected locale and a generic state for unknown codes", async () => {
    acceptLanguage = "ja-JP,ja;q=0.9,en;q=0.8";
    const element = await AuthErrorPage({
      searchParams: Promise.resolve({ code: "unexpected" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('data-auth-error="generic"');
    expect(html).toContain('lang="ja"');
    expect(html).toContain("サインインを完了できませんでした");
    expect(html).not.toContain("unexpected");
  });

  test("sets right-to-left direction for Arabic recovery copy", async () => {
    acceptLanguage = "ar-SA,ar;q=0.9,en;q=0.8";
    const element = await AuthErrorPage({
      searchParams: Promise.resolve({ code: "email-conflict" }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain('lang="ar"');
    expect(html).toContain('dir="rtl"');
  });

  test("preserves a native handoff target on the way back to sign-in", async () => {
    acceptLanguage = "en";
    const element = await AuthErrorPage({
      searchParams: Promise.resolve({
        code: "email-conflict",
        after_auth_return_to: "/handler/after-sign-in?nonce=opaque",
        ignored: "not-forwarded",
      }),
    });
    const html = renderToStaticMarkup(element);

    expect(html).toContain(
      'href="/handler/sign-in?after_auth_return_to=%2Fhandler%2Fafter-sign-in%3Fnonce%3Dopaque"',
    );
    expect(html).not.toContain("not-forwarded");
  });

  test("marks the localized recovery page as non-indexable", async () => {
    acceptLanguage = "en";
    await expect(
      generateMetadata({
        searchParams: Promise.resolve({ code: "email-conflict" }),
      }),
    ).resolves.toMatchObject({
      title: "Verify your email to continue",
      robots: { index: false, follow: false },
    });
  });

  test("ships complete auth-error copy for every routed locale", () => {
    expect(Object.keys(messagesByLocale).sort()).toEqual([...locales].sort());
    const english = messagesByLocale.en.authError as AuthErrorMessages;
    for (const locale of locales) {
      const messages = messagesByLocale[locale].authError as AuthErrorMessages;
      for (const key of Object.keys(english) as (keyof AuthErrorMessages)[]) {
        expect(typeof messages[key]).toBe("string");
        expect(messages[key].trim().length).toBeGreaterThan(0);
      }
      if (locale !== "en") {
        expect(messages.emailUnverifiedTitle).not.toBe(
          english.emailUnverifiedTitle,
        );
      }
    }
  });
});
