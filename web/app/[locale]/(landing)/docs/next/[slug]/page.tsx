import { notFound } from "next/navigation";
import { NextDocView } from "../next-doc-view";
import { baseDocsLocales } from "@/app/[locale]/components/docs-nav-items";
import { nextDocPage, nextDocPages } from "@/data/next-docs/pages";
import { buildAlternates } from "@/i18n/seo";

type Params = Promise<{ locale: string; slug: string }>;

export function generateStaticParams() {
  return nextDocPages.map((page) => ({ slug: page.slug }));
}

export async function generateMetadata({ params }: { params: Params }) {
  const { locale, slug } = await params;
  const page = nextDocPage(slug);
  if (!page) notFound();
  return {
    title: page.title,
    description: page.description,
    alternates: buildAlternates(locale, `/docs/next/${slug}`, baseDocsLocales),
  };
}

export default async function NextDocPageRoute({ params }: { params: Params }) {
  const { locale, slug } = await params;
  const page = nextDocPage(slug);
  if (!page || !baseDocsLocales.includes(locale as (typeof baseDocsLocales)[number])) notFound();
  return <NextDocView page={page} />;
}
