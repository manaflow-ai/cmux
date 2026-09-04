import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import {
  buildAlternates,
  joinMetadataSentences,
  openGraphDefaults,
  seoDescription,
  seoTitle,
  twitterSummary,
} from "@/i18n/seo";
import {
  articleSchema,
  breadcrumbList,
  JsonLd,
} from "@/app/[locale]/components/json-ld";
import {
  changelogPath,
  changelogVersionDescription,
  changelogVersionPath,
  localizedChangelogPath,
  changelogVersionsForPrerender,
  type ChangelogVersion,
} from "@/app/lib/changelog";
import { changelogStore } from "@/app/lib/changelog-store";
import { changelogMedia, type VersionMedia } from "../changelog-media";
import { ChangelogRelease } from "../changelog-release";

type PageParams = { locale: string; version: string };


export function generateStaticParams() {
  return changelogVersionsForPrerender(changelogStore.versions())
    .map((release) => ({ version: release.version }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}): Promise<Metadata> {
  const { locale, version } = await params;
  const release = changelogStore.findVersion(version);
  if (!release) notFound();

  const t = await getTranslations({ locale, namespace: "docs.changelog" });
  const path = changelogVersionPath(release.version);
  const alternates = buildAlternates(locale, path);
  const localizedVersionTitle = t("versionTitle", {
    version: release.version,
  });
  const { title, description } = versionSeoCopy(
    locale,
    release,
    changelogMedia[release.version],
    localizedVersionTitle,
    t("metaDescription"),
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
      publishedTime: release.date,
      modifiedTime: release.date,
    },
    twitter: twitterSummary(locale, title, description),
  };
}

export default async function ChangelogVersionPage({
  params,
}: {
  params: Promise<PageParams>;
}) {
  const { locale, version } = await params;
  const context = changelogStore.findVersionContext(version);
  if (!context) notFound();

  const { release, index: releaseIndex, versions } = context;
  const media = changelogMedia[release.version];
  const [t, links, nav] = await Promise.all([
    getTranslations({ locale, namespace: "docs.changelog" }),
    getTranslations({ locale, namespace: "landing.links" }),
    getTranslations({ locale, namespace: "nav" }),
  ]);
  const path = changelogVersionPath(release.version);
  const localizedVersionTitle = t("versionTitle", {
    version: release.version,
  });
  const { description } = versionSeoCopy(
    locale,
    release,
    media,
    localizedVersionTitle,
    t("metaDescription"),
  );
  const headline = locale === "en" && media?.title
    ? `cmux ${release.version}: ${media.title}`
    : localizedVersionTitle;
  const sectionLabels = {
    added: t("sections.added"),
    changed: t("sections.changed"),
    fixed: t("sections.fixed"),
    removed: t("sections.removed"),
    contributors: t("sections.contributors"),
  };
  const newerRelease = versions[releaseIndex - 1];
  const olderRelease = versions[releaseIndex + 1];

  return (
    <div className="w-full max-w-[640px] min-w-0">
      <JsonLd
        data={articleSchema({
          locale,
          path,
          headline,
          description,
          datePublished: release.date,
          dateModified: release.date,
        })}
      />
      <JsonLd
        data={breadcrumbList(locale, [
          { name: links("home"), path: "/" },
          { name: nav("docs"), path: "/docs" },
          { name: t("title"), path: changelogPath },
          { name: `cmux ${release.version}`, path },
        ])}
      />

      <div className="not-prose" style={{ paddingBottom: 20 }}>
        <a
          href={localizedChangelogPath(locale)}
          className="text-[13px] text-muted hover:text-foreground transition-colors"
        >
          <span aria-hidden>&larr;</span> {t("title")}
        </a>
      </div>

      <ChangelogRelease
        release={release}
        locale={locale}
        media={media}
        sectionLabels={sectionLabels}
        standaloneHeading={headline}
        standalone
      />

      {(olderRelease || newerRelease) && (
        <nav
          aria-label={t("releaseNavLabel", {
            version: release.version,
          })}
          className="not-prose flex items-center justify-between border-t border-border pt-6 text-[13px]"
        >
          {olderRelease ? (
            <a
              href={localizedChangelogPath(locale, olderRelease.version)}
              className="text-muted hover:text-foreground transition-colors"
            >
              <span aria-hidden>&larr;</span> cmux {olderRelease.version}
            </a>
          ) : (
            <span />
          )}
          {newerRelease ? (
            <a
              href={localizedChangelogPath(locale, newerRelease.version)}
              className="text-muted hover:text-foreground transition-colors"
            >
              cmux {newerRelease.version} <span aria-hidden>&rarr;</span>
            </a>
          ) : (
            <span />
          )}
        </nav>
      )}
    </div>
  );
}

function versionSeoCopy(
  locale: string,
  release: ChangelogVersion,
  media: VersionMedia | undefined,
  localizedVersionTitle: string,
  changelogDescription: string,
) {
  const conciseTitle = localizedVersionTitle;
  const titleCandidate = locale === "en" && media?.title
    ? `cmux ${release.version}: ${media.title}`
    : conciseTitle;
  const title = seoTitle(locale, titleCandidate, {
    appendLocalizedContext: false,
    fallbackCandidates: [conciseTitle],
  });
  const descriptionCandidate =
    locale === "en"
      ? changelogVersionDescription(
          release,
          media?.features?.[0]?.description,
        )
      : joinMetadataSentences(
          locale,
          `cmux ${release.version}`,
          changelogDescription,
        );
  const description = seoDescription(locale, descriptionCandidate);
  return { title, description };
}
