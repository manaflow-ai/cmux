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
): Metadata {
  const description = seoDescription("en", summary, { minLength: 0 });
  const alternates = buildAlternates("en", path, ["en"]);

  return {
    title,
    description,
    alternates,
    openGraph: {
      ...openGraphDefaults("en", "website"),
      title,
      description,
      url: alternates.canonical,
    },
    twitter: twitterSummary("en", title, description),
  };
}
