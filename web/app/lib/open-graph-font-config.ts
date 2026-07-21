import type { Locale } from "@/i18n/routing";

export const openGraphTaglineFallbackFont = "geist-regular.ttf";

export const openGraphLocaleFonts: Partial<
  Record<Locale, { name: string; filename: string }>
> = {
  ja: {
    name: "Noto Sans CJK JP",
    filename: "noto-cjk-jp.otf",
  },
  "zh-CN": {
    name: "Noto Sans CJK SC",
    filename: "noto-cjk-sc.otf",
  },
  "zh-TW": {
    name: "Noto Sans CJK TC",
    filename: "noto-cjk-tc.otf",
  },
  ko: {
    name: "Noto Sans CJK KR",
    filename: "noto-cjk-kr.otf",
  },
  ar: {
    name: "Tajawal",
    filename: "tajawal.ttf",
  },
  th: {
    name: "Noto Sans Thai",
    filename: "noto-thai.ttf",
  },
  km: {
    name: "Noto Sans Khmer",
    filename: "noto-khmer.ttf",
  },
  ru: {
    name: "Noto Sans",
    filename: "noto-sans-cyrillic.ttf",
  },
  uk: {
    name: "Noto Sans",
    filename: "noto-sans-cyrillic.ttf",
  },
};
