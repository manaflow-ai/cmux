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

const supportEmail = "founders@manaflow.com";

// Long-form sentences that any genuine translation must render differently
// from the English catalog. Short labels ("Discord", "Support") may
// legitimately match English and are excluded.
const mustDifferFromEnglishPaths = [
  ["metaDescription"],
  ["title"],
  ["body"],
  ["form", "message"],
  ["form", "privacy"],
  ["form", "success"],
  ["form", "error"],
] as const;

type Json = string | number | boolean | null | Json[] | { [key: string]: Json };

function shape(value: Json): Json {
  if (Array.isArray(value)) return value.map(shape);
  if (typeof value === "object" && value !== null) {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, shape(value[key])]),
    );
  }
  return typeof value;
}

function leafStrings(value: Json): string[] {
  if (Array.isArray(value)) return value.flatMap(leafStrings);
  if (typeof value === "object" && value !== null) {
    return Object.values(value).flatMap(leafStrings);
  }
  return typeof value === "string" ? [value] : [];
}

function at(value: Json, path: readonly string[]): string {
  let current: Json = value;
  for (const key of path) {
    current = (current as { [key: string]: Json })[key];
  }
  return current as string;
}

describe("support page localization", () => {
  test("covers every routed locale", () => {
    expect(Object.keys(messagesByLocale).sort()).toEqual([...locales].sort());
  });

  for (const [locale, messages] of Object.entries(messagesByLocale)) {
    const support = (messages as { support: Json }).support;
    const footer = (messages as { footer: { support?: string } }).footer;

    test(`${locale} ships its own support catalog instead of English fallback`, () => {
      // Same key tree and array lengths as English, so no key silently
      // falls back through deepMergeMessages.
      expect(shape(support)).toEqual(
        shape((englishMessages as { support: Json }).support),
      );
      expect(
        leafStrings(support).every((value) => value.trim().length > 0),
      ).toBe(true);

      if (locale !== "en") {
        for (const path of mustDifferFromEnglishPaths) {
          expect(at(support, path)).not.toBe(
            at((englishMessages as { support: Json }).support, path),
          );
        }
      }
    });

    test(`${locale} keeps the support email address intact`, () => {
      const channels = support as {
        channels: { email: { label: string } };
        form: { success: string; error: string };
      };
      expect(channels.channels.email.label).toBe(supportEmail);
      expect(channels.form.success).toContain(supportEmail);
      expect(channels.form.error).toContain(supportEmail);
    });

    test(`${locale} links the support page from the footer`, () => {
      expect(typeof footer.support).toBe("string");
      expect(footer.support?.trim().length).toBeGreaterThan(0);
    });
  }

  test("zh-TW is not a copy of the zh-CN catalog", () => {
    const simplified = leafStrings(
      (simplifiedChineseMessages as { support: Json }).support,
    ).join("\n");
    const traditional = leafStrings(
      (traditionalChineseMessages as { support: Json }).support,
    ).join("\n");
    expect(traditional).not.toBe(simplified);
    // Simplified-only characters that must not leak into the Traditional catalog.
    for (const fragment of ["发送", "帐户", "报告", "订阅", "文档", "请"]) {
      expect(traditional).not.toContain(fragment);
    }
  });
});
