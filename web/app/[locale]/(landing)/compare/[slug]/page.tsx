import { useLocale, useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { notFound } from "next/navigation";
import {
  buildAlternates,
  openGraphDefaults,
  twitterSummary,
} from "@/i18n/seo";
import { comparePageSeoCopy } from "@/i18n/audited-seo";
import { SiteHeader } from "@/app/[locale]/components/site-header";
import {
  comparePageForSlug,
  comparePages,
  comparePath,
} from "../../../../lib/compare-pages";
import type { ComparePageKey } from "../../../../lib/compare-pages";
import { articleSchema, breadcrumbList, faqPage, JsonLd } from "../../../components/json-ld";
import { CompareTable, LandingCTA } from "../../landing-ui";
import { TrackedLink } from "../../tracked-link";

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
  const landingLinks = await getTranslations({
    locale,
    namespace: "landing.links",
  });
  const siteMeta = await getTranslations({ locale, namespace: "meta" });
  const path = comparePath(page.slug);
  const alternates = buildAlternates(locale, path);
  const { title, description } = comparePageSeoCopy(
    locale,
    page.key,
    t,
    landingLinks,
    siteMeta,
  );

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

  return (
    <ComparePageContent
      pageKey={page.key}
      slug={page.slug}
      lastModified={page.lastModified}
    />
  );
}

function ComparePageContent({
  pageKey,
  slug,
  lastModified,
}: {
  pageKey: ComparePageKey;
  slug: string;
  lastModified: string;
}) {
  const namespace = `landing.compare.pages.${pageKey}`;
  const t = useTranslations(namespace);
  const tl = useTranslations("landing.links");
  const tc = useTranslations("landing.compare");
  const siteMeta = useTranslations("meta");
  const locale = useLocale();
  const path = comparePath(slug);
  const seoCopy = comparePageSeoCopy(locale, pageKey, t, tl, siteMeta);
  const sections = t.raw("sections") as Section[];
  const table = t.raw("table") as Table;
  const qas = [1, 2, 3].map((n) => ({
    question: t(`faqQ${n}`),
    answer: t(`faqA${n}`),
  }));
  const relatedComparePages = relatedComparePagesFor(slug);

  return (
    <>
      <JsonLd
        data={articleSchema({
          locale,
          path,
          headline: seoCopy.title,
          description: seoCopy.description,
          datePublished: lastModified,
          dateModified: lastModified,
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

      <SiteHeader section={tc("title")} />
      <main className="w-full max-w-3xl mx-auto px-6 py-12">
        <div className="docs-content text-[15px]">
          <div className="not-prose mb-8">
            <TrackedLink
              href="/compare"
              event="compare_back_clicked"
              className="text-sm text-muted hover:text-foreground transition-colors"
            >
              &larr; {tc("title")}
            </TrackedLink>
          </div>

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
              { href: "/compare", label: tc("title") },
              ...relatedComparePages.map((relatedPage) => ({
                href: comparePath(relatedPage.slug),
                label: tc(`pages.${relatedPage.key}.title`),
              })),
              { href: "/agents", label: tl("agents") },
              { href: "/docs/keyboard-shortcuts", label: tl("keyboardShortcuts") },
              { href: "/docs/browser-automation", label: tl("browserAutomation") },
            ]}
          />
        </div>
      </main>
    </>
  );
}

function relatedComparePagesFor(slug: string) {
  const currentIndex = comparePages.findIndex((page) => page.slug === slug);
  const currentPage = currentIndex >= 0 ? comparePages[currentIndex] : undefined;
  const candidates = [
    comparePages.find((page) => page.slug === "best-terminal-for-ai-coding-agents"),
    comparePages.find((page) => page.slug === "multiple-claude-code-agents-parallel"),
    comparePages[currentIndex - 1],
    comparePages[currentIndex + 1],
  ];
  const seen = new Set<string>();
  return candidates.filter((page): page is (typeof comparePages)[number] => {
    if (!page || page.slug === currentPage?.slug || seen.has(page.slug)) {
      return false;
    }
    seen.add(page.slug);
    return true;
  });
}
