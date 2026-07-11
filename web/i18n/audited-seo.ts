import {
  openGraphImageAlt,
  openGraphImageTagline,
  detailedSeoDescriptionCandidate,
  seoDescription,
  seoTitle,
  shortSeoDescriptionCandidate,
} from "./seo";

export type SeoMessageLookup = (key: string) => string;

const conciseTitleLocales = new Set(["ja", "zh-CN", "zh-TW", "ko"]);

const shortTitleContexts: Record<string, string> = {
  en: "AI coding on macOS",
  ja: "macOS の AI コーディング",
  "zh-CN": "macOS AI 编码",
  "zh-TW": "macOS AI 編碼",
  ko: "macOS AI 코딩",
  de: "KI-Coding auf macOS",
  es: "Código IA en macOS",
  fr: "Codage IA sur macOS",
  it: "Codifica IA su macOS",
  da: "AI-kodning på macOS",
  pl: "Kodowanie AI na macOS",
  ru: "AI-кодинг на macOS",
  bs: "AI kodiranje na macOS-u",
  ar: "برمجة الذكاء الاصطناعي على macOS",
  no: "AI-koding på macOS",
  "pt-BR": "Código com IA no macOS",
  th: "AI coding บน macOS",
  tr: "macOS'ta AI kodlama",
  km: "AI coding លើ macOS",
  uk: "AI-кодування на macOS",
};

const compareIdentityTitles: Partial<Record<string, string>> = {
  multipleClaudeAgents: "cmux · Claude Code",
};

function selectTitle(
  locale: string,
  original: string,
  siteMeta: SeoMessageLookup,
  authoredCandidates: readonly string[],
) {
  const tagline = openGraphImageTagline(locale);
  const shortContext = shortTitleContexts[locale] ?? shortTitleContexts.en;
  const contextualCandidates = authoredCandidates.flatMap((candidate) => [
    candidate,
    `${candidate} — cmux`,
    `${candidate} — ${shortContext}`,
    `${candidate} — ${tagline}`,
    `${candidate} — ${siteMeta("title")}`,
  ]);
  return seoTitle(locale, original, {
    minLength: conciseTitleLocales.has(locale) ? 0 : undefined,
    fallbackCandidates: [
      ...contextualCandidates,
    ],
  });
}

function selectDescription(
  locale: string,
  original: string,
  authoredCandidates: readonly string[] = [],
) {
  const short = shortSeoDescriptionCandidate(locale);
  const detailed = detailedSeoDescriptionCandidate(locale);
  const contextualCandidates = authoredCandidates.flatMap((candidate) => [
    candidate,
    `${candidate}. ${short}`,
    `${candidate}. ${detailed}`,
  ]);
  return seoDescription(locale, original, {
    minLength: 110,
    fallbackCandidates: contextualCandidates,
  });
}

export function homeSeoCopy(locale: string, meta: SeoMessageLookup) {
  const title = selectTitle(locale, meta("title"), meta, [
    openGraphImageAlt(locale),
    openGraphImageTagline(locale),
  ]);
  const description = selectDescription(locale, meta("description"), [
    "cmux",
    meta("ogDescription"),
    openGraphImageAlt(locale),
  ]);
  return { title, description };
}

export function assetsSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      `${t("title")}. ${t("metaDescription")}`,
      t("description"),
    ]),
  };
}

export function blogIndexSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      `${t("title")}. ${t("metaDescription")}`,
    ]),
  };
}

export function communitySeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [
      t("title"),
      t("section"),
    ]),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      `${t("title")}. ${t("metaDescription")}`,
      t("description"),
    ]),
  };
}

export function bestTerminalSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      t("cmuxBuiltFor"),
      `${t("title")}. ${t("cmuxBuiltFor")}`,
    ]),
  };
}

export function cmuxHistorySeoCopy(
  locale: string,
  metadata: SeoMessageLookup,
  post: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  const metaTitle = metadata("metaTitle");
  return {
    title: selectTitle(locale, metaTitle, siteMeta, [
      post("title"),
      post("reopenTitle"),
      post("agentTitle"),
      post("focusTitle"),
    ]),
    description: selectDescription(locale, metadata("metaDescription"), [
      post("summary"),
      post("p1"),
      post("agentP2"),
      post("focusP"),
      post("fullHistoryP"),
      post("docsCta"),
      `${metaTitle} — ${post("agentTitle")}`,
    ]),
  };
}

export function compareIndexSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      `${t("title")}. ${openGraphImageAlt(locale)}`,
      t("intro"),
    ]),
  };
}

export function comparePageSeoCopy(
  locale: string,
  pageKey: string,
  t: SeoMessageLookup,
  landingLinks: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  const titleCandidates = [t("title")];
  if (pageKey === "bestTerminalForAgents") {
    titleCandidates.push(landingLinks("bestTerminal"));
  } else {
    const identityTitle = compareIdentityTitles[pageKey];
    if (identityTitle) titleCandidates.push(identityTitle);
    titleCandidates.push(t("faqQ1"), t("faqQ2"), t("faqQ3"));
  }
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, titleCandidates),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      t("summaryBody"),
      t("intro"),
      t("faqA1"),
      t("faqA2"),
      t("faqA3"),
      `${t("title")}. ${t("faqQ1")}`,
      `${t("title")}. ${t("faqQ2")}`,
      `${t("faqQ1")} ${t("faqQ2")}`,
      `${t("title")}. ${t("faqA1")}`,
      `${t("faqQ1")} ${t("faqA1")}`,
    ]),
  };
}

export function pricingSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
  descriptionKey: "metaDescription" | "metaDescriptionNoVault",
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t(descriptionKey), [t("title")]),
  };
}

export function ohMyPiSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), [
      t("title"),
      t("intro"),
    ]),
  };
}
