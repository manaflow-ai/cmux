import type { Metadata } from "next";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";

export function legalMetadata(
  locale: string,
  path: string,
  title: string,
  summary: string,
): Metadata {
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

type RawMessageReader = {
  raw(key: string): unknown;
};

export function rawStringList(
  translator: RawMessageReader,
  key: string,
): readonly string[] {
  const value = translator.raw(key);
  return Array.isArray(value) &&
    value.every((item): item is string => typeof item === "string")
    ? value
    : [];
}
