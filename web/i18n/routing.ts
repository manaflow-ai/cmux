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
] as const;

export type Locale = (typeof locales)[number];

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
};

export const routing = defineRouting({
  locales,
  defaultLocale: "en",
  localePrefix: "as-needed",
});
