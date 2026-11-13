import { defineRouting } from "next-intl/routing";

export const locales = [
  "en",
  "ja",
  "zh-CN",
  "zh-TW",
  "ko",
  "de",
  "es",
  "fr",
  "it",
  "da",
  "pl",
  "ru",
  "bs",
  "ar",
  "no",
  "pt-BR",
  "th",
  "tr",
  "km",
  "uk",
] as const;

export type Locale = (typeof locales)[number];

/** The text direction of a locale: right to left for Arabic, else left to right. */
export function localeDirection(locale: string): "ltr" | "rtl" {
  return locale === "ar" ? "rtl" : "ltr";
}

export const localeNames: Record<Locale, string> = {
  en: "English",
  ja: "日本語",
  "zh-CN": "简体中文",
  "zh-TW": "繁體中文",
  ko: "한국어",
  de: "Deutsch",
  es: "Español",
  fr: "Français",
  it: "Italiano",
  da: "Dansk",
  pl: "Polski",
  ru: "Русский",
  bs: "Bosanski",
  ar: "العربية",
  no: "Norsk",
  "pt-BR": "Português (Brasil)",
  th: "ไทย",
  tr: "Türkçe",
  km: "ភាសាខ្មែរ",
  uk: "Українська",
};

export const routing = defineRouting({
  locales,
  defaultLocale: "en",
  localePrefix: "as-needed",
  // Route-level metadata owns hreflang because some pages intentionally support
  // only a subset of locales. A global Link header advertises localized URLs
  // that return 404 for those pages.
  alternateLinks: false,
});
