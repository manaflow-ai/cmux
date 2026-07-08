import { locales } from "./routing";

const BASE = "https://cmux.com";
const DEFAULT_OG_IMAGE = `${BASE}/opengraph-image`;

const shortDescriptionSuffixes: Record<string, string> = {
  en: "Built for AI coding agents on macOS.",
  ja: "macOS の AI コーディングエージェント向けです。",
  "zh-CN": "面向 macOS 上的 AI 编码代理。",
  "zh-TW": "面向 macOS 上的 AI 程式碼代理。",
  ko: "macOS의 AI 코딩 에이전트를 위해 설계되었습니다.",
  de: "Für KI-Coding-Agenten auf macOS entwickelt.",
  es: "Creado para agentes de codificación con IA en macOS.",
  fr: "Conçu pour les agents de codage IA sur macOS.",
  it: "Creato per agenti di codifica IA su macOS.",
  da: "Bygget til AI-kodeagenter på macOS.",
  pl: "Stworzone dla agentów kodowania AI na macOS.",
  ru: "Создано для AI-агентов программирования на macOS.",
  bs: "Napravljeno za AI agente za kodiranje na macOS-u.",
  ar: "مصمم لوكلاء البرمجة بالذكاء الاصطناعي على macOS.",
  no: "Laget for AI-kodeagenter på macOS.",
  "pt-BR": "Criado para agentes de código com IA no macOS.",
  th: "สร้างมาเพื่อเอเจนต์เขียนโค้ด AI บน macOS.",
  tr: "macOS'taki AI kodlama ajanları için tasarlandı.",
  km: "បង្កើតសម្រាប់ភ្នាក់ងារ AI សរសេរកូដលើ macOS។",
  uk: "Створено для AI-агентів програмування на macOS.",
};

const openGraphImageAlts: Record<string, string> = {
  en: "cmux - The terminal built for multitasking",
  ja: "cmux - マルチタスクのために作られたターミナル",
  "zh-CN": "cmux - 为多任务处理而生的终端",
  "zh-TW": "cmux - 為多工處理而生的終端",
  ko: "cmux - 멀티태스킹을 위해 설계된 터미널",
  de: "cmux - Das Terminal für Multitasking",
  es: "cmux - La terminal creada para la multitarea",
  fr: "cmux - Le terminal conçu pour le multitâche",
  it: "cmux - Il terminale creato per il multitasking",
  da: "cmux - Terminalen bygget til multitasking",
  pl: "cmux - Terminal stworzony do wielozadaniowości",
  ru: "cmux - Терминал для многозадачности",
  bs: "cmux - Terminal napravljen za multitasking",
  ar: "cmux - الطرفية المصممة لتعدد المهام",
  no: "cmux - Terminalen laget for multitasking",
  "pt-BR": "cmux - O terminal criado para multitarefa",
  th: "cmux - เทอร์มินัลที่สร้างมาเพื่อการทำงานหลายอย่าง",
  tr: "cmux - Çoklu görev için tasarlanmış terminal",
  km: "cmux - Terminal ដែលបង្កើតសម្រាប់ការងារច្រើន",
  uk: "cmux - Термінал для багатозадачності",
};

const openGraphImageTaglines: Record<string, string> = {
  en: "The terminal built for multitasking",
  ja: "マルチタスクのために作られたターミナル",
  "zh-CN": "为多任务处理而生的终端",
  "zh-TW": "為多工處理而生的終端",
  ko: "멀티태스킹을 위해 설계된 터미널",
  de: "Das Terminal für Multitasking",
  es: "La terminal creada para la multitarea",
  fr: "Le terminal conçu pour le multitâche",
  it: "Il terminale creato per il multitasking",
  da: "Terminalen bygget til multitasking",
  pl: "Terminal stworzony do wielozadaniowości",
  ru: "Терминал для многозадачности",
  bs: "Terminal napravljen za multitasking",
  ar: "الطرفية المصممة لتعدد المهام",
  no: "Terminalen laget for multitasking",
  "pt-BR": "O terminal criado para multitarefa",
  th: "เทอร์มินัลที่สร้างมาเพื่อการทำงานหลายอย่าง",
  tr: "Çoklu görev için tasarlanmış terminal",
  km: "Terminal ដែលបង្កើតសម្រាប់ការងារច្រើន",
  uk: "Термінал для багатозадачності",
};

export function openGraphImageAlt(locale: string) {
  return openGraphImageAlts[locale] ?? openGraphImageAlts.en;
}

export function openGraphImageTagline(locale: string) {
  return openGraphImageTaglines[locale] ?? openGraphImageTaglines.en;
}

export function openGraphImage(locale: string) {
  return {
    url: DEFAULT_OG_IMAGE,
    width: 1200,
    height: 630,
    alt: openGraphImageAlt(locale),
  };
}

export const defaultOpenGraphImage = openGraphImage("en");

export function hasLocalizedSeoCopy(locale: string) {
  return (
    Object.hasOwn(shortDescriptionSuffixes, locale) &&
    Object.hasOwn(openGraphImageAlts, locale) &&
    Object.hasOwn(openGraphImageTaglines, locale)
  );
}

export const defaultOpenGraphImageUrl = DEFAULT_OG_IMAGE;

export function seoDescription(locale: string, description: string) {
  const trimmed = description.trim();
  if (trimmed.length >= 90) return trimmed;

  const suffix =
    shortDescriptionSuffixes[locale] ?? shortDescriptionSuffixes.en;
  if (trimmed.includes(suffix)) return trimmed;

  const separator =
    /[。！？.!?]$/.test(trimmed) || trimmed.endsWith("؟") ? " " : ". ";
  return `${trimmed}${separator}${suffix}`;
}

export function openGraphDefaults(
  locale: string,
  type: "website" | "article" = "website",
) {
  return {
    siteName: "cmux",
    type,
    images: [openGraphImage(locale)],
  };
}

export function twitterSummary(title: string, description: string) {
  return {
    card: "summary_large_image" as const,
    title,
    description,
    images: [DEFAULT_OG_IMAGE],
  };
}

export function canonicalUrl(locale: string, path: string) {
  return locale === "en" ? `${BASE}${path}` : `${BASE}/${locale}${path}`;
}

/**
 * Build the full alternates object (canonical + hreflang languages)
 * for a given locale and path. Use in every generateMetadata that
 * sets alternates so child metadata doesn't wipe parent hreflang.
 */
export function buildAlternates(
  locale: string,
  path: string,
  availableLocales: readonly string[] = locales,
) {
  const languages: Record<string, string> = {};
  for (const loc of availableLocales) {
    languages[loc] =
      loc === "en" ? `${BASE}${path}` : `${BASE}/${loc}${path}`;
  }
  languages["x-default"] = `${BASE}${path}`;

  const canonical = canonicalUrl(locale, path);

  return { canonical, languages };
}

export function buildAlternateLinkHeader(
  origin: string,
  path: string,
  availableLocales: readonly string[] = locales,
) {
  const entries = availableLocales.map((locale) => {
    const url = localizedUrl(origin, locale, path);
    return `<${url}>; rel="alternate"; hreflang="${locale}"`;
  });
  entries.push(
    `<${localizedUrl(origin, "en", path)}>; rel="alternate"; hreflang="x-default"`,
  );
  return entries.join(", ");
}

function localizedUrl(origin: string, locale: string, path: string) {
  const pathname = locale === "en" ? path : `/${locale}${path}`;
  return new URL(pathname, origin).toString();
}
