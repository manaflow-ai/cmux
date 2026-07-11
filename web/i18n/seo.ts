import { locales } from "./routing";

const BASE = "https://cmux.com";
const DEFAULT_OG_IMAGE_PATH = "/opengraph-image";

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

const detailedDescriptionSuffixes: Record<string, string> = {
  en: "Built for AI coding agents on macOS, with vertical tabs, notifications, split panes, and browser automation.",
  ja: "macOS の AI コーディングエージェント向け。縦型タブ、通知、分割ペイン、ブラウザ自動化、セッション復元を備えています。",
  "zh-CN": "面向 macOS 上的 AI 编码代理，提供垂直标签页、通知、分屏窗格、浏览器自动化、多代理工作区、会话恢复和快捷命令。",
  "zh-TW": "面向 macOS 上的 AI 程式碼代理，提供垂直分頁、通知、分割窗格、瀏覽器自動化、多代理工作區、工作階段復原與快捷指令。",
  ko: "macOS의 AI 코딩 에이전트를 위해 수직 탭, 알림, 분할 패널, 브라우저 자동화와 세션 복원을 제공합니다.",
  de: "Für KI-Coding-Agenten auf macOS, mit vertikalen Tabs, Benachrichtigungen, geteilten Bereichen und Browser-Automatisierung.",
  es: "Creado para agentes de código con IA en macOS, con pestañas verticales, notificaciones, paneles divididos y automatización del navegador.",
  fr: "Conçu pour les agents de codage IA sur macOS, avec onglets verticaux, notifications, panneaux divisés et automatisation du navigateur.",
  it: "Creato per agenti di codifica IA su macOS, con schede verticali, notifiche, pannelli divisi e automazione del browser.",
  da: "Bygget til AI-kodeagenter på macOS med lodrette faner, notifikationer, opdelte ruder og browserautomatisering.",
  pl: "Stworzone dla agentów kodowania AI na macOS, z pionowymi kartami, powiadomieniami, dzielonymi panelami i automatyzacją przeglądarki.",
  ru: "Создано для AI-агентов программирования на macOS: вертикальные вкладки, уведомления, разделённые панели и автоматизация браузера.",
  bs: "Napravljeno za AI agente za kodiranje na macOS-u, s vertikalnim tabovima, obavijestima, podijeljenim panelima i automatizacijom preglednika.",
  ar: "مصمم لوكلاء البرمجة بالذكاء الاصطناعي على macOS، مع علامات تبويب عمودية وإشعارات وأجزاء مقسمة وأتمتة للمتصفح.",
  no: "Laget for AI-kodeagenter på macOS med vertikale faner, varsler, delte paneler og nettleserautomatisering.",
  "pt-BR": "Criado para agentes de código com IA no macOS, com abas verticais, notificações, painéis divididos e automação do navegador.",
  th: "สร้างมาสำหรับเอเจนต์เขียนโค้ด AI บน macOS พร้อมแท็บแนวตั้ง การแจ้งเตือน แผงแยก และระบบเบราว์เซอร์อัตโนมัติ",
  tr: "macOS'taki AI kodlama ajanları için dikey sekmeler, bildirimler, bölünmüş paneller ve tarayıcı otomasyonuyla tasarlandı.",
  km: "បង្កើតសម្រាប់ភ្នាក់ងារ AI សរសេរកូដលើ macOS ជាមួយផ្ទាំងបញ្ឈរ ការជូនដំណឹង ផ្ទាំងបំបែក និងស្វ័យប្រវត្តិកម្មកម្មវិធីរុករក។",
  uk: "Створено для AI-агентів програмування на macOS: вертикальні вкладки, сповіщення, розділені панелі й автоматизація браузера.",
};

const DEFAULT_MIN_DESCRIPTION_LENGTH = 90;
const AUDIT_MIN_DESCRIPTION_LENGTH = 110;
const MAX_DESCRIPTION_LENGTH = 160;
const MIN_TITLE_LENGTH = 30;
const MAX_TITLE_LENGTH = 60;
const metadataSegmenter = new Intl.Segmenter("en", {
  granularity: "grapheme",
});
const wideMetadataGrapheme =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}\p{Script=Thai}\p{Script=Khmer}\p{Extended_Pictographic}]/u;

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

const OPEN_GRAPH_IMAGE_RENDER_SCALE = 2;
const OPEN_GRAPH_IMAGE_WIDTH = 1200 * OPEN_GRAPH_IMAGE_RENDER_SCALE;
const OPEN_GRAPH_IMAGE_HEIGHT = 630 * OPEN_GRAPH_IMAGE_RENDER_SCALE;

export function openGraphImageAlt(locale: string) {
  return openGraphImageAlts[locale] ?? openGraphImageAlts.en;
}

export function openGraphImageTagline(locale: string) {
  return openGraphImageTaglines[locale] ?? openGraphImageTaglines.en;
}

