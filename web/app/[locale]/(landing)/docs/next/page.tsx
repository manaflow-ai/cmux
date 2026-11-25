import { NextDocView, nextDocMetadata } from "./next-doc-view";
import { nextDocPage } from "@/data/next-docs/pages";

const page = nextDocPage("getting-started")!;

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  return nextDocMetadata(page, locale);
}

/**
 * The cmux-next docs landing page: Getting started. English only, nightly channel only; every
 * locale serves the English page (NextDocView says why).
 */
export default function NextDocsIndex() {
  return <NextDocView page={page} />;
}
