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

export type AuditedBlogPostKey =
  | "cmuxOmo"
  | "gpl"
  | "showHnLaunch"
  | "sessionRestore"
  | "cmuxHome"
  | "introducingCmux"
  | "claudeCodeBestWorktreeManager"
  | "zenOfCmux"
  | "cmdShiftU"
  | "unreadShortcuts"
  | "passkeyAuth";

const blogDescriptionCandidateKeys: Record<
  AuditedBlogPostKey,
  readonly string[]
> = {
  cmuxOmo: ["summary"],
  gpl: ["summary", "p1"],
  showHnLaunch: ["summary"],
  sessionRestore: ["summary", "p1", "p2", "agentP2", "limitsP"],
  cmuxHome: ["summary", "p2", "p3", "p4"],
  introducingCmux: ["summary", "p1", "whyP"],
  claudeCodeBestWorktreeManager: ["summary", "p1"],
  zenOfCmux: ["summary", "p1", "p2", "p3", "p4"],
  cmdShiftU: ["summary", "p1"],
  unreadShortcuts: ["summary", "p1", "p2", "p3", "p4", "p5"],
  passkeyAuth: ["summary", "p1", "p3"],
};

export type AuditedDocsPageKey =
  | "ohMyOpenCode"
  | "api"
  | "configuration"
  | "browserAutomation"
  | "ios"
  | "ssh"
  | "workspaceGroups"
  | "textBox"
  | "concepts"
  | "customCommands"
  | "notifications"
  | "sessionRestore"
  | "skills"
  | "dock"
  | "keyboardShortcuts"
  | "gettingStarted"
  | "remoteTmux";

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

const historyShortDescriptions: Partial<Record<string, string>> = {
  th: "cmux history ช่วยเปิดเทอร์มินัล เบราว์เซอร์ และเซสชัน AI ที่ปิดไป พร้อมเลื่อนโฟกัสบน macOS.",
};

const khmerComparePageFallbacks = new Set([
  "cmuxVsDevin",
  "cmuxVsIterm2",
  "cmuxVsKitty",
  "cmuxVsTmux",
  "cmuxVsVscode",
  "cmuxVsWezterm",
]);

function selectTitle(
  locale: string,
  original: string,
  siteMeta: SeoMessageLookup,
  authoredCandidates: readonly string[],
) {
  const tagline = openGraphImageTagline(locale);
  const shortContext = shortTitleContexts[locale] ?? shortTitleContexts.en;
  const contextualCandidates = authoredCandidates.flatMap((candidate) => {
    const brandCandidate = /cmux/iu.test(candidate)
      ? []
      : [`${candidate} — cmux`];
    return [
      candidate,
      ...brandCandidate,
      `${candidate} — ${shortContext}`,
      `${candidate} — ${tagline}`,
      `${candidate} — ${siteMeta("title")}`,
    ];
  });
  return seoTitle(locale, original, {
    minLength: conciseTitleLocales.has(locale) ? 0 : undefined,
    fallbackCandidates: [...contextualCandidates],
  });
}

function selectDocsTitle(
  locale: string,
  original: string,
  pageTitle: string,
  layoutTitle: string,
  compactTitle?: string,
) {
  const shortContext = shortTitleContexts[locale] ?? shortTitleContexts.en;
  const suffix = ` — ${layoutTitle}`;
  const titleCandidates = [
    ...(compactTitle
      ? [
          compactTitle,
          `${compactTitle} — macOS`,
          `${compactTitle} — ${shortContext}`,
        ]
      : []),
    pageTitle,
    `${pageTitle} — macOS`,
    `${pageTitle} — ${shortContext}`,
  ];
  const effectiveTitle = seoTitle(
    locale,
    `${compactTitle ?? original}${suffix}`,
    {
      minLength: conciseTitleLocales.has(locale) ? 0 : undefined,
      fallbackCandidates: titleCandidates.map(
        (candidate) => `${candidate}${suffix}`,
      ),
      appendLocalizedContext: false,
    },
  );
  return effectiveTitle.endsWith(suffix)
    ? effectiveTitle.slice(0, -suffix.length)
    : effectiveTitle;
}

