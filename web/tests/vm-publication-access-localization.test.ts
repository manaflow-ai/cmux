import { describe, expect, test } from "bun:test";

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
import { publicationAccessLocale } from "../app/cloud/access/locale";

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

type AccessMessageKey = keyof typeof englishMessages.cloudPublicationAccess;

const englishAccess = englishMessages.cloudPublicationAccess;
const accessKeys = Object.keys(englishAccess).sort() as AccessMessageKey[];
const signInCopyKeys = ["title", "signIn", "switchAccount"] as const;

function placeholders(value: string): string[] {
  return [...value.matchAll(/\{[^{}]+\}/g)]
    .map(([placeholder]) => placeholder)
    .sort();
}

describe("cloud publication access localization", () => {
  test("covers every routed locale", () => {
    expect(Object.keys(messagesByLocale).sort()).toEqual([...locales].sort());
  });

  for (const [locale, messages] of Object.entries(messagesByLocale)) {
    test(`${locale} provides every non-empty access message with matching placeholders`, () => {
      const access = messages.cloudPublicationAccess;

      expect(Object.keys(access).sort()).toEqual(accessKeys);
      for (const key of accessKeys) {
        expect(access[key]).toBeString();
        expect(access[key].trim().length).toBeGreaterThan(0);
        expect(placeholders(access[key])).toEqual(placeholders(englishAccess[key]));
      }
    });

    if (locale !== "en") {
      test(`${locale} localizes the access title and sign-in copy`, () => {
        const access = messages.cloudPublicationAccess;

        for (const key of signInCopyKeys) {
          expect(access[key]).not.toBe(englishAccess[key]);
        }
      });
    }
  }
});

describe("Cloud VM publication access locale", () => {
  test("prefers the locale the proxy resolved over raw Accept-Language", () => {
    expect(publicationAccessLocale(new Headers({
      "x-next-intl-locale": "ja",
      "accept-language": "en-US,en;q=0.9",
    }))).toBe("ja");
    expect(publicationAccessLocale(new Headers({
      "x-next-intl-locale": "xx",
      "accept-language": "de-DE,de;q=0.9",
    }))).toBe("de");
    expect(publicationAccessLocale(new Headers({ "accept-language": "fr-FR" }))).toBe("fr");
  });
});