export function openGraphImage(locale: string) {
  return {
    url: canonicalUrl(locale, DEFAULT_OG_IMAGE_PATH),
    width: OPEN_GRAPH_IMAGE_WIDTH,
    height: OPEN_GRAPH_IMAGE_HEIGHT,
    alt: openGraphImageAlt(locale),
  };
}

export const defaultOpenGraphImage = openGraphImage("en");

export function hasLocalizedSeoCopy(locale: string) {
  return (
    Object.hasOwn(shortDescriptionSuffixes, locale) &&
    Object.hasOwn(detailedDescriptionSuffixes, locale) &&
    Object.hasOwn(openGraphImageAlts, locale) &&
    Object.hasOwn(openGraphImageTaglines, locale)
  );
}

export function seoDescription(
  locale: string,
  description: string,
  options: { minLength?: number } = {},
) {
  const minLength = options.minLength ?? DEFAULT_MIN_DESCRIPTION_LENGTH;
  const trimmed = description.trim();
  if (metadataSearchLength(trimmed) >= minLength) {
    return truncateMetadataText(trimmed, MAX_DESCRIPTION_LENGTH, minLength);
  }

  const suffixes =
    minLength >= AUDIT_MIN_DESCRIPTION_LENGTH
      ? detailedDescriptionSuffixes
      : shortDescriptionSuffixes;
  const suffix = suffixes[locale] ?? suffixes.en;
  if (trimmed.includes(suffix)) {
    return truncateMetadataText(trimmed, MAX_DESCRIPTION_LENGTH, minLength);
  }

  const separator =
    /[。！？.!?]$/.test(trimmed) || trimmed.endsWith("؟") ? " " : ". ";
  return truncateMetadataText(
    `${trimmed}${separator}${suffix}`,
    MAX_DESCRIPTION_LENGTH,
    minLength,
  );
}

export function seoTitle(
  locale: string,
  title: string,
  options: { minLength?: number; maxLength?: number } = {},
) {
  const minLength = options.minLength ?? MIN_TITLE_LENGTH;
  const maxLength = options.maxLength ?? MAX_TITLE_LENGTH;
  let normalized = title.trim();

  if (metadataSearchLength(normalized) < minLength) {
    const context = openGraphImageTagline(locale);
    if (!normalized.includes(context)) {
      normalized = `${normalized} — ${context}`;
    }
  }

  return truncateMetadataText(normalized, maxLength);
}

function truncateMetadataText(
  value: string,
  maxLength: number,
  minLength = 0,
) {
  const characters = metadataCharacters(value);
  if (metadataSearchLength(value) <= maxLength) return value;

  const candidate: string[] = [];
  const candidateWidths: number[] = [];
  let candidateWidth = 0;
  for (const character of characters) {
    const characterWidth = metadataGraphemeWidth(character);
    if (candidateWidth + characterWidth > maxLength - 1) break;
    candidate.push(character);
    candidateWidth += characterWidth;
    candidateWidths.push(candidateWidth);
  }
  while (/\s/u.test(candidate.at(-1) ?? "")) candidate.pop();

  const minimumBoundaryWidth = Math.max(
    minLength,
    Math.floor(maxLength * 0.6),
  );
  const sentenceTerminators = new Set([".", "!", "?", "。", "！", "？"]);
  const sentenceBoundary = candidate.findLastIndex(
    (character, index) =>
      candidateWidths[index] >= minimumBoundaryWidth &&
      sentenceTerminators.has(character),
  );
  const wordBoundary = candidate.findLastIndex(
    (character, index) =>
      candidateWidths[index] >= minimumBoundaryWidth && character === " ",
  );
  const boundary =
    sentenceBoundary >= 0
      ? sentenceBoundary + 1
      : wordBoundary >= 0
        ? wordBoundary
        : candidate.length;
  let truncated = candidate
    .slice(0, boundary)
    .join("")
    .replace(/[-,:;–—]+$/u, "")
    .trimEnd();
  if (metadataSearchLength(truncated) + 1 < minLength) {
    truncated = candidate.join("").trimEnd();
  }
  return `${truncated}…`;
}

function metadataCharacters(value: string) {
  return Array.from(metadataSegmenter.segment(value), ({ segment }) => segment);
}

function metadataSearchLength(value: string) {
  return metadataCharacters(value).reduce(
    (length, grapheme) => length + metadataGraphemeWidth(grapheme),
    0,
  );
}

function metadataGraphemeWidth(grapheme: string) {
  return wideMetadataGrapheme.test(grapheme) ? 2 : 1;
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

export function twitterSummary(
  locale: string,
  title: string,
  description: string,
) {
  return {
    card: "summary_large_image" as const,
    title,
    description,
    images: [canonicalUrl(locale, DEFAULT_OG_IMAGE_PATH)],
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
