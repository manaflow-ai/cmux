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
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, path, availableLocales);
  const { title, description } = docsPageSeoCopy(
    locale,
    pageKey,
    messages,
    siteMeta,
  );
  return {
    title: { absolute: title },
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "article"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}
