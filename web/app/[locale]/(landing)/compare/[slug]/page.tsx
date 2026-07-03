import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import { buildAlternates } from "../../../../../i18n/seo";
import {
  comparePageForSlug,
  comparePages,
  comparePath,
} from "../../../../lib/compare-pages";
import { articleSchema, breadcrumbList, faqPage, JsonLd } from "../../../components/json-ld";
import { CompareTable, LandingCTA } from "../../landing-ui";

type PageParams = { locale: string; slug: string };

type Section = { title: string; body: string };
type Table = { headers: string[]; rows: string[][] };

export function generateStaticParams() {
  return comparePages.map((page) => ({ slug: page.slug }));
}

export async function generateMetadata({
  params,
}: {
  params: Promise<PageParams>;
}) {
  const { locale, slug } = await params;
  const page = comparePageForSlug(slug);
  if (!page) {
    notFound();
  }

  const namespace = `landing.compare.pages.${page.key}`;
  const t = await getTranslations({ locale, namespace });
  const path = comparePath(page.slug);
  const alternates = buildAlternates(locale, path);
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
      type: "article",
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
    },
  };
}

export default function ComparePage({
  params,
}: {
  params: Promise<PageParams>;
}) {
  return <ComparePageBody params={params} />;
}

async function ComparePageBody({ params }: { params: Promise<PageParams> }) {
  const { slug } = await params;
  const page = comparePageForSlug(slug);
  if (!page) {
    notFound();
  }

  return <ComparePageContent pageKey={page.key} slug={page.slug} />;
}

function ComparePageContent({
  pageKey,
  slug,
}: {
  pageKey: string;
  slug: string;
}) {
  const namespace = `landing.compare.pages.${pageKey}`;
  const t = useTranslations(namespace);
  const tl = useTranslations("landing.links");
  const tc = useTranslations("landing.compare");
  const locale = useLocale();
  const path = comparePath(slug);
  const sections = t.raw("sections") as Section[];
  const table = t.raw("table") as Table;
  const qas = [1, 2, 3].map((n) => ({
    question: t(`faqQ${n}`),
    answer: t(`faqA${n}`),
  }));

  return (
    <>
      <JsonLd
        data={articleSchema({
          locale,
          path,
          headline: t("title"),
          description: t("metaDescription"),
          datePublished: "2026-07-03",
        })}
      />
      <JsonLd
        data={breadcrumbList(locale, [
          { name: tl("home"), path: "/" },
          { name: tc("title"), path: "/compare" },
          { name: t("title"), path },
        ])}
      />
      <JsonLd data={faqPage(qas)} />

      <h1>{t("title")}</h1>
      <p>{t("intro")}</p>

      <h2>{t("summaryTitle")}</h2>
      <p>{t("summaryBody")}</p>

      <CompareTable headers={table.headers} rows={table.rows} />

      {sections.map((section) => (
        <section key={section.title}>
          <h2>{section.title}</h2>
          <p>{section.body}</p>
        </section>
      ))}

      <h2>{t("faqTitle")}</h2>
      {qas.map((qa) => (
        <section key={qa.question}>
          <h3>{qa.question}</h3>
          <p>{qa.answer}</p>
        </section>
      ))}

      <LandingCTA
        related={[
          { href: "/agents", label: tl("agents") },
          { href: "/docs/keyboard-shortcuts", label: tl("keyboardShortcuts") },
          { href: "/docs/browser-automation", label: tl("browserAutomation") },
        ]}
      />
    </>
  );
}
