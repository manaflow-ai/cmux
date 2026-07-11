import { getTranslations } from "next-intl/server";
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
  messages,
  availableLocales,
}: {
  locale: string;
  pageKey: AuditedDocsPageKey;
  path: string;
  messages: SeoMessageLookup;
  availableLocales?: readonly Locale[];
}) {
  const docs = await getTranslations({ locale, namespace: "docs" });
  const alternates = buildAlternates(locale, path, availableLocales);
  const { title, socialTitle, description } = docsPageSeoCopy(
    locale,
    pageKey,
    messages,
    docs("layoutTitle"),
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
