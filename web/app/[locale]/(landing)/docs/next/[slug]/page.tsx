import { notFound } from "next/navigation";
import { NextDocView, nextDocMetadata } from "../next-doc-view";
import { nextDocPage, nextDocPages } from "@/data/next-docs/pages";

type Params = Promise<{ locale: string; slug: string }>;

export function generateStaticParams() {
  return nextDocPages.map((page) => ({ slug: page.slug }));
}

export async function generateMetadata({ params }: { params: Params }) {
  const { locale, slug } = await params;
  const page = nextDocPage(slug);
  if (!page) notFound();
  return nextDocMetadata(page, locale);
}

/** Every locale serves the English page (NextDocView says why). */
export default async function NextDocPageRoute({ params }: { params: Params }) {
  const { slug } = await params;
  const page = nextDocPage(slug);
  if (!page) notFound();
  return <NextDocView page={page} />;
}
