import type { Metadata } from "next";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";

export function legalMetadata(
  path: string,
  title: string,
  summary: string,
): Metadata;
export function legalMetadata(
  locale: string,
  path: string,
  title: string,
  summary: string,
): Metadata;
export function legalMetadata(
  localeOrPath: string,
  pathOrTitle: string,
  titleOrSummary: string,
  localizedSummary?: string,
): Metadata {
  const locale = localizedSummary === undefined ? "en" : localeOrPath;
  const path = localizedSummary === undefined ? localeOrPath : pathOrTitle;
  const title = localizedSummary === undefined ? pathOrTitle : titleOrSummary;
  const summary =
    localizedSummary === undefined ? titleOrSummary : localizedSummary;
  const description = seoDescription(locale, summary, { minLength: 0 });
  const alternates = buildAlternates(locale, path);

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults(locale, "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary(locale, title, description),
  };
}
