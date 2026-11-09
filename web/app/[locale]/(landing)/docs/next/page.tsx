import { notFound } from "next/navigation";
import { NextDocView, nextDocMetadata } from "./next-doc-view";
import { baseDocsLocales } from "@/app/[locale]/components/docs-nav-items";
import { nextDocPage } from "@/data/next-docs/pages";

const page = nextDocPage("getting-started")!;

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return nextDocMetadata(page, locale);
}

/** The cmux-next docs landing page: Getting started. English only, nightly channel only. */
export default async function NextDocsIndex({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  if (!baseDocsLocales.includes(locale as (typeof baseDocsLocales)[number])) notFound();
  return <NextDocView page={page} />;
}
