import {
  completeMetadataSentence,
  openGraphImageAlt,
  openGraphImageTagline,
  detailedSeoDescriptionCandidate,
  joinMetadataSentences,
  joinMetadataQuestionAndAnswer,
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
  options: {
    completeCandidates?: readonly string[];
    contextFragments?: readonly string[];
  } = {},
) {
  const short = shortSeoDescriptionCandidate(locale);
  const detailed = detailedSeoDescriptionCandidate(locale);
  const completeCandidates = (options.completeCandidates ?? [])
    .filter((candidate) => !/[:：]\s*$/u.test(candidate))
    .map((candidate) => completeMetadataSentence(locale, candidate));
  const contextFragments = (options.contextFragments ?? []).filter(
    (candidate) => !/[:：]\s*$/u.test(candidate),
  );
  const contextualCandidates = [
    ...completeCandidates,
    ...completeCandidates.map((candidate) =>
      joinMetadataSentences(locale, candidate, short),
    ),
    ...completeCandidates.map((candidate) =>
      joinMetadataSentences(locale, candidate, detailed),
    ),
    ...contextFragments.map((candidate) =>
      joinMetadataSentences(locale, candidate, short),
    ),
    ...contextFragments.map((candidate) =>
      joinMetadataSentences(locale, candidate, detailed),
    ),
  ];
  return seoDescription(locale, completeMetadataSentence(locale, original), {
    minLength: 110,
    fallbackCandidates: contextualCandidates,
  });
}

export function homeSeoCopy(locale: string, meta: SeoMessageLookup) {
  const title = selectTitle(locale, meta("title"), meta, [
    openGraphImageAlt(locale),
    openGraphImageTagline(locale),
  ]);
  const description = selectDescription(locale, meta("description"), {
    completeCandidates: [meta("ogDescription")],
    contextFragments: [
      `cmux — ${shortTitleContexts[locale] ?? shortTitleContexts.en}`,
      "cmux",
      openGraphImageAlt(locale),
    ],
  });
  return { title, description };
}

export function assetsSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [t("description")],
      contextFragments: [
        `${t("title")} — ${t("iconSection")}`,
        t("title"),
      ],
    }),
  };
}

export function blogIndexSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [t("description")],
      contextFragments: [t("title")],
    }),
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
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [t("description")],
      contextFragments: [
        `${t("title")} — ${t("sourceAction")}`,
        t("title"),
        t("section"),
      ],
    }),
  };
}

export function bestTerminalSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [t("intro")],
      contextFragments: [t("title"), t("cmuxBuiltFor")],
    }),
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
    description: selectDescription(locale, metadata("metaDescription"), {
      completeCandidates: [
        post("summary"),
        post("p1"),
        post("agentP2"),
        post("focusP"),
        post("fullHistoryP"),
        post("docsCta"),
      ],
      contextFragments: [
        post("title"),
        post("reopenTitle"),
        post("agentTitle"),
        post("focusTitle"),
        `${metaTitle} — ${post("agentTitle")}`,
      ],
    }),
  };
}

export function compareIndexSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [t("intro")],
      contextFragments: [
        `${t("title")} — ${shortTitleContexts[locale] ?? shortTitleContexts.en}`,
        t("title"),
      ],
    }),
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
  const completeDescriptionCandidates = [t("summaryBody"), t("intro")];
  const descriptionFragments = [t("title")];
  if (pageKey === "bestTerminalForAgents") {
    titleCandidates.push(landingLinks("bestTerminal"));
    descriptionFragments.push(landingLinks("agents"));
  } else if (pageKey === "multipleClaudeAgents") {
    titleCandidates.push(landingLinks("claudeTeams"));
    descriptionFragments.push(landingLinks("claudeTeams"));
    titleCandidates.push(t("faqQ1"), t("faqQ2"), t("faqQ3"));
  } else {
    titleCandidates.push(t("faqQ1"), t("faqQ2"), t("faqQ3"));
  }
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, titleCandidates),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [
        ...completeDescriptionCandidates,
        joinMetadataQuestionAndAnswer(locale, t("faqQ1"), t("faqA1")),
        joinMetadataQuestionAndAnswer(locale, t("faqQ2"), t("faqA2")),
        joinMetadataQuestionAndAnswer(locale, t("faqQ3"), t("faqA3")),
        joinMetadataQuestionAndAnswer(
          locale,
          t("faqQ1"),
          shortSeoDescriptionCandidate(locale),
        ),
        joinMetadataQuestionAndAnswer(
          locale,
          t("faqQ2"),
          shortSeoDescriptionCandidate(locale),
        ),
        joinMetadataQuestionAndAnswer(
          locale,
          t("faqQ3"),
          shortSeoDescriptionCandidate(locale),
        ),
      ],
      contextFragments: descriptionFragments,
    }),
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
    description: selectDescription(locale, t(descriptionKey), {
      completeCandidates: [
        t(
          descriptionKey === "metaDescription"
            ? "metaDescriptionShort"
            : "metaDescriptionNoVaultShort",
        ),
      ],
      contextFragments: [t("title")],
    }),
  };
}

export function ohMyPiSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [t("title")]),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates: [t("intro")],
      contextFragments: [t("title")],
    }),
  };
}
