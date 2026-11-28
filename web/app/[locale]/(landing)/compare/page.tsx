import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";
import { compareIndexSeoCopy } from "@/i18n/audited-seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import { comparePages, comparePath } from "../../../lib/compare-pages";
import { TrackedLink } from "../tracked-link";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.compare" });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const alternates = buildAlternates(locale, "/compare");
  const { title, description } = compareIndexSeoCopy(locale, t, siteMeta);
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

export default function CompareIndexPage() {
  const t = useTranslations("landing.compare");
  const tl = useTranslations("landing.links");
  return (
    <>
      <SiteHeader section={tl("compare")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <h1>{t("title")}</h1>
          <p>{t("intro")}</p>
          <ul className="not-prose mt-6 flex flex-col gap-5">
            {comparePages.map((page) => (
              <li key={page.slug}>
                <TrackedLink
                  href={comparePath(page.slug)}
                  event="compare_link_clicked"
                  className="text-base font-medium underline underline-offset-2"
                >
                  {t(`pages.${page.key}.title`)}
                </TrackedLink>
                <p className="text-muted text-sm mt-1">
                  {t(`pages.${page.key}.metaDescription`)}
                </p>
              </li>
            ))}
          </ul>
        </div>
      </main>
    </>
  );
}