function selectDocsSocialTitle(
  locale: string,
  original: string,
  pageTitle?: string,
  compactTitle?: string,
) {
  const shortContext = shortTitleContexts[locale] ?? shortTitleContexts.en;
  const fallbackTitles = [pageTitle, compactTitle].filter(
    (candidate): candidate is string => Boolean(candidate),
  );
  return seoTitle(locale, original, {
    minLength: conciseTitleLocales.has(locale) ? 0 : undefined,
    fallbackCandidates: fallbackTitles.flatMap((candidate) => [
      `${candidate} — ${shortContext} — cmux`,
      `${candidate} — ${shortContext}`,
      `${candidate} — cmux`,
      candidate,
    ]),
    appendLocalizedContext: false,
  });
}

function firstMetadataSentence(value: string) {
  return value
    .split(/(?<=[。！？])|(?<=[.!?؟។៕])\s+/u)
    .map((fragment) => fragment.trim())
    .find(Boolean);
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
    .filter((candidate) => !/[:：៖]\s*$/u.test(candidate))
    .map((candidate) => completeMetadataSentence(locale, candidate));
  const contextFragments = (options.contextFragments ?? []).filter(
    (candidate) => !/[:：៖]\s*$/u.test(candidate),
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
      contextFragments: [`${t("title")} — ${t("iconSection")}`, t("title")],
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

export function blogPostSeoCopy(
  locale: string,
  postKey: AuditedBlogPostKey,
  metadata: SeoMessageLookup,
  post: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
) {
  const title = post("title");
  const authoredDescriptions = blogDescriptionCandidateKeys[postKey].map(
    (key) => post(key),
  );
  return {
    title: selectTitle(locale, metadata("metaTitle"), siteMeta, [title]),
    description: selectDescription(locale, metadata("metaDescription"), {
      completeCandidates: authoredDescriptions,
      contextFragments: [title],
    }),
  };
}

export function landingPageSeoCopy(
  locale: string,
  t: SeoMessageLookup,
  siteMeta: SeoMessageLookup,
  candidateKeys: {
    complete: readonly string[];
    context: readonly string[];
  },
) {
  const completeCandidates = candidateKeys.complete.map((key) => t(key));
  const contextFragments = candidateKeys.context.map((key) => t(key));
  return {
    title: selectTitle(locale, t("metaTitle"), siteMeta, [
      ...contextFragments,
      ...completeCandidates,
    ]),
    description: selectDescription(locale, t("metaDescription"), {
      completeCandidates,
      contextFragments,
    }),
  };
}

export function docsPageSeoCopy(
  locale: string,
  pageKey: AuditedDocsPageKey,
  t: SeoMessageLookup,
  layoutTitle: string,
  options: {
    curatedDescription?: string;
    intro?: string;
  } = {},
) {
  const pageTitle = pageKey === "ohMyOpenCode" ? undefined : t("title");
  const title = pageTitle ?? t("metaTitle");
  const metaTitle = t("metaTitle");
  const metaDescription = t("metaDescription");
  const auditedDescriptions = [
    options.curatedDescription,
    firstMetadataSentence(metaDescription),
    options.intro ? firstMetadataSentence(options.intro) : undefined,
  ].filter((candidate): candidate is string => Boolean(candidate));
  const auditedDescription = auditedDescriptions[0] ?? metaDescription;
  const compactTitle =
    pageKey === "ohMyOpenCode" ? "oh-my-opencode" : undefined;
  return {
    title: selectDocsTitle(locale, metaTitle, title, layoutTitle, compactTitle),
    socialTitle: selectDocsSocialTitle(
      locale,
      metaTitle,
      pageTitle,
      compactTitle,
    ),
    description: selectDescription(locale, auditedDescription, {
      completeCandidates: auditedDescriptions,
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
  const shortDescription = historyShortDescriptions[locale];
  return {
    title: selectTitle(locale, metaTitle, siteMeta, [
      post("title"),
      post("reopenTitle"),
      post("agentTitle"),
      post("focusTitle"),
    ]),
    description: selectDescription(locale, metadata("metaDescription"), {
      completeCandidates: [
        ...(shortDescription ? [shortDescription] : []),
        post("summary"),
        post("p1"),
        post("fullHistoryP"),
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
  if (locale === "km" && khmerComparePageFallbacks.has(pageKey)) {
    completeDescriptionCandidates.push(
      `${t("title")} ប្រៀបធៀបភ្នាក់ងារសរសេរកូដ AI ការជូនដំណឹង កន្លែងធ្វើការ និងស្វ័យប្រវត្តិកម្មលើ macOS។`,
    );
  }
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
