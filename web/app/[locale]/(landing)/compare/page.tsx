import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "../../../../i18n/seo";
import { comparePages, comparePath } from "../../../lib/compare-pages";
import { TrackedLink } from "../tracked-link";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "landing.compare" });
  const alternates = buildAlternates(locale, "/compare");
  const title = t("metaTitle");
  const description = t("metaDescription");
  return {
    title,
    description,
    alternates,
    openGraph: {
      title,
      description,
      url: alternates.canonical,
      siteName: "cmux",
      type: "website",
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
    },
  };
}

export default function CompareIndexPage() {
  const t = useTranslations("landing.compare");
  return (
    <>
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
    </>
  );
}
