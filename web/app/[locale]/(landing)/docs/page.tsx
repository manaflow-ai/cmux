import { redirect } from "next/navigation";
import { auditedDocsMetadata } from "./audited-docs-metadata";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  return auditedDocsMetadata({
    locale,
    pageKey: "gettingStarted",
    path: "/docs/getting-started",
  });
}

export default async function DocsPage({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const prefix = locale === "en" ? "" : `/${locale}`;
  redirect(`${prefix}/docs/getting-started`);
}
