import { getMessages } from "next-intl/server";
import type { Locale } from "@/i18n/routing";
import {
  type AuditedDocsPageKey,
  docsPageSeoCopy,
  type SeoMessageLookup,
} from "@/i18n/audited-seo";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";

export async function auditedDocsMetadata({
  locale,
  pageKey,
  path,
  availableLocales,
}: {
  locale: string;
  pageKey: AuditedDocsPageKey;
  path: string;
  availableLocales?: readonly Locale[];
}) {
  const allMessages = await getMessages({ locale });
  const docs = allMessages.docs as Record<string, unknown>;
  const pageMessages = docs[pageKey] as Record<string, unknown>;
  const messages: SeoMessageLookup = (key) => {
    const value = pageMessages[key];
    if (typeof value !== "string") {
      throw new Error(`Expected docs.${pageKey}.${key} to be a string`);
    }
    return value;
  };
  const layoutTitle = docs.layoutTitle;
  if (typeof layoutTitle !== "string") {
    throw new Error("Expected docs.layoutTitle to be a string");
  }
  const alternates = buildAlternates(locale, path, availableLocales);
  const { title, socialTitle, description } = docsPageSeoCopy(
    locale,
    pageKey,
    messages,
    layoutTitle,
    {
      curatedDescription:
        typeof pageMessages.metaDescriptionShort === "string"
          ? pageMessages.metaDescriptionShort
          : undefined,
      intro:
        typeof pageMessages.intro === "string"
          ? pageMessages.intro
          : undefined,
    },
  );
  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title: socialTitle,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, socialTitle, description),
  };
}
