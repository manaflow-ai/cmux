import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import {
  buildAlternates,
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
  findChangelogVersion,
  localizedChangelogPath,
  readChangelog,
  type ChangelogVersion,
} from "@/app/lib/changelog";
import { changelogMedia, type VersionMedia } from "../changelog-media";
import { ChangelogRelease } from "../changelog-release";

type PageParams = { locale: string; version: string };

export const dynamicParams = false;

export function generateStaticParams() {
  return readChangelog().map((release) => ({ version: release.version }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}): Promise<Metadata> {
  const { locale, version } = await params;
  const release = findChangelogVersion(version);
  if (!release) notFound();

  const t = await getTranslations({ locale, namespace: "docs.changelog" });
  const path = changelogVersionPath(release.version);
  const alternates = buildAlternates(locale, path);
  const { title, description } = versionSeoCopy(
    locale,
    release,
    changelogMedia[release.version],
    t("metaTitle"),
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
  const versions = readChangelog();
  const releaseIndex = versions.findIndex(
    (candidate) => candidate.version === version,
  );
  if (releaseIndex < 0) notFound();

  const release = versions[releaseIndex];
  const media = changelogMedia[release.version];
  const [t, links, nav] = await Promise.all([
    getTranslations({ locale, namespace: "docs.changelog" }),
    getTranslations({ locale, namespace: "landing.links" }),
    getTranslations({ locale, namespace: "nav" }),
  ]);
  const path = changelogVersionPath(release.version);
  const { description } = versionSeoCopy(
    locale,
    release,
    media,
    t("metaTitle"),
  );
  const headline = media?.title
    ? `cmux ${release.version}: ${media.title}`
    : `cmux ${release.version}`;
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
        standalone
      />

      {(olderRelease || newerRelease) && (
        <nav
          aria-label={`${t("title")} ${release.version}`}
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
  changelogTitle: string,
) {
  const conciseTitle = `cmux ${release.version} · ${changelogTitle}`;
  const titleCandidate = media?.title
    ? `cmux ${release.version}: ${media.title}`
    : conciseTitle;
  const title = seoTitle(locale, titleCandidate, {
    appendLocalizedContext: false,
    fallbackCandidates: [conciseTitle],
  });
  const description = seoDescription(
    locale,
    changelogVersionDescription(
      release,
      media?.features?.[0]?.description,
    ),
  );
  return { title, description };
}
