import { getTranslations } from "next-intl/server";
import {
  buildAlternates,
  openGraphDefaults,
  seoDescription,
  twitterSummary,
} from "@/i18n/seo";
import {
  localizedChangelogPath,
} from "@/app/lib/changelog";
import { changelogStore } from "@/app/lib/changelog-store";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";
import { DocsSchema } from "../docs-schema";
import { changelogMedia } from "./changelog-media";
import { ChangelogRelease } from "./changelog-release";


export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.changelog" });
  const alternates = buildAlternates(locale, "/docs/changelog");
  const title = t("metaTitle");
  const description = seoDescription(locale, t("metaDescription"));
  return {
    title,
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

export default async function ChangelogPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.changelog" });
  const versions = changelogStore.versions();
  const sectionLabels = {
    added: t("sections.added"),
    changed: t("sections.changed"),
    fixed: t("sections.fixed"),
    removed: t("sections.removed"),
    contributors: t("sections.contributors"),
  };

  return (
    <div className="w-full max-w-[640px] min-w-0">
      <DocsSchema namespace="docs.changelog" path="/docs/changelog" />
      <DocsHeading level={1} id="title" className="docs-heading-compact">
        {t("title")}
      </DocsHeading>

      <div style={{ paddingTop: 16 }}>
        {versions.map((release, index) => (
          <ChangelogRelease
            key={release.version}
            release={release}
            locale={locale}
            media={changelogMedia[release.version]}
            sectionLabels={sectionLabels}
            versionHref={localizedChangelogPath(locale, release.version)}
            first={index === 0}
          />
        ))}
      </div>
    </div>
  );
}
